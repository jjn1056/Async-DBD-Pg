use strict;
use warnings;
use Test2::V0;
use Time::HiRes qw(time);
use DBI;
use File::Temp qw(tempfile);

use lib 't/lib';
use Test::Async::DBD::Pg qw(skip_without_postgres test_dsn);

my $dsn = skip_without_postgres();

use Future;
use Future::IO;

BEGIN { Future::IO->load_best_impl; }

use Async::DBD::Pg;
use Async::DBD::Pg::Util ();

sub wait_until {
    my ($code, $label, $timeout) = @_;

    $timeout //= 1;
    my $deadline = time + $timeout;

    while (time < $deadline) {
        return 1 if $code->();
        Future::IO->sleep(0.05)->get;
    }

    return 0;
}

# Terminate every backend on the test database except this one. The listener
# connection cannot be asked for its own pid: querying it while its loop is
# polling the same socket makes both wait on POLLIN forever.
sub kill_backends {
    my $parsed = Async::DBD::Pg::Util::parse_dsn(test_dsn());
    my $dbh = DBI->connect(
        $parsed->{dbi_dsn}, $parsed->{user}, $parsed->{password},
        { RaiseError => 1, PrintError => 0 },
    );
    $dbh->do(q{
        SELECT pg_terminate_backend(pid) FROM pg_stat_activity
         WHERE datname = current_database() AND pid <> pg_backend_pid()
    });
    $dbh->disconnect;
    return;
}

# Killing a listener's backend makes the FATAL arrive via DBI's own
# PrintWarn calling Perl's warn() -- not, as this file once assumed, a raw
# libpq write that bypasses warn() and $SIG{__WARN__} entirely. Measured
# directly: PrintWarn => 0 makes the notice vanish completely, which a raw
# write could not do, since libpq's own notice processor has no way to know
# about a DBI attribute. _capture_pg_notices intercepts it at the same site
# as any other server message, so it now reaches on_log instead of file
# descriptor 2. This descriptor-level helper stays regardless: it is what
# proves fd 2 stays empty, catching anything that lands there regardless of
# source, rather than assuming it does because the mechanism is understood.
sub capture_stderr {
    my ($code) = @_;

    my ($fh, $path) = tempfile(UNLINK => 1);
    close $fh;

    open my $saved_stderr, '>&', \*STDERR or die "dup stderr: $!";
    open STDERR, '>', $path or die "redirect stderr: $!";

    my $ok = eval { $code->(); 1 };
    my $err = $@;

    open STDERR, '>&', $saved_stderr or die "restore stderr: $!";
    close $saved_stderr;

    die $err unless $ok;

    open my $read_fh, '<', $path or die "read captured stderr: $!";
    local $/;
    my $captured = <$read_fh>;
    close $read_fh;

    return $captured;
}

subtest 'create pubsub instance' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
    );

    my $pubsub = $pg->pubsub;

    isa_ok $pubsub, 'Async::DBD::Pg::PubSub';
    ok !$pubsub->is_connected, 'not connected before listen';
    is $pubsub->subscribed_channels, 0, 'no channels';

    $pubsub->disconnect->get;
};

subtest 'a callback that dies does not stop the others or the listener' => sub {
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
        on_log          => sub { push @logged, $_[1] },
    );
    my $pubsub = $pg->pubsub;

    my (@second, @later);

    $pubsub->listen('cb_error_test', sub { die "callback exploded\n" })->get;
    $pubsub->listen('cb_error_test', sub { push @second, $_[1] })->get;

    $pubsub->notify('cb_error_test', 'first')->get;
    wait_until(sub { @second }, 'second callback ran', 3);

    is \@second, ['first'], 'a callback dying does not stop the next one';
    ok scalar(grep { /callback exploded/ } @logged),
        'the failure is reported rather than swallowed';

    # The listener has to survive, or one bad callback ends every
    # subscription on the connection.
    $pubsub->listen('cb_error_later', sub { push @later, $_[1] })->get;
    $pubsub->notify('cb_error_later', 'second')->get;
    wait_until(sub { @later }, 'listener still running', 3);

    is \@later, ['second'], 'listener still delivering after the failure';

    $pubsub->disconnect->get;
};

subtest 'cancelling a listen leaves the listener running' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 3,
    );
    my $pubsub = $pg->pubsub;

    my @got;
    $pubsub->listen('cancel_listen_a', sub { push @got, $_[1] })->get;

    # Issuing a control statement stops the listener for the duration. A
    # caller cancelling part way through must not leave it stopped, or
    # notifications quietly stop arriving with nothing to say why.
    my $abandoned = $pubsub->listen('cancel_listen_b', sub { });
    $abandoned->cancel;

    is $pubsub->{_stopping}, 0, 'listener not left in the stopping state';

    $pubsub->notify('cancel_listen_a', 'still here')->get;
    wait_until(sub { @got }, 'notification after the cancelled listen', 3);

    is \@got, ['still here'], 'existing subscription still delivering';

    $pubsub->disconnect->get;
};

subtest 'giving up on connect leaves pub/sub usable' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 3,
    );
    my $pubsub = $pg->pubsub;

    # Callers arriving together share one connect attempt. A caller that
    # gives up must not leave that shared attempt behind for everyone after
    # it to wait on.
    my $abandoned = $pubsub->connect;
    $abandoned->cancel;

    my @got;
    ok lives {
        $pubsub->listen('give_up_test', sub { push @got, $_[1] })->get;
    }, 'a later listen still connects';

    $pubsub->notify('give_up_test', 'payload')->get;
    wait_until(sub { @got }, 'notification arrived', 3);

    is \@got, ['payload'], 'pub/sub works normally afterwards';

    $pubsub->disconnect->get;
};

subtest 'concurrent connect checks out a single connection' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
    );
    my $pubsub = $pg->pubsub;

    # connected is only set once a connection has been handed over, so two
    # callers arriving together must still share one attempt. Otherwise each
    # checks one out and only the last is kept; the rest are never released.
    my @attempts = map { $pubsub->connect } 1 .. 3;
    $_->get for @attempts;

    ok $pubsub->is_connected, 'pub/sub connected';
    is $pg->active_count, 1, 'exactly one connection checked out of the pool';

    $pubsub->disconnect->get;
    is $pg->active_count, 0, 'connection returned on disconnect';
};

subtest 'listen and receive notification' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
    );
    my $pubsub = $pg->pubsub;
    my @received;

    $pubsub->listen('notify_test', sub {
        my ($channel, $payload, $pid) = @_;
        push @received, { channel => $channel, payload => $payload, pid => $pid };
    })->get;

    ok $pubsub->is_connected, 'connected after listen';
    is $pubsub->subscribed_channels, 1, 'one channel subscribed';

    my $conn = $pg->connection->get;
    $conn->query("NOTIFY notify_test, 'hello'")->get;
    $conn->release;

    ok wait_until(sub { @received == 1 }, 'notification delivery'), 'received notification';
    is $received[0]{channel}, 'notify_test', 'correct channel';
    is $received[0]{payload}, 'hello', 'correct payload';

    $pubsub->disconnect->get;
};

subtest 'notify via pubsub helper' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
    );
    my @received;

    $pg->listen('pubsub_notify', sub {
        my ($channel, $payload, $pid) = @_;
        push @received, { channel => $channel, payload => $payload, pid => $pid };
    })->get;

    $pg->notify('pubsub_notify', 'test message')->get;

    ok wait_until(sub { @received == 1 }, 'notification delivery'), 'received notification';
    is $received[0]{payload}, 'test message', 'correct payload';

    $pg->pubsub->disconnect->get;
};

subtest 'multiple callbacks on one channel' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
    );
    my $pubsub = $pg->pubsub;
    my @received1;
    my @received2;

    $pubsub->listen('multi_channel', sub {
        my ($channel, $payload) = @_;
        push @received1, $payload;
    })->get;

    $pubsub->listen('multi_channel', sub {
        my ($channel, $payload) = @_;
        push @received2, $payload;
    })->get;

    is $pubsub->subscribed_channels, 1, 'one subscribed channel';

    $pubsub->notify('multi_channel', 'broadcast')->get;

    ok wait_until(sub { @received1 == 1 && @received2 == 1 }, 'broadcast delivery'),
        'both callbacks received notification';
    is $received1[0], 'broadcast', 'first callback got payload';
    is $received2[0], 'broadcast', 'second callback got payload';

    $pubsub->disconnect->get;
};

subtest 'unlisten removes a specific callback' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
    );
    my $pubsub = $pg->pubsub;
    my @kept;
    my @removed;

    my $keep_cb = sub {
        my ($channel, $payload) = @_;
        push @kept, $payload;
    };
    my $drop_cb = sub {
        my ($channel, $payload) = @_;
        push @removed, $payload;
    };

    $pubsub->listen('unsub_test', $keep_cb)->get;
    $pubsub->listen('unsub_test', $drop_cb)->get;

    $pubsub->unlisten('unsub_test', $drop_cb)->get;

    $pubsub->notify('unsub_test', 'remaining')->get;

    ok wait_until(sub { @kept == 1 }, 'remaining callback delivery'), 'kept callback received';
    is \@removed, [], 'removed callback not invoked';
    is $pubsub->subscribed_channels, 1, 'channel still subscribed';

    $pubsub->unlisten('unsub_test', $keep_cb)->get;
    is $pubsub->subscribed_channels, 0, 'channel removed after last callback';

    $pubsub->disconnect->get;
};

subtest 'unlisten all clears all subscriptions' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('channel1', sub {})->get;
    $pubsub->listen('channel2', sub {})->get;
    $pubsub->listen('channel3', sub {})->get;

    is $pubsub->subscribed_channels, 3, 'three channels subscribed';

    $pg->unlisten_all->get;
    is $pubsub->subscribed_channels, 0, 'all subscriptions removed';

    $pubsub->disconnect->get;
};

subtest 'invalid channel name' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
    );

    my $err;
    eval { $pg->listen('bad;channel', sub {})->get };
    $err = $@;

    like $err, qr/Invalid channel name/, 'error for invalid channel';

    $pg->pubsub->disconnect->get;
};

subtest 'a dead listener reports itself disconnected' => sub {
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 4,
        on_log          => sub { push @logged, $_[1] },
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('death_reporting', sub { })->get;
    ok $pubsub->is_connected, 'connected before the backend dies';

    # Killing the backend makes DBD::Pg's PrintWarn raise the termination
    # notice as an ordinary warning, which _capture_pg_notices routes to
    # on_log -- not, as this comment once claimed, a raw libpq write that
    # bypasses warn() entirely. Captured at the descriptor level anyway, to
    # prove fd 2 actually stays empty rather than assuming it does.
    my $captured = capture_stderr(sub {
        kill_backends();
        wait_until(sub { !$pubsub->is_connected }, 'listener noticed', 5);
    });

    ok !$pubsub->is_connected, 'reports disconnected once the listener fails';
    is $pubsub->conn, undef, 'dead connection let go';
    is $pubsub->subscribed_channels, 1, 'subscription registry kept for replay';
    ok scalar(grep { /listener stopped/i } @logged), 'loss reported';
    is $captured, '', 'the termination notice does not reach fd 2';
    ok scalar(grep { /FATAL:\s+terminating connection due to administrator command/ } @logged),
        'the termination notice reaches on_log instead';
};

subtest 'the listener comes back after the connection dies' => sub {
    my @reconnected;
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn                    => test_dsn(),
        min_connections        => 0,
        max_connections        => 4,
        reconnect              => 1,
        reconnect_min_interval => 0.1,
        reconnect_max_interval => 0.5,
        on_reconnect           => sub { push @reconnected, $_[0] },
        on_log                 => sub { push @logged, $_[1] },
    );
    my $pubsub = $pg->pubsub;

    my @got;
    $pubsub->listen('revival', sub { push @got, $_[1] })->get;

    $pubsub->notify('revival', 'before')->get;
    wait_until(sub { @got }, 'delivery before the kill', 3);
    is \@got, ['before'], 'delivering before the connection dies';

    my $captured = capture_stderr(sub {
        kill_backends();
        wait_until(sub { @reconnected }, 'reconnected', 15);
    });

    ok scalar @reconnected, 'on_reconnect fired';
    ok $pubsub->is_connected, 'connected again';
    is $pubsub->subscribed_channels, 1, 'channel still subscribed';
    is $captured, '', 'the termination notice does not reach fd 2';
    ok scalar(grep { /FATAL:\s+terminating connection due to administrator command/ } @logged),
        'the termination notice reaches on_log instead';

    # The assertion that matters. Everything above could pass while nothing
    # was actually being delivered any more.
    $pubsub->notify('revival', 'after')->get;
    wait_until(sub { @got > 1 }, 'delivery after the reconnect', 5);
    is \@got, ['before', 'after'], 'notifications flow again';

    $pubsub->disconnect->get;
};

subtest 'without reconnect the listener stays down' => sub {
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 4,
        on_log          => sub { push @logged, $_[1] },
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('stays_down', sub { })->get;

    my $captured = capture_stderr(sub {
        kill_backends();
        wait_until(sub { !$pubsub->is_connected }, 'listener noticed', 5);
    });
    is $captured, '', 'the termination notice does not reach fd 2';
    ok scalar(grep { /FATAL:\s+terminating connection due to administrator command/ } @logged),
        'the termination notice reaches on_log instead';

    # Give a reconnect long enough to have happened, had one been asked for.
    Future::IO->sleep(1)->get;

    ok !$pubsub->is_connected, 'stays disconnected when reconnect is off';
};

subtest 'disconnect during the backoff window forgets subscriptions too' => sub {
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn                    => test_dsn(),
        min_connections        => 0,
        max_connections        => 4,
        reconnect              => 1,
        reconnect_min_interval => 2,
        reconnect_max_interval => 3,
        on_log                 => sub { push @logged, $_[1] },
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('minor_disconnect', sub { })->get;

    # Right after the connection dies, and until the supervisor's first
    # attempt completes, connected and conn are both false while the
    # supervisor sleeps its backoff. disconnect called in that window used
    # to return early before clearing channels or resetting _stopping.
    my $captured = capture_stderr(sub {
        kill_backends();
        wait_until(sub { !$pubsub->is_connected }, 'listener noticed', 5);
    });
    is $captured, '', 'the termination notice does not reach fd 2';
    ok scalar(grep { /FATAL:\s+terminating connection due to administrator command/ } @logged),
        'the termination notice reaches on_log instead';

    ok !$pubsub->{connected} && !$pubsub->{conn}, 'caught in the backoff window';

    $pubsub->disconnect->get;

    is $pubsub->subscribed_channels, 0, 'subscriptions forgotten even from the early-return path';
    is $pubsub->{_stopping}, 0, '_stopping reset even from the early-return path';
};

subtest 'a pool shutdown while queued for reconnect makes the supervisor give up' => sub {
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn                    => test_dsn(),
        min_connections        => 0,
        max_connections        => 1,
        reconnect              => 1,
        reconnect_min_interval => 1,
        reconnect_max_interval => 1.5,
        on_log                 => sub { push @logged, $_[1] },
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('shutdown_race', sub { })->get;

    my $captured = capture_stderr(sub {
        kill_backends();
        wait_until(sub { !$pubsub->is_connected }, 'listener noticed', 5);
    });
    is $captured, '', 'the termination notice does not reach fd 2';
    ok scalar(grep { /FATAL:\s+terminating connection due to administrator command/ } @logged),
        'the termination notice reaches on_log instead';

    # With only one connection allowed in this pool, holding one ourselves
    # forces the supervisor's next attempt to queue instead of succeeding,
    # so it learns about the coming shutdown by exception, not by
    # cancellation, exercising the branch this test is here to cover.
    my $held = $pg->connection->get;

    ok wait_until(sub { $pg->waiting_count }, 'supervisor queued for a connection', 5),
        'supervisor is queued behind the held connection';

    $pg->shutdown(force => 1)->get;

    ok scalar(grep { /giving up on reconnect/i } @logged),
        'supervisor reports giving up';
    is $pubsub->{_reconnect_future}, undef, 'supervisor stopped, not merely cancelled mid-flight';

    # Long enough for several more backoff cycles, had it kept looping
    # instead of stopping.
    Future::IO->sleep(2)->get;

    is scalar(grep { /reconnect attempt \d+ failed/i } @logged), 0,
        'no further reconnect attempts after shutdown';
};

subtest 'listen() during the reconnect backoff does not orphan a connection' => sub {
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn                    => test_dsn(),
        min_connections        => 0,
        max_connections        => 4,
        reconnect              => 1,
        reconnect_min_interval => 2,
        reconnect_max_interval => 3,
        on_log                 => sub { push @logged, $_[1] },
    );
    my $pubsub = $pg->pubsub;

    my (@got_a, @got_b);
    $pubsub->listen('orphan_a', sub { push @got_a, $_[1] })->get;

    my $captured = capture_stderr(sub {
        kill_backends();
        wait_until(sub { !$pubsub->is_connected }, 'listener noticed', 5);
    });
    is $captured, '', 'the termination notice does not reach fd 2';
    ok scalar(grep { /FATAL:\s+terminating connection due to administrator command/ } @logged),
        'the termination notice reaches on_log instead';

    # Call listen() for a second channel while the supervisor is still
    # backing off (the long min interval above makes this land inside the
    # window reliably rather than by luck).
    $pubsub->listen('orphan_b', sub { push @got_b, $_[1] })->get;

    ok $pubsub->is_connected, 'ordinary listen() reconnected on its own';

    # Give the supervisor time to wake up and discover it lost the race.
    Future::IO->sleep(3)->get;

    $pubsub->notify('orphan_a', 'still here')->get;
    $pubsub->notify('orphan_b', 'also here')->get;

    wait_until(sub { @got_a && @got_b }, 'delivery after the race', 5);

    is \@got_a, ['still here'], 'channel registered before the race still delivers';
    is \@got_b, ['also here'], 'channel registered during the race delivers';

    $pubsub->disconnect->get;
    ok wait_until(sub { $pg->active_count == 0 }, 'pool drained after disconnect', 3),
        'no orphaned connection left checked out';
};

subtest 'a failure inside the replay is retried in place, not left to end the supervisor' => sub {
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn                    => test_dsn(),
        min_connections        => 0,
        max_connections        => 4,
        reconnect              => 1,
        reconnect_min_interval => 3,
        reconnect_max_interval => 4,
        on_log                 => sub { push @logged, $_[1] },
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('lockout_a', sub { })->get;

    my $captured1 = capture_stderr(sub {
        kill_backends();
        wait_until(sub { !$pubsub->is_connected }, 'listener noticed', 5);
    });
    is $captured1, '', 'the termination notice does not reach fd 2';
    ok scalar(grep { /FATAL:\s+terminating connection due to administrator command/ } @logged),
        'the termination notice reaches on_log instead';

    # An ordinary listen() wins the race, same as the earlier subtest, and
    # its own control query goes through fine. The supervisor's own replay
    # is then made to fail on its second channel -- standing in for any
    # error from the query itself, without needing a real connection
    # failure. That realistic shape, with the listener teardown genuinely
    # happening, is covered separately below.
    $pubsub->listen('lockout_b', sub { })->get;

    my $orig = \&Async::DBD::Pg::PubSub::_run_control_query;
    my $seen = 0;
    {
        no strict 'refs';
        no warnings 'redefine';
        *Async::DBD::Pg::PubSub::_run_control_query = sub {
            $seen++;
            return Future->fail("simulated: connection died mid-replay\n") if $seen > 1;
            return $orig->(@_);
        };
    }

    ok wait_until(sub { $seen > 1 }, 'supervisor reached the stubbed replay', 8),
        'the supervisor woke into the race branch and started replaying';

    {
        no warnings 'redefine';
        *Async::DBD::Pg::PubSub::_run_control_query = $orig;
    }

    # The failure is caught by the loop's own eval and retried in place now,
    # not left to escape and end the supervisor's future -- it is still the
    # same future, still running, not cleared and waiting on some other
    # trigger to re-arm it.
    ok $pubsub->{_reconnect_future} && !$pubsub->{_reconnect_future}->is_ready,
        'the supervisor is still the one running, not ended by the failure';
    ok wait_until(sub {
        scalar grep { /reconnect attempt \d+ failed/i } @logged
    }, 'the failure is logged', 3),
        'the failure is reported like any other failed attempt';

    # And it recovers on its own next retry -- no independent trigger needed.
    ok wait_until(sub { $pubsub->is_connected }, 'supervisor recovers on its own retry', 10),
        'reconnects without needing a fresh, independent listener death';
    is $pubsub->subscribed_channels, 2, 'both channels still registered';

    $pubsub->disconnect->get;
};

subtest 'the give-up check does not fire on PostgreSQL wording alone' => sub {
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn                    => test_dsn(),
        min_connections        => 0,
        max_connections        => 4,
        reconnect              => 1,
        reconnect_min_interval => 0.4,
        reconnect_max_interval => 0.6,
        on_log                 => sub { push @logged, $_[1] },
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('false_positive', sub { })->get;

    # From now on every fresh connection attempt fails with PostgreSQL's own
    # restart wording. The pool itself stays healthy -- _shutting_down is
    # never set -- so this must not trip the give-up check the way matching
    # $err's text against "shut...down" would have.
    $pg->{on_connect} = sub { die "FATAL:  the database system is shutting down\n" };

    my $captured = capture_stderr(sub {
        kill_backends();
        wait_until(sub { !$pubsub->is_connected }, 'listener noticed', 5);
    });
    is $captured, '', 'the termination notice does not reach fd 2';
    ok scalar(grep { /FATAL:\s+terminating connection due to administrator command/ } @logged),
        'the termination notice reaches on_log instead';

    Future::IO->sleep(3)->get;    # several backoff cycles

    is $pg->{_shutting_down}, undef, 'the pool itself never entered shutdown';
    ok scalar(grep { /reconnect attempt \d+ failed/i } @logged) >= 2,
        'kept retrying rather than giving up on the first attempt';
    is scalar(grep { /giving up on reconnect/i } @logged), 0,
        'never gave up';

    # Pins the real on_connect error reaching the supervisor's own log line
    # specifically, rather than a generic "Died at ...". Matching anywhere in
    # @logged is not enough: the pool's own "on_connect failed: ..." line
    # carries the correct text even under the $@-clobbering bug, since it
    # interpolates $@ before _close_dbh gets a chance to clear it -- only the
    # value that travels through the die (into the supervisor's own
    # "reconnect attempt N failed" line) was ever wrong.
    ok scalar(grep { /reconnect attempt \d+ failed:.*the database system is shutting down/s } @logged),
        'the real on_connect error reaches the supervisor';

    $pg->shutdown(force => 1)->get;
};

subtest 'a connection dying again mid-replay does not leave the supervisor inert' => sub {
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn                    => test_dsn(),
        min_connections        => 0,
        max_connections        => 4,
        reconnect              => 1,
        reconnect_min_interval => 3,
        reconnect_max_interval => 4,
        on_log                 => sub { push @logged, $_[1] },
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('inert_a', sub { })->get;

    my $captured1 = capture_stderr(sub {
        kill_backends();
        wait_until(sub { !$pubsub->is_connected }, 'listener noticed', 5);
    });
    is $captured1, '', 'the termination notice does not reach fd 2';
    ok scalar(grep { /FATAL:\s+terminating connection due to administrator command/ } @logged),
        'the termination notice reaches on_log instead';

    # An ordinary listen() wins the race, same as the earlier subtests.
    $pubsub->listen('inert_b', sub { })->get;

    # Let the supervisor's own replay run for real, but kill the backend
    # again immediately before its first control query. The listener
    # teardown _run_control_query does happens for real, and the query that
    # follows then genuinely fails against a connection that just died --
    # not a synthetic failure that never touches any of that.
    my $orig = \&Async::DBD::Pg::PubSub::_run_control_query;
    my $seen = 0;
    my $captured2 = capture_stderr(sub {
        {
            no strict 'refs';
            no warnings 'redefine';
            *Async::DBD::Pg::PubSub::_run_control_query = sub {
                $seen++;
                kill_backends() if $seen == 1;
                return $orig->(@_);
            };
        }
        wait_until(sub { $seen >= 1 }, 'supervisor reached its own replay', 8);
        Future::IO->sleep(2)->get;
    });
    {
        no warnings 'redefine';
        *Async::DBD::Pg::PubSub::_run_control_query = $orig;
    }

    # Unlike the other kill_backends() calls in this file, this one lands
    # while _run_control_query is stopping the listener out from under
    # itself, cancelling the very poll that would otherwise notice the
    # server's notice -- so the connection reliably fails later via a
    # lower-level driver error instead of a notice ever reaching
    # pg_notifies at all. Either way fd 2 stays clean: if the notice is
    # never seen, nothing is ever printed; if it is seen, it goes through
    # _capture_pg_notices to on_log instead of stderr. No alternative to
    # pin to here -- unlike before, both outcomes agree.
    is $captured2, '', 'nothing reaches fd 2 from the connection dying mid-replay either way';

    # The failure this branch used to die from silently now has to be
    # reported and retried like any other reconnect failure, not swallowed.
    ok wait_until(sub {
        scalar grep { /reconnect attempt \d+ failed/i } @logged
    }, 'a failed replay is logged like any other attempt', 5),
        'the supervisor reports the failure rather than dying silently';

    # And it has to keep going: a fresh listener eventually comes back on
    # its own, with no application intervention.
    ok wait_until(sub { $pubsub->is_connected }, 'supervisor recovers on its own', 10),
        'the supervisor keeps retrying rather than going inert';
    is $pubsub->subscribed_channels, 2, 'both channels still registered';

    $pubsub->disconnect->get;
};

subtest 'a failure that escapes through on_log still clears the reconnect slot' => sub {
    my @logged;
    my $connect_attempts = 0;
    my $pg = Async::DBD::Pg->new(
        dsn                    => test_dsn(),
        min_connections        => 0,
        max_connections        => 4,
        reconnect              => 1,
        reconnect_min_interval => 0.2,
        reconnect_max_interval => 0.4,
        on_log                 => sub {
            push @logged, $_[1];
            die "boom\n" if $_[1] =~ /reconnect attempt \d+ failed/;
        },
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('on_ready_guard', sub { })->get;

    # The merged eval added in round 3 catches a failure anywhere inside an
    # attempt, but the failure handling after it -- $conn->release and
    # _log -- sits outside that eval, same as it always has. Making the
    # very next connect attempt fail drives the supervisor's own first
    # attempt to a genuine "reconnect attempt N failed" log call, and the
    # on_log above turns that into a die. That escapes _reconnect_loop's
    # async sub entirely, failing its future for real: the exact route
    # round 2's on_ready cleanup exists for, which the round-3 test does not
    # exercise at all now that its stubbed failure is caught and retried in
    # place instead of escaping.
    $pg->{on_connect} = sub {
        $connect_attempts++;
        die "simulated: first reconnect attempt fails\n" if $connect_attempts == 1;
        return Future->done;
    };

    my $captured1 = capture_stderr(sub {
        kill_backends();
        wait_until(sub { !$pubsub->is_connected }, 'listener noticed', 5);
    });
    is $captured1, '', 'the termination notice does not reach fd 2';
    ok scalar(grep { /FATAL:\s+terminating connection due to administrator command/ } @logged),
        'the termination notice reaches on_log instead';

    ok wait_until(sub { !defined $pubsub->{_reconnect_future} }, 'reconnect slot released', 5),
        'the escaping die still clears _reconnect_future rather than leaving a dead future behind';

    # Nothing is left running to notice on its own -- the escaping die took
    # the whole supervisor down with it, same as any uncaught exception
    # always would. Reconnect normally (the on_connect stub above only
    # fails the very first attempt) so there is a listener to kill again.
    $pubsub->connect->get;
    ok $pubsub->is_connected, 'reconnected normally afterward';

    my $captured2 = capture_stderr(sub {
        kill_backends();
        wait_until(sub { !$pubsub->is_connected }, 'listener noticed again', 5);
    });
    is $captured2, '', 'the termination notice does not reach fd 2';
    ok scalar(grep { /FATAL:\s+terminating connection due to administrator command/ } @logged),
        'the termination notice reaches on_log instead';

    ok wait_until(sub {
        $pubsub->{_reconnect_future} && !$pubsub->{_reconnect_future}->is_ready
    }, 'a new supervisor starts after the next death', 5),
        'reconnect re-arms rather than staying permanently dead';

    $pubsub->disconnect->get;
};

subtest 'the listener keeps reading the connection it is polling' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 4,
    );
    my $pubsub = $pg->pubsub;

    my @got;
    $pubsub->listen('stale_conn_test', sub { push @got, $_[1] })->get;

    # Simulate what a reconnect does: replace the tracked connection while a
    # listener loop is already running against the original one. The loop
    # polls the original socket, so it must also read notifications from the
    # original connection, not from whatever {conn} happens to hold now.
    my $original = $pubsub->conn;
    my $usurper  = $pg->connection->get;
    $pubsub->{conn} = $usurper;

    $pubsub->notify('stale_conn_test', 'delivered')->get;
    wait_until(sub { @got }, 'notification arrived', 3);

    is \@got, ['delivered'],
        'a notification on the polled connection is still delivered';

    $pubsub->{conn} = $original;
    $usurper->release;
    $pubsub->disconnect->get;
};

done_testing;

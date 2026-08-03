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
use Future::AsyncAwait;
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

    # Checked after the assertion above rather than before it: a further
    # control query here would complete and restore {_stopping} through its
    # own guard, masking a broken _ListenerGuard on the cancelled one.
    is $pubsub->{_control_query}, undef, 'the cancelled control query freed its slot';

    $pubsub->notify('cancel_listen_a', 'still here')->get;
    wait_until(sub { @got }, 'notification after the cancelled listen', 3);

    is \@got, ['still here'], 'existing subscription still delivering';

    $pubsub->disconnect->get;
};

subtest 'a control query queued behind a cancelled one is woken, not stranded' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 3,
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('slot_seed', sub { })->get;

    my $holder = $pubsub->listen('slot_holder', sub { });   # claims the slot, suspends in its query
    my $queued = $pubsub->listen('slot_queued', sub { });   # parks in the mutex loop
    $holder->cancel;

    ok $queued->get, 'a control query parked behind a cancelled one is woken';
    is $pubsub->{_control_query}, undef, 'and the slot is free afterwards';

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

subtest 'a caller giving up does not fail another caller' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 3,
    );
    my $pubsub = $pg->pubsub;

    # Both arrive before either finishes, so they share one attempt. The
    # second gives up. The first never did, and must not be punished for it.
    my $first  = $pubsub->connect;
    my $second = $pubsub->connect;
    $second->cancel;

    my $err;
    my $ok = eval { $first->get; 1 };
    $err = $@ unless $ok;

    ok $ok, 'the caller that waited still connected'
        or diag "first caller failed with: $err";
    ok $pubsub->is_connected, 'and the object is connected';

    $pubsub->disconnect->get;
};

subtest 'abandoning the only connect releases everything' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 3,
    );
    my $pubsub = $pg->pubsub;

    # The last awaiter leaving must cancel the attempt, or the connection is
    # checked out for a caller that no longer exists.
    my $abandoned = $pubsub->connect;
    $abandoned->cancel;

    # A negative property, checked with the negative form: wait_until tests
    # its condition before ever sleeping, so asserting active_count == 0
    # here would pass at the instant connect() was called, before the TCP
    # handshake has run in any universe -- the leak this guards against has
    # not had a chance to happen yet, whether or not it ever will. Giving it
    # real wall-clock time to appear, and asserting it did not, is what
    # actually exercises the guarantee.
    ok !wait_until(sub { $pg->active_count > 0 }, 'a leaked checkout would appear here', 1),
        'no connection is left checked out';
    ok !$pubsub->is_connected, 'and the object is not left connected';

    $pubsub->disconnect->get;
};

subtest 'disconnecting during a connect does not leave it running' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 3,
    );
    my $pubsub = $pg->pubsub;

    # Start a connect and tear down before it can finish. Nothing may be left
    # checked out to an object that has been disconnected.
    my $connecting = $pubsub->connect;
    $pubsub->disconnect->get;

    # Give the abandoned attempt real wall-clock time to reach a terminal
    # state before checking anything downstream of it. disconnect() never
    # pumps the event loop here, so checking active_count/is_connected right
    # away would pass whether or not the attempt was ever actually
    # cancelled -- the leak this subtest is named for hasn't had a chance to
    # happen yet in either universe.
    ok wait_until(sub { $connecting->is_ready }, 'connect settled', 3),
        'the waiting caller was told';

    ok wait_until(sub { $pg->active_count == 0 }, 'checkout released', 3),
        'no connection is left checked out after disconnect';
    ok !$pubsub->is_connected, 'and the object is not connected';

    # A cancelled future surfaces as "Future=HASH(0x...) was cancelled",
    # which tells them nothing about what happened or whether it was their
    # fault.
    like $connecting->failure, qr/PubSub connect was cancelled/,
        'and told something that explains it';

    $connecting->cancel unless $connecting->is_ready;
};

# A regression in either of the next two subtests fails by *hanging*, not by
# a red assertion -- if one of them never finishes, that hang is the
# failure, not infrastructure flakiness.
subtest 'disconnecting cancels a control query in flight, not abandons it' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 3,
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('c1_seed', sub { })->get;

    # Not awaited: still suspended inside its own LISTEN query when
    # disconnect() below runs. Without a fix, disconnect() has no way to
    # know this query exists, releases {conn} out from under it, and the
    # mutex slot this query claimed is never freed -- every later control
    # query on this object parks in _run_control_query's while loop forever.
    my $in_flight = $pubsub->listen('c1_in_flight', sub { });

    $pubsub->disconnect->get;

    ok wait_until(sub { $in_flight->is_ready }, 'abandoned query settled', 3),
        'the abandoned control query settles rather than hanging forever';
    like $in_flight->failure, qr/PubSub is disconnecting/,
        'and says why, not a bare "Future=HASH(0x...) was cancelled"';
    ok !$pubsub->{_control_query}, 'and the mutex slot was not left claimed';

    ok $pubsub->listen('c1_after', sub { })->get,
        'a fresh listen() after disconnect is not stuck behind the abandoned one';

    $pubsub->disconnect->get;
};

subtest 'a control query queued behind one abandoned by disconnect is also woken cleanly' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 3,
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('c1q_seed', sub { })->get;

    # $holder claims the mutex slot and suspends in its own query; $queued
    # parks behind it in _run_control_query's while loop. Cancelling
    # $holder's query -- what disconnect() does below -- wakes $queued
    # synchronously, inside that same cancellation call, before disconnect()
    # has gone on to release {conn}. A waiter woken this way that cannot
    # tell teardown is underway would see {conn} still looking valid, issue
    # its own query on it, and then have disconnect() release that same
    # connection a moment later with the query still running -- corrupting
    # it for whichever caller the pool hands it to next.
    my $holder = $pubsub->listen('c1q_holder', sub { });
    my $queued = $pubsub->listen('c1q_queued', sub { });

    $pubsub->disconnect->get;

    # Unbounded rather than wait_until: this is the assertion that hangs,
    # not merely fails, if the queued waiter is left unable to tell
    # teardown is underway.
    my $ok  = eval { $queued->get; 1 };
    my $err = $@;
    ok !$ok, 'the queued query does not silently succeed once teardown is underway';
    like $err, qr/PubSub is disconnecting/, 'and reports why';
    ok !$pubsub->{_control_query}, 'and the mutex slot was not left claimed';

    # The real proof: a completely unrelated connection must still work.
    my $probe = $pg->connection->get;
    my $result = $probe->query('SELECT 1 AS n')->get;
    is $result->first->{n}, 1,
        'an unrelated connection from the pool is not corrupted by the abandoned query';
    $probe->release;
};

subtest 'abandoning a queued connect does not leave a waiter behind' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 1,
    );
    my $pubsub = $pg->pubsub;

    # With the only slot held, connect() has to queue behind it in the
    # pool rather than create a second connection -- this is the branch the
    # single-attempt version of this test above never reaches, where the
    # pool's own {waiting} array holds a reference to the queued future
    # independent of anything connect() itself is holding. Cancelling the
    # top-level future alone cannot free that entry; only the guard's
    # explicit ->cancel, propagating back through _establish and
    # connection(), reaches it.
    my $held = $pg->connection->get;

    my $queued = $pubsub->connect;
    ok wait_until(sub { $pg->waiting_count == 1 }, 'connect queued', 3),
        'connect actually queued behind the held connection';

    $queued->cancel;
    ok !$pubsub->is_connected, 'not left connected';

    # A cancelled waiter is only spliced out of {waiting} the next time the
    # pool has a connection to hand out -- _return_connection skips settled
    # entries lazily rather than the cancellation itself editing the array.
    # Releasing the held connection is what proves the guard's cancellation
    # actually reached the queued future, not just this object's own state.
    $held->release;

    ok wait_until(sub { $pg->waiting_count == 0 }, 'stale waiter cleared', 3),
        'no waiter left behind for the abandoned caller';
    ok wait_until(sub { $pg->active_count == 0 }, 'not handed to a ghost', 3),
        'the connection was not checked out to nobody';
    is $pg->idle_count, 1, 'the connection went back to idle instead';

    $pubsub->disconnect->get;
};

subtest 'a queued connect can be ->get directly, without polling first' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 1,
    );
    my $pubsub = $pg->pubsub;

    my $held = $pg->connection->get;

    # Release from a timer, so connect() below is still queued behind the
    # held connection -- not yet ready -- when ->get is called on it
    # directly. connect()'s shared attempt is _establish()'s own returned
    # future, whose class comes from whatever it first suspends on: before
    # the pool's queue branch was fixed to use pending_future, a caller
    # queued this way got back a future that could never block on ->get,
    # only croak "is not yet complete and does not provide ->await".
    my $releaser = Future::IO->sleep(0.1);
    $releaser->on_done(sub { $held->release });

    ok $pubsub->connect->get,
        'a connect queued behind pool exhaustion can be ->get directly';

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

subtest 'concurrent control queries on one connection are serialized, not raced' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
    );
    my $pubsub = $pg->pubsub;

    # Establishes the connection and its listener loop before the race, so
    # both calls below reach _run_control_query with nothing else left to
    # await first.
    $pubsub->listen('serial_seed', sub { })->get;

    # Two first-subscriptions fired back to back, with neither awaited before
    # the second is issued: each reaches _run_control_query wanting the same
    # connection at the same moment. Without serialization, DBD::Pg refuses
    # the second async query while the first is still in flight and this
    # fails outright rather than merely racing -- see the mutation check
    # below.
    my $f1 = $pubsub->listen('concurrent_a', sub { });
    my $f2 = $pubsub->listen('concurrent_b', sub { });

    my $ok1  = eval { $f1->get; 1 };
    my $err1 = $@;
    ok $ok1, 'first concurrent listen succeeded' or diag $err1;

    my $ok2  = eval { $f2->get; 1 };
    my $err2 = $@;
    ok $ok2, 'second concurrent listen succeeded' or diag $err2;

    is $pubsub->subscribed_channels, 3, 'all three channels registered';

    $pubsub->disconnect->get;
};

subtest 'a reconnect racing a listen takes only one connection' => sub {
    my @got_before;
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn                    => test_dsn(),
        min_connections        => 0,
        max_connections        => 5,
        reconnect              => 1,
        reconnect_min_interval => 0.1,
        reconnect_max_interval => 0.1,
        on_log                 => sub { push @logged, $_[1] },
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('race_before', sub { push @got_before, $_[1] })->get;

    # Delay exactly one pool checkout, so the listen() below is still in
    # flight when the supervisor wakes from its backoff. Real contention does
    # this for free but not reliably; forcing it makes the test deterministic.
    # The delay lives here rather than in the pool: production code does not
    # carry test scaffolding.
    my $orig      = Async::DBD::Pg->can('connection');
    my $delay_one = 1;
    no warnings 'redefine';
    local *Async::DBD::Pg::connection = sub {
        my ($pool) = @_;
        return $pool->$orig unless $delay_one;
        $delay_one = 0;
        return (async sub {
            await Future::IO->sleep(0.3);
            return await $pool->$orig;
        })->();
    };

    my $captured = capture_stderr(sub {
        kill_backends();

        # kill_backends is synchronous DBI and never turns the reactor, so
        # {connected} still reads stale here. Waiting for the listener to
        # notice is what actually starts the race: without it, the listen()
        # below would read the same stale flag, skip connect() entirely, and
        # try to issue LISTEN on the connection whose backend was just
        # killed.
        wait_until(sub { !$pubsub->is_connected }, 'listener noticed', 5);
    });
    is $captured, '', 'the termination notice does not reach fd 2';
    ok scalar(grep { /FATAL:\s+terminating connection due to administrator command/ } @logged),
        'the termination notice reaches on_log instead';

    # The supervisor is now backing off; this listen races it.
    $pubsub->listen('race_during', sub { })->get;

    ok wait_until(sub { $pubsub->is_connected }, 'reconnected', 5),
        'pub/sub came back';

    # A channel subscribed before the race must still deliver afterwards. If
    # two connections were taken, the listener loop polls one socket while
    # _process_notifications reads the other, and this notification is dropped
    # silently -- no error, no log line, and the subscription still reports
    # itself as active.
    $pubsub->notify('race_before', 'still here')->get;
    ok wait_until(sub { @got_before }, 'notification arrived', 5),
        'a channel subscribed before the race still delivers';

    $pubsub->disconnect->get;

    is $pg->active_count, 0,
        'no connection was orphaned by the race';
};

# A regression here fails by hanging or by a missing notification, not by a
# clean assertion -- if the listener never comes back, that silence is the
# failure, not infrastructure flakiness.
subtest 'a reconnect supervisor backing off is not fooled by an ordinary listen() pausing the listener' => sub {
    my @got_early;
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn                    => test_dsn(),
        min_connections        => 0,
        max_connections        => 5,
        reconnect              => 1,
        reconnect_min_interval => 0.5,
        reconnect_max_interval => 0.5,
        on_log                 => sub { push @logged, $_[1] },
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('i1_early', sub { push @got_early, $_[1] })->get;

    # Delay exactly one control query well past the backoff above, so
    # {_listener_paused} is still set when the supervisor wakes and checks
    # {_stopping}. Real contention does this for free -- the window widens
    # with the number of channels replayed on reconnect -- but not reliably
    # enough to test against; forcing it makes the test deterministic. The
    # delay lives here rather than in Connection.pm: production code does
    # not carry test scaffolding.
    my $orig_query = Async::DBD::Pg::Connection->can('query');
    my $delay_one  = 1;
    no warnings 'redefine';
    local *Async::DBD::Pg::Connection::query = sub {
        my ($conn, @args) = @_;
        return $conn->$orig_query(@args) unless $delay_one;
        $delay_one = 0;
        return (async sub {
            await Future::IO->sleep(1);
            return await $conn->$orig_query(@args);
        })->();
    };

    my $captured = capture_stderr(sub {
        kill_backends();
        wait_until(sub { !$pubsub->is_connected }, 'listener noticed', 5);
    });
    is $captured, '', 'the termination notice does not reach fd 2';
    ok scalar(grep { /FATAL:\s+terminating connection due to administrator command/ } @logged),
        'the termination notice reaches on_log instead';

    # Reconnects on its own and issues the delayed control query above,
    # pausing the listener for a full second -- long enough for the
    # supervisor's 0.5s backoff to elapse while it is still paused.
    $pubsub->listen('i1_late', sub { })->get;

    ok wait_until(sub { $pubsub->is_connected }, 'reconnected', 5),
        'pub/sub came back';

    # The real proof: a channel subscribed before the race must still
    # deliver. Before splitting {_stopping} from {_listener_paused}, the
    # supervisor woke mid-pause, read the shared flag as true, and exited
    # permanently believing it had been told to stop -- the listener never
    # restarted and this channel was never re-subscribed on the new
    # connection, with no error and no log line.
    $pubsub->notify('i1_early', 'still here')->get;
    ok wait_until(sub { @got_early }, 'notification arrived', 5),
        'a channel subscribed before the race still delivers';

    $pubsub->disconnect->get;
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

subtest 'the reconnect supervisor gives up when the pool is gone' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn                    => test_dsn(),
        min_connections        => 0,
        max_connections        => 3,
        reconnect              => 1,
        # Wide enough that the backoff sleep -- during which the supervisor
        # is suspended and _reconnect_future stays live -- comfortably spans
        # more than one of wait_until's own 0.05s polls below. At 0.05/0.05
        # the whole create-backoff-fail-giveup-delete cycle can complete
        # inside a single gap between polls: giving up is the fast path this
        # subtest exists to prove, so the future can vanish (deleted by its
        # own on_ready cleanup) before any poll ever observes it in flight,
        # failing the assertion below even though the supervisor behaved
        # correctly. Reproduced deterministically under IOAsync at 0.05/0.05
        # (5/5 runs); reliable at 0.3/0.3 (5/5 IOAsync, 3/3 UV).
        reconnect_min_interval => 0.3,
        reconnect_max_interval => 0.3,
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('no_pool_test', sub { })->get;

    my $reconnecting;

    # Once the pool is gone, _log has nowhere to send anything and falls back
    # to warn -- so the "giving up" message lands on file descriptor 2 rather
    # than on_log, and must be captured and asserted rather than allowed to
    # escape. That is also the point of the subtest: the supervisor cannot
    # ever succeed without a pool, so it must stop rather than log forever.
    my $captured = capture_stderr(sub {
        delete $pubsub->{pool};
        kill_backends();

        wait_until(
            sub {
                $reconnecting ||= $pubsub->{_reconnect_future};
                $reconnecting && $reconnecting->is_ready;
            },
            'supervisor finished', 5,
        );
    });

    ok $reconnecting && $reconnecting->is_ready,
        'the supervisor stopped instead of retrying forever';

    my @gave_up = ($captured =~ /giving up on reconnect/g);
    is scalar @gave_up, 1, 'it said so once, on the way out';

    # Restore the weak pool reference so the object is left in its ordinary
    # shape. disconnect() below never actually touches {pool}: {connected} and
    # {conn} are already both false here, cleared by the failed attempt's own
    # cleanup above, so it takes the early-return path with nothing left to
    # release.
    $pubsub->{pool} = $pg;
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

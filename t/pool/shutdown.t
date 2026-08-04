use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Time::HiRes qw(time);
use DBI;
use File::Temp qw(tempfile);

use lib 't/lib';
use Test::Async::DBD::Pg qw(skip_without_postgres test_dsn);

my $dsn = skip_without_postgres();

use Future::IO;

BEGIN { Future::IO->load_best_impl; }

use Async::DBD::Pg;
use Async::DBD::Pg::Util ();

sub make_pool {
    my (%args) = @_;
    return Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 2,
        %args,
    );
}

# Shutdown waits on plain Futures, which cannot drive the event loop the way
# a Future::IO one can, so the loop is pumped until they settle.
sub settle {
    my ($f, $timeout) = @_;

    $timeout //= 5;
    my $deadline = time + $timeout;

    while (!$f->is_ready && time < $deadline) {
        Future::IO->sleep(0.02)->get;
    }

    return $f;
}

# Killing a listener's backend makes the FATAL arrive via DBI's own
# PrintWarn calling Perl's warn() -- not a raw libpq write that bypasses
# warn() and $SIG{__WARN__} entirely. _capture_pg_notices intercepts it at
# the same site as any other server message, so it now reaches on_log
# instead of file descriptor 2. This descriptor-level helper stays
# regardless: it is what proves fd 2 stays empty, catching anything that
# lands there regardless of source, rather than assuming it does because
# the mechanism is understood. This closes and reopens STDERR onto a real
# file for the duration of $code and hands back what landed there,
# restoring STDERR on every path, including a die in $code.
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

subtest 'shutdown closes idle connections' => sub {
    my $pg = make_pool();

    my $conn = $pg->connection->get;
    $conn->release;
    is $pg->idle_count, 1, 'one connection idle';

    settle($pg->shutdown);

    is $pg->idle_count, 0, 'idle connections closed';
    is $pg->total_count, 0, 'pool empty';
};

subtest 'the pool refuses work once shut down' => sub {
    my $pg = make_pool();
    settle($pg->shutdown);

    my $err = dies { $pg->connection->get };

    ok $err, 'acquiring after shutdown fails';
    like $err, qr/shut down/i, 'the error says why';

    ok !$pg->is_healthy, 'a shut down pool is not healthy';
};

subtest 'shutdown is idempotent' => sub {
    my $pg = make_pool();
    my $conn = $pg->connection->get;
    $conn->release;

    settle($pg->shutdown);
    ok lives { settle($pg->shutdown) }, 'shutting down twice is harmless';
    is $pg->total_count, 0, 'still empty';
};

subtest 'shutdown waits for a connection still in use' => sub {
    my $pg = make_pool();

    my $held = $pg->connection->get;
    is $pg->active_count, 1, 'one connection checked out';

    my $shutdown = $pg->shutdown;

    # The connection is still being used, so the pool must not close it out
    # from underneath its owner.
    Future::IO->sleep(0.3)->get;
    ok !$shutdown->is_ready, 'shutdown waits while the connection is in use';

    my $result = $held->query('SELECT 1 AS n')->get;
    is $result->first->{n}, 1, 'the connection still works during the drain';

    $held->release;
    settle($shutdown);

    ok $shutdown->is_done, 'shutdown finished once the connection came back';
    is $pg->total_count, 0, 'pool empty';
};

subtest 'a forced shutdown does not wait' => sub {
    my $pg = make_pool();

    my $held = $pg->connection->get;
    is $pg->active_count, 1, 'one connection checked out';

    settle($pg->shutdown(force => 1), 3);

    is $pg->total_count, 0, 'connection closed without waiting for release';
};

subtest 'a drain that outlasts its timeout gives up waiting' => sub {
    my $pg = make_pool();

    my $held = $pg->connection->get;

    my $started = time;
    settle($pg->shutdown(timeout => 1), 5);
    my $elapsed = time - $started;

    ok $elapsed >= 0.9, 'waited for the timeout';
    ok $elapsed < 4, 'but gave up rather than waiting for a release';
    is $pg->total_count, 0, 'pool closed anyway';
};

subtest 'callers waiting in the queue are told' => sub {
    my $pg = make_pool(max_connections => 1, queue_timeout => 30);

    my $held = $pg->connection->get;
    my $queued = $pg->connection;

    Future::IO->sleep(0.1)->get;
    is $pg->waiting_count, 1, 'a caller is queued';

    my $shutdown = $pg->shutdown(force => 1);
    settle($queued, 3);

    ok $queued->is_failed, 'the queued caller is failed rather than left waiting';
    like $queued->failure, qr/shut(ting)? down/i, 'the failure says why';

    settle($shutdown, 3);
};

subtest 'work still in flight cannot revive a closed pool' => sub {
    my $pg = make_pool(
        on_release => async sub {
            # Cleanup that is still running when shutdown is called.
            await Future::IO->sleep(0.4);
        },
    );

    my $conn = $pg->connection->get;
    $conn->release;

    # Releasing a connection finishes in the background, so a shutdown can
    # start while that work is still going.
    settle($pg->shutdown, 5);

    ok $pg->is_shut_down, 'pool reports shut down';
    is $pg->total_count, 0, 'pool empty when shutdown returns';

    # Whatever was in flight must not put a connection back afterwards.
    Future::IO->sleep(1)->get;

    is $pg->total_count, 0, 'still empty once the background work finished';
    is $pg->idle_count, 0, 'nothing returned to the idle list';
};

subtest 'shutdown gives back the pub/sub listener connection' => sub {
    my $pg = make_pool(max_connections => 3);
    my $pubsub = $pg->pubsub;

    $pubsub->listen('shutdown_test', sub { })->get;
    is $pg->active_count, 1, 'the listener holds a connection';

    settle($pg->shutdown, 5);

    is $pg->active_count, 0, 'listener connection accounted for';
    is $pg->total_count, 0, 'pool empty';
    ok !$pubsub->is_connected, 'pub/sub reports disconnected';
};

subtest 'shutdown refuses pub/sub work permanently, not just until reconnect' => sub {
    my $pg = make_pool(max_connections => 3);
    my $pubsub = $pg->pubsub;

    $pubsub->listen('shutdown_direct_seed', sub { })->get;
    settle($pg->shutdown, 5);

    # No public call shape reaches _run_control_query's teardown check here:
    # listen()/unlisten() both gate on {phase} eq 'live' before dispatching a
    # control query, and a fresh call is turned away earlier still, by the
    # pool's own shut-down guard in connection(). Reaching in directly is
    # deliberate white-box, the same idiom t/unit/pubsub.t already uses for
    # internal mechanisms -- it's the only way to exercise the check itself
    # rather than something further downstream.
    my $err = dies { $pubsub->_run_control_query('LISTEN shutdown_direct_probe')->get };
    # 'has been shut down', not 'is disconnecting'. This subtest's own name is
    # the reason: the refusal here is permanent, and reporting it with the
    # message disconnect() uses told a caller to retry something that will
    # never succeed. See the terminal-phase design spec.
    like $err, qr/PubSub has been shut down/,
        'refused as permanently shut, not as merely mid-teardown';
};

subtest 'shutdown completes while a listener is trying to reconnect' => sub {
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn                    => test_dsn(),
        min_connections        => 0,
        max_connections        => 4,
        reconnect              => 1,
        reconnect_min_interval => 1,
        reconnect_max_interval => 2,
        on_log                 => sub { push @logged, $_[1] },
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('shutdown_while_reconnecting', sub { })->get;

    # Kill the listener's connection, then shut down while the supervisor is
    # asleep between attempts. The FATAL notice libpq prints for the killed
    # backend lands during the sleep below, when the listener's poll notices
    # the connection died, so both are captured together.
    my $parsed = Async::DBD::Pg::Util::parse_dsn(test_dsn());
    my $captured = capture_stderr(sub {
        my $dbh = DBI->connect(
            $parsed->{dbi_dsn}, $parsed->{user}, $parsed->{password},
            { RaiseError => 1, PrintError => 0 },
        );
        # Scoped to this suite's own connections by application_name, which
        # Test::Async::DBD::Pg sets via PGAPPNAME. Without it this terminates
        # every connection to the database, including an unrelated
        # application's on a shared PostgreSQL -- and a second copy of this
        # suite's.
        $dbh->do(q{
            SELECT pg_terminate_backend(pid) FROM pg_stat_activity
             WHERE datname = current_database()
               AND pid <> pg_backend_pid()
               AND application_name = ?
        }, undef, $ENV{PGAPPNAME});
        $dbh->disconnect;

        Future::IO->sleep(0.3)->get;    # let it fail and start backing off
    });
    is $captured, '', 'the termination notice does not reach fd 2';
    ok scalar(grep { /FATAL:\s+terminating connection due to administrator command/ } @logged),
        'the termination notice reaches on_log instead';

    settle($pg->shutdown, 10);

    ok $pg->is_shut_down, 'shutdown completed';
    is $pg->total_count, 0, 'pool empty';

    # The backoff drawn above is [0.5, 1.0)s and shutdown lands 0.3s in, so a
    # supervisor left to wake up on its own would still be sleeping here --
    # only Task 4's cancel in _pool_shutdown settles it this promptly. Total
    # connection count alone cannot tell cancelled apart from merely
    # outlived, because the other two guards (the loop's own _stopping check
    # and connection()'s refusal once the pool is shutting down) keep the
    # symptom off the pool's stats regardless of whether the supervisor was
    # ever actually stopped. This checks the mechanism itself, not just the
    # invariant it protects.
    is $pubsub->{_reconnect_future}, undef,
        'the supervisor is cancelled promptly rather than left to expire on its own';

    # Nothing may reconnect afterwards and put a connection back.
    Future::IO->sleep(1.5)->get;
    is $pg->total_count, 0, 'still empty once the backoff would have elapsed';
};


subtest 'shutdown->get waits at the top level rather than croaking' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 2,
    );
    my $held = $pg->connection->get;
    is $pg->active_count, 1, 'a connection is checked out';

    # Released from a timer, so shutdown genuinely has to wait rather than
    # finding the pool already drained. Held in a lexical rather than ->retain
    # -- see gaps item 64 for why.
    my $releaser = Future::IO->sleep(0.2)->on_done(sub { $held->release });

    # The idiom a caller outside an async sub writes. The drain future was a
    # bare Future->new, whose top-level ->get croaks the moment it is not
    # already ready instead of pumping the reactor -- so this worked only when
    # the pool had nothing to wait for, which is when it is not needed.
    my $ok  = eval { $pg->shutdown->get; 1 };
    my $err = $@;

    ok $ok, 'shutdown->get waited for the checkout to come back'
        or diag "shutdown->get died: $err";
    is $pg->active_count, 0, 'and the pool drained';
};

done_testing;

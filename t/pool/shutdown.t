use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Time::HiRes qw(time);

use lib 't/lib';
use Test::Async::DBD::Pg qw(skip_without_postgres test_dsn);

my $dsn = skip_without_postgres();

use Future::IO;

BEGIN { Future::IO->load_best_impl; }

use Async::DBD::Pg;

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

done_testing;

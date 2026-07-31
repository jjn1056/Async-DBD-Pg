use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 't/lib';
use Test::Async::DBD::Pg qw(skip_without_postgres test_dsn);

# Skip if no PostgreSQL available
my $dsn = skip_without_postgres();

use Future::IO;

BEGIN { Future::IO->load_best_impl; }

use Async::DBD::Pg;

subtest 'create pool' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 1,
        max_connections => 5,
    );

    isa_ok $pg, 'Async::DBD::Pg';
    is $pg->min_connections, 1, 'min_connections';
    is $pg->max_connections, 5, 'max_connections';
};

subtest 'get connection from pool' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,  # Don't pre-create, we want to test explicit acquisition
        max_connections => 5,
    );

    my $conn = $pg->connection->get;
    isa_ok $conn, 'Async::DBD::Pg::Connection';

    is $pg->active_count, 1, 'connection is active';

    my $result = $conn->query('SELECT 1 AS one')->get;
    is $result->first->{one}, 1, 'query works';

    $conn->release;
    is $pg->active_count, 0, 'connection released';
    is $pg->idle_count, 1, 'connection returned to idle';
};

subtest 'connection reuse' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
    );

    my $conn1 = $pg->connection->get;
    my $conn1_dbh = $conn1->dbh;
    $conn1->release;

    my $conn2 = $pg->connection->get;
    is $conn2->dbh, $conn1_dbh, 'same connection reused';

    $conn2->release;
};

subtest 'multiple connections' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 3,
    );

    my $conn1 = $pg->connection->get;
    my $conn2 = $pg->connection->get;
    my $conn3 = $pg->connection->get;

    is $pg->active_count, 3, '3 active connections';
    is $pg->total_count, 3, '3 total connections';

    $conn1->release;
    $conn2->release;
    $conn3->release;

    is $pg->active_count, 0, 'all released';
    is $pg->idle_count, 3, 'all idle';
};

subtest 'pool stats' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 2,
    );

    my $conn = $pg->connection->get;
    ok $pg->stats->{created} >= 1, 'created stat incremented';

    $conn->release;
    ok $pg->stats->{released} >= 1, 'released stat incremented';
};

subtest 'on_connect callback' => sub {
    my $connected = 0;

    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 2,
        on_connect      => async sub {
            my ($conn) = @_;
            $connected++;
            await $conn->query("SET application_name = 'test_app'");
        },
    );

    my $conn = $pg->connection->get;
    is $connected, 1, 'on_connect called';

    my $result = $conn->query("SHOW application_name")->get;
    is $result->first->{application_name}, 'test_app', 'on_connect query executed';

    $conn->release;
};

# A caller that has to queue waits on a plain Future, which cannot drive the
# event loop the way a Future::IO one can, so the loop is pumped here until
# the future settles.
sub settle {
    my ($f, $timeout) = @_;

    $timeout //= 5;
    my $deadline = time + $timeout;

    while (!$f->is_ready && time < $deadline) {
        Future::IO->sleep(0.05)->get;
    }

    return $f;
}

subtest 'waiting past queue_timeout fails with Error::PoolExhausted' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 1,
        queue_timeout   => 1,
    );

    my $held = $pg->connection->get;

    my $queued = settle($pg->connection);

    ok $queued->is_failed, 'a caller that waits too long fails';
    my $err = $queued->failure;
    isa_ok $err, 'Async::DBD::Pg::Error::PoolExhausted';
    is $err->pool_size, 1, 'error reports the limit that was reached';
    like $err->message, qr/exhausted/i, 'message explains the failure';
    is $pg->stats->{timeouts}, 1, 'timeout counted';

    # The pool has to keep working once the queue drains.
    is $pg->waiting_count, 0, 'timed out caller left the queue';
    $held->release;

    my $next = $pg->connection->get;
    ok $next, 'connection available again once released';
    $next->release;
};

subtest 'a queued caller is served when a connection frees up' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 1,
        queue_timeout   => 30,
    );

    my $held = $pg->connection->get;
    my $queued = $pg->connection;

    Future::IO->sleep(0.1)->get;
    ok !$queued->is_ready, 'second caller is waiting';
    is $pg->waiting_count, 1, 'and is on the queue';

    $held->release;
    settle($queued);

    my $conn = $queued->get;
    ok $conn, 'queued caller received the released connection';
    is $pg->waiting_count, 0, 'queue drained';

    my $r = $conn->query('SELECT 1 AS n')->get;
    is $r->first->{n}, 1, 'handed over connection works';

    $conn->release;
};

subtest 'on_release runs before a connection is reused' => sub {
    my @released;
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 1,
        on_release      => async sub {
            my ($conn) = @_;
            push @released, $conn->query_count;
            await $conn->query('SELECT 1');
        },
    );

    my $conn = $pg->connection->get;
    $conn->query('SELECT 1')->get;
    $conn->release;

    Future::IO->sleep(0.2)->get;

    is scalar @released, 1, 'on_release called once';
    is $pg->idle_count, 1, 'connection returned after the callback ran';

    $pg->connection->get->release;
};

subtest 'a connection whose on_release dies is discarded' => sub {
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 2,
        on_log          => sub { push @logged, $_[1] },
        on_release      => async sub { die "cleanup failed\n" },
    );

    my $conn = $pg->connection->get;
    $conn->release;

    Future::IO->sleep(0.2)->get;

    is $pg->idle_count, 0, 'connection not returned to the pool';
    is $pg->stats->{discarded}, 1, 'connection discarded instead';
    ok scalar(grep { /cleanup failed/ } @logged), 'failure reported';
};

subtest 'concurrent acquisition never exceeds max_connections' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 2,
        queue_timeout   => 30,
    );

    # Ask for more connections than the pool may hold, all before any of them
    # has finished connecting. Each caller must account for the connections
    # already on their way, not just the ones that have arrived.
    my @waiting = map { $pg->connection } 1 .. 6;

    Future::IO->sleep(1)->get;    # let the handshakes finish

    ok $pg->total_count <= 2,
        'pool never grew past max_connections (got ' . $pg->total_count . ')';

    my @acquired = grep { $_->is_done } @waiting;
    is scalar @acquired, 2, 'exactly max_connections callers were served';

    $_->cancel for grep { !$_->is_ready } @waiting;
    $_->get->release for @acquired;
};

subtest 'a waiter that gives up does not consume a connection' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 1,
        queue_timeout   => 30,
    );

    my $held = $pg->connection->get;
    is $pg->active_count, 1, 'the only connection is in use';

    # A second caller queues, then gives up before one becomes free.
    my $queued = $pg->connection;
    Future::IO->sleep(0.1)->get;
    is $pg->waiting_count, 1, 'second caller queued';
    $queued->cancel;

    # Handing the connection to the abandoned waiter would lose it: it goes
    # onto the active list and nobody is left to release it.
    $held->release;
    Future::IO->sleep(0.2)->get;

    is $pg->active_count, 0, 'connection not parked against the abandoned waiter';
    is $pg->idle_count, 1, 'connection returned to the pool';
    ok $pg->is_healthy, 'pool can still serve';

    my $next = $pg->connection->get;
    ok $next, 'connection can be acquired again';
    $next->release;
};

subtest 'an abandoned cursor does not outlive its connection' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 1,
    );

    my $conn = $pg->connection->get;

    my $cursor = $conn->cursor(
        'SELECT generate_series(1, 100) AS n',
        { batch_size => 10, name => 'leak_cursor' }
    )->get;
    $cursor->next->get;

    my $open = $conn->query(
        "SELECT count(*) AS n FROM pg_cursors WHERE name = 'leak_cursor'"
    )->get;
    is $open->first->{n}, 1, 'cursor is open on the server';

    # Drop the cursor without closing it. The connection is left holding an
    # open transaction, and the cursor lives until that transaction ends.
    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, join '', @_ };
        undef $cursor;
    }
    like \@warnings, array { item match qr/cursor/i; etc },
        'abandoning an unclosed cursor is reported';

    $conn->release;
    Future::IO->sleep(0.2)->get;    # let the asynchronous reset finish

    my $again = $pg->connection->get;
    my $after = $again->query(
        "SELECT count(*) AS n FROM pg_cursors WHERE name = 'leak_cursor'"
    )->get;
    # A cursor declared without WITH HOLD only lives as long as the
    # transaction that declared it, so its disappearance is also proof that
    # the transaction was ended rather than handed on to the next borrower.
    is $after->first->{n}, 0, 'cursor reclaimed when the connection was reset';

    $again->release;
};

subtest 'safe_dsn masks password' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => 'postgresql://user:secret@localhost/db',
        min_connections => 0,
        max_connections => 1,
    );

    is $pg->safe_dsn, 'postgresql://user:***@localhost/db', 'password masked';
};

done_testing;

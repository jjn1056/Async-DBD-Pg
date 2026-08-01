use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use DBI;
use File::Temp ();
use Scalar::Util qw(refaddr);

use lib 't/lib';
use Test::Async::DBD::Pg qw(skip_without_postgres test_dsn);

# Skip if no PostgreSQL available
my $dsn = skip_without_postgres();

use Future::IO;

BEGIN { Future::IO->load_best_impl; }

use Async::DBD::Pg;
use Async::DBD::Pg::Util ();

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
    is refaddr($conn2->dbh), refaddr($conn1_dbh), 'same connection reused';

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

subtest 'giving up while connecting does not consume pool capacity' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 2,
        queue_timeout   => 5,
    );

    # A caller that cancels while the handshake is still running must not
    # leave the pool counting a connection that is never going to arrive.
    for my $n (1 .. 3) {
        my $f = $pg->connection;
        $f->cancel;
    }

    is $pg->total_count, 0, 'no connections left behind';

    my $conn = $pg->connection->get;
    ok $conn, 'pool still hands out connections';

    my $result = $conn->query('SELECT 1 AS n')->get;
    is $result->first->{n}, 1, 'and they work';

    $conn->release;

    # Capacity has to be genuinely intact, not just enough for one.
    my $a = $pg->connection->get;
    my $b = $pg->connection->get;
    ok $a && $b, 'both connection slots still usable';
    $_->release for $a, $b;
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

sub capture_stderr {
    my ($code) = @_;

    my ($fh, $path) = File::Temp::tempfile(UNLINK => 1);
    close $fh;

    open my $saved, '>&', \*STDERR or die "dup stderr: $!";
    open STDERR, '>', $path or die "redirect stderr: $!";

    my $ok = eval { $code->(); 1 };
    my $err = $@;

    open STDERR, '>&', $saved or die "restore stderr: $!";
    close $saved;

    die $err unless $ok;

    open my $read, '<', $path or die "read captured stderr: $!";
    local $/;
    my $captured = <$read>;
    close $read;

    return $captured;
}

sub kill_all_backends {
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

subtest 'a connection that died while idle is repaired, not reported' => sub {
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 3,
        on_log          => sub { push @logged, $_[1] },
    );

    my $conn = $pg->connection->get;
    $conn->query('SELECT 1')->get;
    $conn->release;

    # Nothing polls this connection's socket while it sits idle, so nothing
    # reads the pending FATAL notice during this window -- it is read later,
    # inside _heal_if_dead's ping, once the connection is checked out again.
    # That later read does not raise a raw fd2 print either: confirmed by
    # running the whole file with the real process stderr captured
    # separately from this window, not just by reading this one empty.
    my $captured = capture_stderr(sub {
        kill_all_backends();
        Future::IO->sleep(0.2)->get;
    });
    is $captured, '', 'nothing is read from the idle socket during the kill';

    my $again = $pg->connection->get;
    my $before = $again->dbh;

    # The caller must not see the pool's problem.
    my $result = $again->query('SELECT 42 AS answer')->get;
    is $result->first->{answer}, 42, 'statement ran despite the dead connection';

    isnt refaddr($again->dbh), refaddr($before), 'the handle was replaced';
    ok scalar(grep { /dead/i } @logged), 'the replacement was reported';

    $again->release;
};

subtest 'a transaction whose connection dies reports the failure to the caller' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 3,
        on_log          => sub { },
    );

    my $conn = $pg->connection->get;
    $conn->query('SELECT 1')->get;

    my $err = dies {
        $conn->transaction(async sub {
            my ($tx) = @_;
            await $tx->query('SELECT 1');

            # Same as the other windows in this file: nothing polls this
            # connection's socket during the kill, so nothing is read here.
            # Confirmed by running.
            my $c17 = capture_stderr(sub {
                kill_all_backends();
                Future::IO->sleep(0.2)->get;
            });
            is $c17, '', 'nothing is read from the socket during the kill';

            # The transaction died with the connection. As the code stands, a
            # connection can never reach the liveness check with
            # in_transaction true: the check fires only once, on the first
            # statement after an idle checkout, and that first statement is
            # always BEGIN, which runs before in_transaction is set. This
            # asserts the failure still reaches the caller regardless -- a
            # future change that armed the check more than once per checkout
            # would need this to keep holding.
            await $tx->query('SELECT 2');
        })->get;
    };

    ok $err, 'the failure reaches the caller';

    $conn->release;
};

subtest 'a syntax error on a live connection is reported as itself' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 2,
        on_log          => sub { },
    );

    my $conn = $pg->connection->get;
    my $before = $conn->dbh;

    my $err = dies { $conn->query('SELECT * FROM no_such_table_here')->get };

    isa_ok $err, 'Async::DBD::Pg::Error::Query';
    is refaddr($conn->dbh), refaddr($before), 'the connection was not replaced';

    $conn->release;
};

subtest 'a connection that dies while its result is awaited fails to the caller' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 3,
        on_log          => sub { },
    );

    my $conn = $pg->connection->get;
    my $before = $conn->dbh;

    # An error reaching the caller and the connection object staying the same
    # are both consequences of the statement not being repeated, not
    # observations of it -- neither would notice a repeat that itself failed,
    # or one whose side effect landed before it failed. A probe table gives
    # the statement a side effect that can be counted afterward from a
    # separate connection, which observes the property the feature is
    # organised around directly: did this run twice.
    # Named per pid rather than guarded with IF EXISTS: the latter's harmless
    # NOTICE still reaches DBI's PrintWarn and prints to stderr, which this
    # suite's zero-byte requirement does not forgive just because the text
    # is benign.
    my $probe = 'heal_probe_' . $$;
    $conn->query("CREATE TABLE $probe (tag text)")->get;

    # Kill the backend while the statement is in flight. execute already
    # succeeded, so the statement reached the server and may have run.
    # Nothing after execute is ever retried, so this is never repeated.
    my $slow = $conn->query(
        "INSERT INTO $probe (tag) SELECT 'already-sent' FROM pg_sleep(3)"
    );

    # Unlike the pub/sub listener, which polls pg_notifies in a loop and
    # picks up unsolicited notices that way, the ordinary async query path
    # (pg_ready/pg_result) surfaces the FATAL as the query's own error
    # without a separate raw fd2 print. Confirmed by running: nothing lands
    # here even though the failing $slow->get is inside this window.
    my $err;
    my $c19 = capture_stderr(sub {
        Future::IO->sleep(0.3)->get;
        kill_all_backends();
        $err = dies { $slow->get };
    });
    is $c19, '', 'the failure is reported through the exception, not fd2';

    ok $err, 'the failure reaches the caller';
    is refaddr($conn->dbh), refaddr($before), 'the connection object is unchanged';

    # The killed backend aborts the in-flight insert, so the honest count is
    # 0; a re-execution on a replacement connection would commit and make it
    # 1. Checked from a fresh connection, since $conn's own is dead.
    my $parsed = Async::DBD::Pg::Util::parse_dsn(test_dsn());
    my $checker = DBI->connect(
        $parsed->{dbi_dsn}, $parsed->{user}, $parsed->{password},
        { RaiseError => 1, PrintError => 0 },
    );
    my ($count) = $checker->selectrow_array("SELECT count(*) FROM $probe");
    is $count, 0, 'the statement never ran';
    $checker->do("DROP TABLE $probe");
    $checker->disconnect;

    $conn->release;
};

subtest 'the caller still sees the failure once the pool is marked shutting down' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 3,
        on_log          => sub { },
    );

    my $conn = $pg->connection->get;
    $conn->query('SELECT 1')->get;
    $conn->release;

    my $c20 = capture_stderr(sub {
        kill_all_backends();
        Future::IO->sleep(0.2)->get;
    });
    is $c20, '', 'nothing is read from the idle socket during the kill';

    # Re-acquiring from idle is what arms the liveness check, so the guard
    # under test is actually reached this time. The flag has to be set after
    # acquiring rather than before: connection() refuses outright once
    # _shutting_down is true, so setting it first would never get this far.
    my $again = $pg->connection->get;
    $pg->{_shutting_down} = 1;

    my $before = $again->dbh;
    ok dies { $again->query('SELECT 1')->get },
        'the error reaches the caller';
    is refaddr($again->dbh), refaddr($before), 'the connection object is unchanged';

    $pg->{_shutting_down} = 0;
    $again->release;
};

subtest 'healing can be turned off' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn                   => test_dsn(),
        min_connections       => 0,
        max_connections       => 3,
        heal_dead_connections => 0,
        on_log                => sub { },
    );

    my $conn = $pg->connection->get;
    $conn->query('SELECT 1')->get;
    $conn->release;

    my $c21 = capture_stderr(sub {
        kill_all_backends();
        Future::IO->sleep(0.2)->get;
    });
    is $c21, '', 'nothing is read from the idle socket during the kill';

    my $again = $pg->connection->get;
    ok dies { $again->query('SELECT 1')->get },
        'the original error propagates when healing is off';
};

done_testing;

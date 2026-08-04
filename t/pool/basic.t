use strict;
use warnings;
use Test2::V0;
use Future;
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

# Drives the loop until a future settles, without propagating its result
# the way ->get would. Several tests below want to observe that a queued
# future has become ready -- for example to assert on the pool's state at
# that exact point -- before going on to read the value themselves.
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

subtest 'a queued caller can ->get its future directly, without settling first' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 1,
        queue_timeout   => 5,
    );

    my $held = $pg->connection->get;

    # Release from a timer, so the request below is still queued -- not yet
    # ready -- at the moment ->get is called on it directly. This is the
    # documented, synchronous way every other example in this file acquires
    # a connection; a caller genuinely queued behind another needs to be
    # able to use it too, blocking on pending_future's reactor-aware ->await
    # (see Async::DBD::Pg::Util) rather than only succeeding when the future
    # happens to already be ready.
    my $releaser = Future::IO->sleep(0.1);
    $releaser->on_done(sub { $held->release });

    my $conn = $pg->connection->get;
    ok $conn, 'a queued connection request can be ->get directly';

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
    # Scoped to this suite's own connections by application_name, which
    # Test::Async::DBD::Pg sets via PGAPPNAME. Without it this terminates
    # every connection to the database, including an unrelated application's
    # on a shared PostgreSQL -- and a second copy of this suite's.
    $dbh->do(q{
        SELECT pg_terminate_backend(pid) FROM pg_stat_activity
         WHERE datname = current_database()
           AND pid <> pg_backend_pid()
           AND application_name = ?
    }, undef, $ENV{PGAPPNAME});
    $dbh->disconnect;
    return;
}

sub wait_until {
    my ($code, $label, $timeout) = @_;

    $timeout //= 1;
    my $deadline = time + $timeout;

    while (time < $deadline) {
        return 1 if $code->();
        Future::IO->sleep(0.02)->get;
    }

    return $code->() ? 1 : 0;
}

# True if any of the given backend pids are still visible in
# pg_stat_activity. pg_terminate_backend sends a signal and returns as soon
# as it is sent, not once the backend has actually exited, so this is what a
# wait for "actually gone" polls -- a fresh, throwaway connection each call,
# never one of the pool's own, so it cannot itself become a target the next
# kill_all_backends call reaches, and never touches the idle connections
# under test.
sub backends_alive {
    my (@pids) = @_;
    return 0 unless @pids;

    my $parsed = Async::DBD::Pg::Util::parse_dsn(test_dsn());
    my $dbh = DBI->connect(
        $parsed->{dbi_dsn}, $parsed->{user}, $parsed->{password},
        { RaiseError => 1, PrintError => 0 },
    );
    my $placeholders = join ',', ('?') x @pids;
    my ($count) = $dbh->selectrow_array(
        "SELECT count(*) FROM pg_stat_activity WHERE pid IN ($placeholders)",
        undef, @pids,
    );
    $dbh->disconnect;

    return $count > 0;
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
    my $created_before   = $pg->stats->{created};
    my $discarded_before = $pg->stats->{discarded};

    # The caller must not see the pool's problem.
    my $result = $again->query('SELECT 42 AS answer')->get;
    is $result->first->{answer}, 42, 'statement ran despite the dead connection';

    isnt refaddr($again->dbh), refaddr($before), 'the handle was replaced';
    ok scalar(grep { /dead/i } @logged), 'the replacement was reported';

    # The Connection never leaves the active list and _replace_dbh takes no
    # _ConnectingGuard, so a heal should be invisible to the pool's own
    # counts apart from the created/discarded pair it is.
    is $pg->stats->{created}, $created_before + 1, 'the replacement is counted as created';
    is $pg->stats->{discarded}, $discarded_before + 1, 'the dead handle is counted as discarded';
    is $pg->active_count, 1, 'the connection never left the active list';
    is $pg->total_count, 1, 'and the pool total is unaffected by the heal';

    $again->release;
};

subtest 'a healthy connection is never pinged' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 1,
        on_log          => sub { },
    );

    my $conn = $pg->connection->get;
    $conn->query('SELECT 1')->get;
    $conn->release;

    my $again = $pg->connection->get;    # idle checkout, arms _check_liveness

    # The free zero-timeout select is what the whole design's cost claim
    # rests on: it is what decides whether the round trip happens at all.
    # Spied on the real ping method rather than faked, so this exercises the
    # actual DBI call the design depends on not making, not a stand-in for
    # it. Scoped to just the query -- release() has its own, separate,
    # pre-existing validation ping, unrelated to healing, that would
    # otherwise be counted here too.
    my $pings = 0;
    {
        no warnings 'redefine';
        my $orig = \&DBD::Pg::db::ping;
        local *DBD::Pg::db::ping = sub { $pings++; goto &$orig };
        $again->query('SELECT 1')->get;
    }

    is $pings, 0, 'no round trip on a healthy checkout';

    $again->release;
};

subtest 'healing invalidates the cached poll socket on the connection' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 1,
        on_log          => sub { },
    );

    my $conn = $pg->connection->get;
    $conn->query('SELECT 1')->get;    # populates _cached_sock / _cached_fd

    ok exists $conn->{_cached_sock}, 'the poll cache is populated before healing';

    $pg->_replace_dbh($conn)->get;

    # This call doesn't go through a real dead connection -- $conn was never
    # actually killed, so its old fd is still open when _create_connection
    # runs and the replacement is unlikely to land on the same number here.
    # That's fine for what this checks: the two deletes run unconditionally,
    # so whether they're doing anything on this particular call is beside the
    # point. What they're *for* is checked below, on a connection that really
    # was healed, where the collision is not a corner case -- see there for
    # why a check that merely compared fd numbers would still miss it.
    ok !exists $conn->{_cached_sock}, 'the transplant invalidates the poll cache';
    ok !exists $conn->{_cached_fd}, 'and the cached fd number with it';

    $conn->release;
};

subtest 'a healed connection does not busy-wait on its old socket' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 1,
        on_log          => sub { },
    );

    my $conn = $pg->connection->get;
    $conn->query('SELECT 1')->get;    # populates _cached_sock / _cached_fd
    $conn->release;

    my $captured = capture_stderr(sub {
        kill_all_backends();
        Future::IO->sleep(0.2)->get;
    });
    is $captured, '', 'nothing is read from the idle socket during the kill';

    my $again = $pg->connection->get;    # re-acquire, arms _check_liveness

    # On this path -- a connection actually found dead and healed --
    # _heal_if_dead's ping has already made libpq close the old socket before
    # _replace_dbh runs, so the fd number is free beforehand and the
    # replacement commonly reuses it. A check that only compared fd numbers
    # would not catch a stale cache here, because the number is the same
    # whether or not the entry was cleared. What differs is what a dup of
    # that number reads as: a stale cache hands _wait_for_result a dup of the
    # socket that was already closed, which reports readable at EOF, so the
    # poll loop spins for the life of every query on the connection instead
    # of waiting once. Counting the polls catches that regardless of the fd
    # numbers, which is why it's the assertion here rather than a repeat of
    # the identity check above.
    my $polls = 0;
    {
        no warnings 'redefine';
        my $orig = \&Future::IO::poll;
        local *Future::IO::poll = sub { $polls++; goto &$orig };
        $again->query('SELECT pg_sleep(0.5) AS answer')->get;
    }

    ok $polls < 200, "few poll calls on the healed connection (got $polls)";

    $again->release;
};

subtest 'finding one dead connection discards its idle siblings' => sub {
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 3,
        on_log          => sub { push @logged, $_[1] },
    );

    my $conn1 = $pg->connection->get;
    my $conn2 = $pg->connection->get;
    my $held  = $pg->connection->get;    # stays checked out through the heal
    $conn1->query('SELECT 1')->get;
    $conn2->query('SELECT 1')->get;
    $held->query('SELECT 1')->get;

    # pg_pid is a cached attribute recorded at connect time, not a live read,
    # so fetching it here does not touch the socket -- it does not disturb
    # the "nothing is read from the idle sockets" property this subtest goes
    # on to test below.
    my ($pid1, $pid2) = ($conn1->dbh->{pg_pid}, $conn2->dbh->{pg_pid});

    $conn1->release;
    $conn2->release;

    is $pg->idle_count, 2, 'both connections idle before the kill';
    is $pg->active_count, 1, 'the third connection stays checked out';

    my $captured = capture_stderr(sub {
        kill_all_backends();

        # pg_terminate_backend sends the signal and returns as soon as it is
        # sent, not once the backend has actually exited -- a fixed sleep
        # here is a guess at how long that takes. Wait for the two specific
        # backends this subtest depends on to actually be gone instead,
        # checked through a separate, throwaway connection (backends_alive)
        # that never touches conn1's or conn2's own idle sockets.
        wait_until(sub { !backends_alive($pid1, $pid2) },
            'both idle backends actually gone', 5);
    });
    is $captured, '', 'nothing is read from the idle sockets during the kill';

    # kill_all_backends kills every other backend, including $held's, but
    # $held is never idle-checked-out, so nothing arms its liveness check and
    # _discard_idle_connections only ever touches the idle list -- it should
    # stay in the active list, dead handle and all, untouched by the discard.
    # (It gets discarded on release the ordinary way, by the existing
    # release-time ping, which is a different, already-tested path.)
    #
    # Re-acquiring takes one of the two idle connections and arms its
    # liveness check, leaving the other sitting idle -- also dead, but not
    # yet discovered. Querying is what triggers the heal, and with it the
    # sibling discard.
    my $again = $pg->connection->get;
    $again->query('SELECT 1')->get;

    is $pg->idle_count, 0,
        'the sibling was discarded too, not left for a later caller to rediscover';
    is $pg->active_count, 2,
        'the checked-out connection was left alone, not touched by the discard';
    ok scalar(grep { /discarded \d+ idle connection/ } @logged),
        'the sibling discard was reported through on_log';

    $held->release;

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

subtest 'a real SQL error on a live connection is reported as itself' => sub {
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
    #
    # Cleanup uses DROP TABLE IF EXISTS on a connection with PrintWarn off:
    # the NOTICE that statement emits on a table that doesn't exist yet
    # otherwise reaches DBI's PrintWarn and prints to stderr regardless of
    # $^W, which this suite's zero-byte requirement does not forgive just
    # because the text is benign. Cleaned up before creating too, not only
    # after, so a table a previous run's throw left behind under the same
    # reused pid doesn't fail this run's CREATE TABLE.
    my $parsed = Async::DBD::Pg::Util::parse_dsn(test_dsn());
    my $probe  = 'heal_probe_' . $$;
    my $connect_quiet = sub {
        return DBI->connect(
            $parsed->{dbi_dsn}, $parsed->{user}, $parsed->{password},
            { RaiseError => 1, PrintError => 0, PrintWarn => 0 },
        );
    };

    my $pre = $connect_quiet->();
    $pre->do("DROP TABLE IF EXISTS $probe");
    $pre->disconnect;

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

    # A bare ok $err would also pass if the statement were never dispatched
    # at all, so it does not confirm its own premise -- that this failure
    # arrived while awaiting the result of a statement already on the wire.
    like $err, qr/terminating connection|server closed/i,
        'the failure is the connection dying while its result was awaited';
    is refaddr($conn->dbh), refaddr($before), 'the connection object is unchanged';

    # The killed backend aborts the in-flight insert, so the honest count is
    # 0; a re-execution on a replacement connection would commit and make it
    # 1. Checked from a fresh connection, since $conn's own is dead.
    my $checker = $connect_quiet->();
    my ($count) = $checker->selectrow_array("SELECT count(*) FROM $probe");
    is $count, 0, 'the statement never ran';
    $checker->do("DROP TABLE IF EXISTS $probe");
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
    my $before = $again->dbh;
    ok dies { $again->query('SELECT 1')->get },
        'the original error propagates when healing is off';
    is refaddr($again->dbh), refaddr($before),
        'and the connection was not replaced -- this is the option actually being tested';

    $again->release;
};

subtest 'a PostgreSQL notice is routed through on_log, not fd 2' => sub {
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 1,
        on_log          => sub { push @logged, [$_[0], $_[1]] },
    );

    my $conn = $pg->connection->get;

    my $captured = capture_stderr(sub {
        $conn->query(
            q{DO $$ BEGIN RAISE NOTICE 'plain_notice_marker'; END $$}
        )->get;
    });

    is $captured, '', 'nothing reaches fd 2';
    ok scalar(grep { $_->[0] eq 'info' && $_->[1] =~ /plain_notice_marker/ } @logged),
        'on_log received the notice text at info level';

    $conn->release;
};

subtest 'a notice raised inside a transaction still reaches on_log' => sub {
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 1,
        on_log          => sub { push @logged, [$_[0], $_[1]] },
    );

    my $conn = $pg->connection->get;

    # transaction() takes a different path through query than a bare call
    # does, so the notice has to be shown to reach on_log from inside it too,
    # not just assumed to because the bare case does.
    #
    # capture_stderr wraps the whole transaction here, at the top level,
    # rather than nesting a second capture_stderr (with its own ->get) inside
    # the async transaction body. A ->get nested inside an already-running
    # async sub, on a future built from several awaits the way a query's is,
    # crashes under Future::IO::Impl::IOAsync -- "IO::Async::Future=HASH(...)
    # is already done and cannot be ->done" -- because it re-enters IOAsync's
    # reactor from inside one of its own callbacks. await does not have this
    # problem; a nested ->get does. See the design doc addendum.
    my $captured = capture_stderr(sub {
        $conn->transaction(async sub {
            my ($tx) = @_;
            await $tx->query(
                q{DO $$ BEGIN RAISE NOTICE 'tx_notice_marker'; END $$}
            );
        })->get;
    });

    is $captured, '', 'nothing reaches fd 2 from inside the transaction';
    ok scalar(grep { $_->[0] eq 'info' && $_->[1] =~ /tx_notice_marker/ } @logged),
        'on_log received the notice text from inside the transaction';

    $conn->release;
};

subtest 'concurrent notices on different connections all reach on_log' => sub {
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 2,
        on_log          => sub { push @logged, [$_[0], $_[1]] },
    );

    my $conn_a = $pg->connection->get;
    my $conn_b = $pg->connection->get;

    # This is the case a query-lifetime guard object would get wrong: its
    # constructor/destructor pair would be a global $SIG{__WARN__}
    # assignment held across every await the query makes, and two overlapping
    # queries would give nested guards. Guards nest correctly by pure luck
    # whenever they unwind in the same order they were built -- the bug needs
    # the *first*-built guard to finish, and so destroy, before the *second*
    # one does, breaking that stack discipline and restoring the wrong saved
    # value over the still-in-flight second guard's handler. So conn_a, whose
    # query starts first, is given the fast statement here, and conn_b the
    # slow one -- deliberately the pairing a guard gets wrong, not the one
    # that happens to still work. Wrapping only the one synchronous call that
    # can raise a notice, per _capture_pg_notices, never leaves a handler
    # installed across an await in the first place, so this holds regardless
    # of which one finishes first.
    my $fast = $conn_a->query(
        q{DO $$ BEGIN RAISE NOTICE 'concurrent_marker_fast'; END $$}
    );
    my $slow = $conn_b->query(
        q{DO $$ BEGIN PERFORM pg_sleep(0.3); RAISE NOTICE 'concurrent_marker_slow'; END $$}
    );

    my $captured = capture_stderr(sub {
        Future->wait_all($slow, $fast)->get;
    });

    is $captured, '', 'nothing reaches fd 2 from either connection';

    # wait_all above already blocks until both queries' own futures are
    # done, and _capture_pg_notices runs synchronously inside each one
    # before it resolves -- but waiting explicitly for @logged to hold each
    # marker, rather than trusting that internal ordering, removes the
    # assumption instead of relying on it.
    ok wait_until(sub { scalar grep { $_->[1] =~ /concurrent_marker_slow/ } @logged },
        'slow notice logged', 2),
        'the slower notice reached on_log';
    ok wait_until(sub { scalar grep { $_->[1] =~ /concurrent_marker_fast/ } @logged },
        'fast notice logged', 2),
        'the faster notice reached on_log';

    $conn_a->release;
    $conn_b->release;
};


subtest 'a cancelled queued caller is removed from the queue immediately' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 1,
    );
    my $held = $pg->connection->get;

    my @queued = map { $pg->connection } 1 .. 5;
    is $pg->waiting_count, 5, 'five callers queued behind the held connection';

    $_->cancel for @queued;

    # The pool sweeps its own queue_timeout expiries eagerly. A caller that
    # cancels -- its own deadline, an enclosing wait_any, a request handler
    # going away -- used to be left in place until the next release swept it
    # lazily. That inflated waiting_count exactly when the pool was saturated
    # and releases were rarest, which is when someone is reading the gauge.
    is $pg->waiting_count, 0,
        'cancelling clears them without waiting for a release';

    # The safety property the lazy sweep provided must survive: a connection
    # handed back must not go to a caller that has gone.
    $held->release;
    ok wait_until(sub { $pg->active_count == 0 }, 'not handed to a ghost', 3),
        'the released connection was not checked out to a cancelled caller';

    $pg->shutdown->get;
};

subtest 'cancelling one queued caller leaves the others queued' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 1,
    );
    my $held = $pg->connection->get;

    my @queued = map { $pg->connection } 1 .. 3;
    $queued[1]->cancel;

    is $pg->waiting_count, 2, 'only the cancelled one was removed';

    # And the survivors still work: the next release goes to one of them.
    $held->release;
    ok wait_until(sub { $queued[0]->is_ready || $queued[2]->is_ready },
                  'a survivor was served', 3),
        'a still-waiting caller received the released connection';

    $_->cancel for grep { !$_->is_ready } @queued;
    my $winner = (grep { $_->is_done } @queued)[0];
    $winner->get->release if $winner;
    $pg->shutdown->get;
};

done_testing;

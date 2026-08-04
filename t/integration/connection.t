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
use Async::DBD::Pg::Connection;
use Async::DBD::Pg::Util qw(parse_dsn);
use DBI;
use DBD::Pg qw(:async);

# Helper to create a connection
sub make_connection {
    my $parsed = parse_dsn(test_dsn());

    my $dbh = DBI->connect(
        $parsed->{dbi_dsn},
        $parsed->{user},
        $parsed->{password},
        {
            AutoCommit     => 1,
            RaiseError     => 1,
            PrintError     => 0,
            PrintWarn      => 1,
            pg_enable_utf8 => 1,
        }
    ) or die "Cannot connect: " . DBI->errstr;

    return Async::DBD::Pg::Connection->new(
        dbh => $dbh,
    );
}

subtest 'simple query' => sub {
    my $conn = make_connection();

    my $result = $conn->query('SELECT 1 + 1 AS sum')->get;

    is $result->first->{sum}, 2, 'query returns correct result';
    is $result->count, 1, 'one row';

    $conn->_close_dbh;
};

subtest 'query with positional placeholders' => sub {
    my $conn = make_connection();

    my $result = $conn->query('SELECT $1::int + $2::int AS sum', 3, 4)->get;

    is $result->first->{sum}, 7, 'positional placeholders work';

    $conn->_close_dbh;
};

subtest 'query with named placeholders' => sub {
    my $conn = make_connection();

    my $result = $conn->query(
        'SELECT :a::int + :b::int AS sum',
        { a => 10, b => 20 }
    )->get;

    is $result->first->{sum}, 30, 'named placeholders work';

    $conn->_close_dbh;
};

subtest 'multiple rows' => sub {
    my $conn = make_connection();

    my $result = $conn->query('SELECT generate_series(1, 5) AS n')->get;

    is $result->count, 5, 'five rows returned';
    is [ map { $_->{n} } @{$result->rows} ], [1, 2, 3, 4, 5], 'correct values';

    $conn->_close_dbh;
};

subtest 'query error' => sub {
    my $conn = make_connection();

    my $err;
    eval {
        $conn->query('SELECT * FROM nonexistent_table_xyz')->get;
    };
    $err = $@;

    ok $err, 'error thrown';
    isa_ok $err, 'Async::DBD::Pg::Error::Query';
    like $err->message, qr/nonexistent_table|does not exist/i, 'error mentions table';

    $conn->_close_dbh;
};

subtest 'results built from a live statement handle' => sub {
    my $conn = make_connection();

    # The unit tests build results with new_from_data. This exercises the
    # constructor that reads a real DBI handle: column order, row contents,
    # and finishing the handle.
    my $result = $conn->query(
        q{SELECT * FROM (VALUES (1, 'one'), (2, 'two')) AS t(id, word)}
    )->get;

    isa_ok $result, 'Async::DBD::Pg::Results';
    is $result->columns, ['id', 'word'], 'column names in the order selected';
    is $result->count, 2, 'row count';
    is $result->rows, [
        { id => 1, word => 'one' },
        { id => 2, word => 'two' },
    ], 'rows as hashrefs keyed by column';
    is $result->first, { id => 1, word => 'one' }, 'first row';
    is $result->scalar, 1, 'scalar takes the first column of the first row';
    ok !$result->is_empty, 'not empty';

    # A statement returning nothing still has columns.
    my $none = $conn->query('SELECT 1 AS n WHERE false')->get;
    is $none->count, 0, 'no rows';
    is $none->columns, ['n'], 'columns still reported';
    ok $none->is_empty, 'reports empty';
    is $none->first, undef, 'first is undef';
    is $none->scalar, undef, 'scalar is undef';

    # NULL must survive as undef rather than becoming an empty string.
    my $null = $conn->query('SELECT NULL::text AS nothing')->get;
    is $null->first->{nothing}, undef, 'NULL comes back as undef';

    $conn->_close_dbh;
};

subtest 'query errors carry PostgreSQL diagnostics' => sub {
    my $conn = make_connection();

    $conn->query(
        'CREATE TEMP TABLE diag (
            id    int primary key,
            email text CONSTRAINT diag_email_unique UNIQUE
         )'
    )->get;
    $conn->query("INSERT INTO diag VALUES (1, 'a\@example.com')")->get;

    my $err = dies {
        $conn->query("INSERT INTO diag VALUES (2, 'a\@example.com')")->get
    };

    isa_ok $err, 'Async::DBD::Pg::Error::Query';
    is $err->code, '23505', 'SQLSTATE recorded';
    is $err->state, 'unique_violation', 'SQLSTATE mapped to a state name';
    is $err->constraint, 'diag_email_unique', 'violated constraint named';
    like $err->detail, qr/already exists/i, 'detail carries the server explanation';
    is $err->table, 'diag', 'offending table named';
    ok defined $err->schema, 'schema populated';
    like $err->severity, qr/^ERROR$/i, 'severity populated';

    # detail previously came from pg_errorlevel, which is the verbosity
    # setting rather than any error text.
    unlike $err->detail, qr/^\d+$/, 'detail is not the verbosity setting';

    $conn->_close_dbh;
};

subtest 'syntax errors report their position' => sub {
    my $conn = make_connection();

    my $err = dies { $conn->query('SELECT * FROM WHERE')->get };

    isa_ok $err, 'Async::DBD::Pg::Error::Query';
    is $err->code, '42601', 'syntax error SQLSTATE';
    ok defined $err->position, 'statement position populated';
    ok $err->position > 0, 'position points into the statement';

    $conn->_close_dbh;
};

subtest 'query count increments' => sub {
    my $conn = make_connection();

    is $conn->query_count, 0, 'starts at 0';

    $conn->query('SELECT 1')->get;
    is $conn->query_count, 1, 'incremented after first query';

    $conn->query('SELECT 2')->get;
    is $conn->query_count, 2, 'incremented after second query';

    $conn->_close_dbh;
};

subtest 'scalar method' => sub {
    my $conn = make_connection();

    my $result = $conn->query('SELECT COUNT(*) FROM pg_tables')->get;

    ok $result->scalar > 0, 'scalar returns count value';

    $conn->_close_dbh;
};

subtest 'query completing inside its timeout returns normally' => sub {
    my $conn = make_connection();

    my $result = $conn->query('SELECT 42 AS answer', { timeout => 10 })->get;
    is $result->first->{answer}, 42, 'result returned when the query beats the timeout';

    $conn->_close_dbh;
};

subtest 'query exceeding its timeout fails with Error::Timeout' => sub {
    my $conn = make_connection();

    # An abandoned query must release its statement handle, or DBI warns that
    # the handle was cleared whilst still active when it is collected.
    my @warnings;
    my $err;
    {
        local $SIG{__WARN__} = sub { push @warnings, join '', @_ };
        $err = dies { $conn->query('SELECT pg_sleep(5)', { timeout => 0.5 })->get };
    }

    ok $err, 'slow query fails';
    isa_ok $err, 'Async::DBD::Pg::Error::Timeout';
    is $err->timeout, 0.5, 'error carries the timeout that was exceeded';
    is \@warnings, [], 'abandoned statement handle released without warnings'
        or diag("warnings: @warnings");

    $conn->_close_dbh;
};

subtest 'cancelling a query releases its statement handle' => sub {
    my $conn = make_connection();

    # Nothing after the await runs when a caller cancels, so the handle has
    # to be released from a destructor. Left held, it is collected while
    # still active and DBI says so.
    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, join '', @_ };

        my $abandoned = $conn->query('SELECT pg_sleep(5)');
        Future::IO->sleep(0.2)->get;
        $abandoned->cancel;

        # The next query reuses the slot, which is when a leaked handle is
        # collected and complains.
        my $next = $conn->query('SELECT 7 AS n')->get;
        is $next->first->{n}, 7, 'connection usable after the cancelled query';
    }

    is \@warnings, [], 'cancelled query left no statement handle behind'
        or diag("warnings: @warnings");

    $conn->_close_dbh;
};

subtest 'DML affecting no rows succeeds' => sub {
    my $conn = make_connection();

    $conn->query('CREATE TEMP TABLE dml_zero (id int primary key, name text)')->get;
    $conn->query("INSERT INTO dml_zero VALUES (1, 'one')")->get;

    # pg_result reports affected rows as the DBI '0E0', which is false
    # numerically but true in boolean context, so a statement that matches
    # nothing must not be mistaken for a failed one.
    my $updated = $conn->query('UPDATE dml_zero SET name = $1 WHERE id = $2', 'x', 999)->get;
    ok $updated, 'UPDATE matching no rows returns a result';
    is $updated->rows_affected, 0, 'UPDATE reports zero rows affected';

    my $deleted = $conn->query('DELETE FROM dml_zero WHERE id = $1', 999)->get;
    ok $deleted, 'DELETE matching no rows returns a result';
    is $deleted->rows_affected, 0, 'DELETE reports zero rows affected';

    my $conflicted = $conn->query(
        'INSERT INTO dml_zero VALUES (1, $1) ON CONFLICT DO NOTHING', 'dup'
    )->get;
    ok $conflicted, 'INSERT ... ON CONFLICT DO NOTHING returns a result';
    is $conflicted->rows_affected, 0, 'conflicting INSERT reports zero rows affected';

    # The row that was there must be untouched.
    my $check = $conn->query('SELECT name FROM dml_zero WHERE id = 1')->get;
    is $check->first->{name}, 'one', 'existing row unchanged';

    $conn->_close_dbh;
};

subtest 'event loop not blocked during query' => sub {
    my $conn = make_connection();

    my $ticks = 0;
    my $ticker = async sub {
        while (1) {
            await Future::IO->sleep(0.01);
            $ticks++;
        }
    }->();

    # Run a query that takes some time
    my $result = $conn->query("SELECT pg_sleep(0.1), 42 AS answer")->get;

    $ticker->cancel unless $ticker->is_ready;

    is $result->first->{answer}, 42, 'query completed';
    ok $ticks >= 3, "event loop ran during query (got $ticks ticks)";

    $conn->_close_dbh;
};

subtest 'a notice on a connection with no pool is not swallowed' => sub {
    # This connection was built directly, not through a pool, so there is no
    # on_log to route a notice through. _capture_pg_notices leaves
    # $SIG{__WARN__} untouched in that case rather than eating the notice --
    # losing it is worse than printing it -- so it still reaches whatever
    # handler is already in effect, exactly as it would without this feature.
    my $conn = make_connection();

    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings, join '', @_ };
        $conn->query(q{DO $$ BEGIN RAISE NOTICE 'nopool_marker'; END $$})->get;
    }

    ok scalar(grep { /nopool_marker/ } @warnings),
        'the notice still reaches a warning rather than being silently dropped';

    $conn->_close_dbh;
};

subtest '_result_ready reports readiness without throwing' => sub {
    my $pg   = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 2);
    my $conn = $pg->connection->get;
    my $dbh  = $conn->dbh;

    # Dispatched directly rather than through query(), which would wait for the
    # result and leave nothing to observe. This is the only state
    # _wait_for_result ever calls _result_ready in: a statement sent, no result
    # back yet. pg_ready returns false here -- it is the idle handle, which
    # nothing in production ever asks, that throws instead.
    my $sth = $dbh->prepare('SELECT pg_sleep(0.4)', { pg_async => PG_ASYNC });
    $sth->execute;

    ok !$conn->_result_ready, 'not ready while the statement is still running';

    Future::IO->sleep(0.8)->get;
    ok $conn->_result_ready, 'ready once the result has arrived';

    # Drained before anything else: leaving the handle active makes DBI warn on
    # disconnect, which would breach the suite's pristine-stderr requirement.
    $dbh->pg_result;
    $sth->finish;

    # With the result collected there is no async query left, so pg_ready
    # throws. _result_ready must absorb that and report ready -- a caller that
    # kept waiting here would spin forever.
    ok $conn->_result_ready, 'absorbs pg_ready throwing when no query is running';

    # Same contract when the handle is gone entirely. Built standalone rather
    # than checked out, so a connection with no dbh is never returned to the
    # pool.
    my $dead = Async::DBD::Pg::Connection->new(dbh => undef);
    ok $dead->_result_ready, 'reports ready when the handle is gone';

    $conn->release;
    $pg->shutdown->get;
};

done_testing;

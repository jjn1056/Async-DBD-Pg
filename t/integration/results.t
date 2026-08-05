use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 't/lib';
use Test::Async::DBD::Pg qw(skip_without_postgres test_dsn);

my $dsn = skip_without_postgres();

use Future::IO;

BEGIN { Future::IO->load_best_impl; }

use Async::DBD::Pg;
use Async::DBD::Pg::Connection;
use Async::DBD::Pg::Util qw(parse_dsn);
use DBI;

# The unit tests build results from data. These build them from a live
# statement handle, which is where the fetch order and the non-row guard
# actually matter.
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
            pg_enable_utf8 => 1,
        }
    ) or die "Cannot connect: " . DBI->errstr;

    return Async::DBD::Pg::Connection->new(dbh => $dbh);
}

subtest 'a self-join keeps every column' => sub {
    my $conn = make_connection();

    $conn->query('CREATE TEMP TABLE res_join (id int, name text)')->get;
    $conn->query(q{INSERT INTO res_join VALUES (1, 'Alice'), (2, 'Bob')})->get;

    # SELECT * across a join is the ordinary way to end up with two columns
    # of the same name. Storing rows as hashes lost two of these four.
    my $r = $conn->query(
        'SELECT * FROM res_join a JOIN res_join b ON b.id = a.id + 1'
    )->get;

    is $r->columns, ['id', 'name', 'id', 'name'], 'all four columns reported';
    is $r->count, 1, 'one joined row';
    is $r->arrays->[0], [1, 'Alice', 2, 'Bob'], 'all four values reachable';

    like dies { $r->rows },
        qr/Column 'id' appears 2 times at positions 0, 2/,
        'asking for hashes croaks rather than dropping two values';

    $conn->_close_dbh;
};

subtest 'types come back as PostgreSQL type names' => sub {
    my $conn = make_connection();

    my $r = $conn->query(q{
        SELECT 1::int AS a, 'x'::text AS b, 1.5::numeric AS c,
               true AS d, now()::date AS e, '{}'::jsonb AS f
    })->get;

    is $r->columns, ['a', 'b', 'c', 'd', 'e', 'f'], 'column names';
    is $r->types, ['int4', 'text', 'numeric', 'bool', 'date', 'jsonb'],
        'type names, aligned by position';

    $conn->_close_dbh;
};

subtest 'statements that return no rows' => sub {
    my $conn = make_connection();

    # The positional fetch dies on a statement with no result set, where the
    # hash form used to return nothing quietly. An empty NAME is the guard,
    # so every one of these has to be exercised rather than reasoned about.
    my $create = $conn->query('CREATE TEMP TABLE res_none (id int, tag text)')->get;
    is $create->columns, [], 'CREATE reports no columns';
    is $create->count, 0, 'no rows';
    ok $create->is_empty, 'empty';
    is $create->rows->size, 0, 'rows is an empty collection, not a croak';
    is $create->first, undef, 'first is undef';
    is $create->arrays->size, 0, 'arrays is empty too';

    my $insert = $conn->query(q{INSERT INTO res_none VALUES (1, 'a'), (2, 'b')})->get;
    is $insert->rows_affected, 2, 'INSERT reports rows affected';
    is $insert->count, 0, 'and no rows in hand';
    is $insert->columns, [], 'no columns';

    my $update = $conn->query(q{UPDATE res_none SET tag = 'z' WHERE id = 1})->get;
    is $update->rows_affected, 1, 'UPDATE reports rows affected';

    my $delete = $conn->query('DELETE FROM res_none WHERE id = 2')->get;
    is $delete->rows_affected, 1, 'DELETE reports rows affected';

    my $nothing = $conn->query('DELETE FROM res_none WHERE id = 999')->get;
    is $nothing->rows_affected, 0, 'matching nothing is 0, not an error';

    ok lives { $conn->query('DROP TABLE res_none')->get }, 'DROP works';

    $conn->_close_dbh;
};

subtest 'RETURNING behaves exactly like SELECT' => sub {
    my $conn = make_connection();

    $conn->query('CREATE TEMP TABLE res_ret (id serial PRIMARY KEY, tag text)')->get;

    my $star = $conn->query(
        q{INSERT INTO res_ret (tag) VALUES ('a'), ('b') RETURNING *}
    )->get;

    is $star->columns, ['id', 'tag'], 'RETURNING * reports columns';
    is $star->types, ['int4', 'text'], 'and types';
    is $star->count, 2, 'rows are in hand';
    ok !$star->is_empty, 'not empty';
    is $star->rows->[0]{tag}, 'a', 'rows as hashrefs';
    is $star->arrays->[1], [2, 'b'], 'and positionally';

    my $named = $conn->query(
        q{UPDATE res_ret SET tag = 'z' WHERE id = 1 RETURNING id, tag}
    )->get;
    is $named->columns, ['id', 'tag'], 'RETURNING a, b reports columns';
    is $named->single, { id => 1, tag => 'z' }, 'single row';

    # Legal SQL, and the same collapse a self-join would cause.
    my $twice = $conn->query(
        q{INSERT INTO res_ret (tag) VALUES ('c') RETURNING id, id}
    )->get;
    is $twice->columns, ['id', 'id'], 'both columns reported';
    is $twice->arrays->[0][0], $twice->arrays->[0][1], 'both values present';
    like dies { $twice->rows },
        qr/Column 'id' appears 2 times at positions 0, 1/,
        'and the hash view croaks';

    my $deleted = $conn->query('DELETE FROM res_ret RETURNING id')->get;
    is $deleted->count, 3, 'DELETE ... RETURNING yields the deleted rows';
    is $deleted->rows_affected, 3, 'and reports them affected';

    $conn->_close_dbh;
};

subtest 'walking a live result' => sub {
    my $conn = make_connection();

    my $r = $conn->query(
        q{SELECT * FROM (VALUES (1, 'one'), (2, 'two'), (3, 'three')) AS t(n, word)}
    )->get;

    my @words;
    while (my $row = $r->next) {
        push @words, $row->{word};
    }
    is \@words, ['one', 'two', 'three'], 'next walks every row';

    $r->reset;
    is $r->next->{word}, 'one', 'reset returns to the start';

    is [ @{ $r->get_column('word')->all } ], ['one', 'two', 'three'],
        'get_column collects one column';

    is $r->all->size, 2, 'all takes what is left after next';

    $conn->_close_dbh;
};

subtest 'query_row returns one row' => sub {
    my $conn = make_connection();

    $conn->query('CREATE TEMP TABLE res_one (id int, tag text)')->get;
    $conn->query(q{INSERT INTO res_one VALUES (1, 'a'), (2, 'b')})->get;

    is $conn->query_row('SELECT * FROM res_one WHERE id = $1', 1)->get,
        { id => 1, tag => 'a' }, 'the matching row, as a hashref';

    # No match is an ordinary outcome to branch on, not an exception to trap.
    my $missing;
    my $quiet;
    {
        local $SIG{__WARN__} = sub { $quiet = shift };
        $missing = $conn->query_row('SELECT * FROM res_one WHERE id = 99')->get;
    }
    is $missing, undef, 'no match is undef';
    is $quiet, undef, 'and is not warned about';

    # Asking for one and getting several usually means the query is wrong.
    my ($row, $warning);
    {
        local $SIG{__WARN__} = sub { $warning = shift };
        $row = $conn->query_row('SELECT * FROM res_one ORDER BY id')->get;
    }
    is $row, { id => 1, tag => 'a' }, 'the first row is still returned';
    like $warning, qr/query_row/, 'the warning names the method';
    like $warning, qr/2 rows/, 'and how many matched';

    $conn->_close_dbh;
};

subtest 'query_row croaks on repeated column names' => sub {
    my $conn = make_connection();

    $conn->query('CREATE TEMP TABLE res_dup (id int, tag text)')->get;
    $conn->query(q{INSERT INTO res_dup VALUES (1, 'a')})->get;

    my $err = dies {
        $conn->query_row('SELECT id, id FROM res_dup')->get
    };

    like $err, qr/Column 'id' appears 2 times at positions 0, 1/,
        'names the column and its positions';
    like $err, qr/in query_row/, 'and where it happened';
    like $err, qr/query\(\.\.\.\)->single/,
        'points at the call that can handle it';

    $conn->_close_dbh;
};

subtest 'query_value returns one value and never builds a hash' => sub {
    my $conn = make_connection();

    $conn->query('CREATE TEMP TABLE res_val (id int, tag text)')->get;
    $conn->query(q{INSERT INTO res_val VALUES (1, 'a'), (2, 'b')})->get;

    is $conn->query_value('SELECT count(*) FROM res_val')->get, 2, 'the value';

    my $missing;
    my $quiet;
    {
        local $SIG{__WARN__} = sub { $quiet = shift };
        $missing = $conn->query_value('SELECT id FROM res_val WHERE id = 99')->get;
    }
    is $missing, undef, 'no match is undef';
    is $quiet, undef, 'and is not warned about';

    my ($value, $warning);
    {
        local $SIG{__WARN__} = sub { $warning = shift };
        $value = $conn->query_value('SELECT id FROM res_val ORDER BY id')->get;
    }
    is $value, 1, 'the first value';
    like $warning, qr/query_value/, 'the warning names the method';

    # Positional all the way down, so repeated names cannot stop it. This is
    # the escape hatch query_row's croak points away from.
    my $duplicated;
    ok lives { $duplicated = $conn->query_value('SELECT id, id FROM res_val WHERE id = 1')->get },
        'a repeated column name is not an error here';
    is $duplicated, 1, 'and the value is right';

    $conn->_close_dbh;
};

subtest 'query_list gives one row as a list' => sub {
    my $conn = make_connection();

    $conn->query('CREATE TEMP TABLE res_list (id int, tag text, n int)')->get;
    $conn->query(q{INSERT INTO res_list VALUES (1, 'a', 10), (2, 'b', 20)})->get;

    # The idiom this exists for.
    my ($id, $tag, $n) = $conn->query_list(
        'SELECT id, tag, n FROM res_list WHERE id = $1', 1
    )->get;
    is [$id, $tag, $n], [1, 'a', 10], 'every column, in order, as a list';

    my @none = $conn->query_list('SELECT id, tag FROM res_list WHERE id = 99')->get;
    is \@none, [], 'no match is an empty list';

    my ($first, $warning);
    {
        local $SIG{__WARN__} = sub { $warning = shift };
        ($first) = $conn->query_list('SELECT id FROM res_list ORDER BY id')->get;
    }
    is $first, 1, 'several rows still returns the first';
    like $warning, qr/query_list/, 'and warns, naming the method';

    # Positional, so it works where query_row croaks -- the same escape
    # hatch query_value offers, but for the whole row.
    my @dup = $conn->query_list('SELECT id, id FROM res_list WHERE id = 1')->get;
    is \@dup, [1, 1], 'a repeated column name is not an error here';

    # An async sub cannot see its caller's context, so the future carries a
    # list and scalar context takes its first value rather than an arrayref.
    my $scalar = $conn->query_list('SELECT id, tag FROM res_list WHERE id = 2')->get;
    is $scalar, 2, 'awaited in scalar context, the first value';

    $conn->_close_dbh;
};

subtest 'elapsed is captured on every result' => sub {
    my $conn = make_connection();

    my $quick = $conn->query('SELECT 1 AS n')->get;
    ok defined $quick->elapsed, 'a SELECT carries its duration';
    ok $quick->elapsed > 0, 'which is positive';
    ok $quick->elapsed < 10, 'and plausible for a trivial statement';

    # A slow statement must measure slower than a fast one, or the number is
    # decorative rather than a measurement.
    my $slow = $conn->query('SELECT pg_sleep(0.25)')->get;
    ok $slow->elapsed > 0.2, 'a deliberately slow query measures slow';
    ok $slow->elapsed > $quick->elapsed, 'and slower than the quick one';

    my $insert = $conn->query('CREATE TEMP TABLE res_time (id int)')->get;
    ok defined $insert->elapsed, 'a statement returning no rows has one too';

    my $returning = $conn->query(
        'INSERT INTO res_time VALUES (1) RETURNING id'
    )->get;
    ok defined $returning->elapsed, 'and so does RETURNING';

    # A view is the same query's result, so it reports the same duration.
    my $r = $conn->query('SELECT 1 AS n')->get;
    is $r->as(['x'])->elapsed, $r->elapsed, 'a view carries it through';

    $conn->_close_dbh;
};

subtest 'on_query sees every statement, successful or not' => sub {
    my @events;
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 2,
        on_query        => sub { push @events, $_[0] },
    );

    $pg->query('SELECT $1::int AS n', 7)->get;

    is scalar @events, 1, 'one statement, one event';
    is $events[0]{sql}, 'SELECT $1::int AS n', 'the statement';
    is $events[0]{binds}, [7], 'its binds';
    is $events[0]{rows}, 1, 'the row count';
    is $events[0]{error}, undef, 'and no error';
    ok $events[0]{elapsed} > 0, 'with a duration';

    @events = ();
    ok dies { $pg->query('SELECT * FROM no_such_table_here')->get },
        'a failing statement still fails';

    is scalar @events, 1, 'and still reports';
    is $events[0]{rows}, undef, 'with no row count';
    like $events[0]{error}, qr/no_such_table_here/, 'and the error';

    # This is the "did this code path run two queries" use, which is why the
    # hook is worth having rather than four separate features.
    @events = ();
    $pg->query_row('SELECT 1 AS n')->get;
    $pg->query_value('SELECT 2')->get;
    is scalar @events, 2, 'query_row and query_value report too';

    # A handler that dies must not take the caller's query down with it.
    my @logged;
    $pg->{on_log} = sub { push @logged, $_[1] };
    $pg->on_query(sub { die "handler exploded\n" });

    my $survived;
    ok lives { $survived = $pg->query('SELECT 42 AS n')->get },
        'a dying handler does not fail the query';
    is $survived->first->{n}, 42, 'which returns its result as normal';
    like $logged[-1], qr/on_query handler failed/, 'and the failure is logged';

    $pg->on_query(undef);
    ok lives { $pg->query('SELECT 1')->get }, 'the hook can be removed again';

    $pg->shutdown(timeout => 2)->get;
};

done_testing;

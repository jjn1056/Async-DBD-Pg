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

done_testing;

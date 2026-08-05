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

# The statement the converter emits is not the statement PostgreSQL runs:
# DBD::Pg scans it again at prepare. A unit test of convert_placeholders
# cannot see that second scan, so everything here goes through query() and
# reaches a real server.

my $pg = Async::DBD::Pg->new(
    dsn             => test_dsn(),
    min_connections => 1,
    max_connections => 2,
);

my $conn = $pg->connection->get or die "could not check out a connection\n";

# Run $sql and return its single row. A failed query reports the database's
# own message and yields an empty row, so the assertions that follow fail on
# a missing value rather than on a type error that hides the cause.
sub run {
    my ($sql, @bind) = @_;
    my $row = eval { $conn->query($sql, @bind)->get->first };
    return $row if !$@;

    my $err = "$@";
    $err =~ s/\s+at\s+\S+\s+line\s+\d+\.?\s*//s;
    chomp $err;
    fail "query failed: $err";
    diag "  statement: $sql";
    return {};
}

subtest 'jsonb operators spelled with a question mark' => sub {
    # ?, ?| and ?& are PostgreSQL's jsonb existence operators. DBD::Pg's own
    # scanner reads each ? as a placeholder, so without pg_placeholder_dollaronly
    # these fail at execute -- and once the caller has binds of their own, the
    # error names a placeholder style they never typed.
    is run(q{SELECT '{"a":1}'::jsonb ? 'a' AS hit})->{hit}, 1,
        'exists operator, no binds';

    is run(q{SELECT '{"a":1}'::jsonb ?| array['a','z'] AS hit})->{hit}, 1,
        'exists-any operator, no binds';

    is run(q{SELECT '{"a":1}'::jsonb ?& array['a'] AS hit})->{hit}, 1,
        'exists-all operator, no binds';

    is run(q{SELECT '{"a":1}'::jsonb ? 'z' AS hit})->{hit}, 0,
        'exists operator returning false';

    my $positional = run(q{SELECT '{"a":1}'::jsonb ? 'a' AS hit, $1::int AS n}, 7);
    is $positional, { hit => 1, n => 7 }, 'exists operator alongside a positional bind';

    my $named = run(q{SELECT '{"a":1}'::jsonb ? 'a' AS hit, :n::int AS n}, { n => 7 });
    is $named, { hit => 1, n => 7 }, 'exists operator alongside a named bind';
};

subtest 'array slices' => sub {
    # arr[:2] passes through the converter untouched, which is correct, and
    # then dies inside DBD::Pg because the colon looks like a placeholder to
    # its scanner too.
    is run(q{SELECT (ARRAY[1,2,3])[:2] AS s})->{s}, [1, 2],
        'slice with an omitted lower bound';

    is run(q{SELECT (ARRAY[1,2,3])[2:] AS s})->{s}, [2, 3],
        'slice with an omitted upper bound';

    is run(q{SELECT (ARRAY[1,2,3])[1:3] AS s})->{s}, [1, 2, 3],
        'slice with both bounds';

    my $bound = run(q{SELECT (ARRAY[1,2,3])[:2] AS s, $1::int AS n}, 9);
    is $bound, { s => [1, 2], n => 9 }, 'slice alongside a positional bind';

    my $named = run(q{SELECT (ARRAY[1,2,3])[:2] AS s, :n::int AS n}, { n => 9 });
    is $named, { s => [1, 2], n => 9 }, 'slice alongside a named bind';
};

subtest 'binds of every supported form still work' => sub {
    # pg_placeholder_dollaronly narrows what DBD::Pg treats as a placeholder,
    # so this is the regression half: nothing the library documents may break.
    is run(q{SELECT $1::int AS n}, 42)->{n}, 42, 'one positional bind';

    is run(q{SELECT $1::int AS a, $2::text AS b}, 1, 'x'),
        { a => 1, b => 'x' }, 'two positional binds';

    is run(q{SELECT $1::int AS a, $1::int AS b}, 5),
        { a => 5, b => 5 }, 'a repeated positional bind is passed once';

    is run(q{SELECT :n::int AS n}, { n => 42 })->{n}, 42, 'one named bind';

    is run(q{SELECT :a::int AS a, :b::text AS b, :a::int AS c}, { a => 1, b => 'x' }),
        { a => 1, b => 'x', c => 1 }, 'named binds, one of them repeated';

    is run(q{SELECT 'literal ? mark' AS s})->{s}, 'literal ? mark',
        'a question mark inside a string literal is data';
};

subtest 'typed binds still work' => sub {
    # bind_param with pg_type is a different mechanism from the placeholder
    # scan, so dollaronly is expected not to disturb it. Expected is not
    # verified; a byte range that includes NUL is what would show it.
    my $blob = join '', map { chr } 0 .. 255;

    my $row = run(
        q{SELECT $1::bytea AS b},
        { type => DBD::Pg::PG_BYTEA(), value => $blob },
    );

    is length $row->{b}, 256, 'every byte survived the round trip';
    is $row->{b}, $blob, 'bytes are identical, NUL included';
};

$conn->release;
$pg->shutdown->get;

done_testing;

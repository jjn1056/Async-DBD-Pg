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
use DBD::Pg qw(:pg_types);

sub pool {
    my (%args) = @_;
    return Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 2, %args,
    );
}

subtest 'a type name binds the same bytes as the constant' => sub {
    my $pg = pool();
    my $conn = $pg->connection->get;

    $conn->query('SET client_min_messages = warning')->get;
    $conn->query('DROP TABLE IF EXISTS typed_binds')->get;
    $conn->query('CREATE TABLE typed_binds (id int, body bytea)')->get;

    # An embedded NUL is the whole point: bytea sent as text truncates there
    # and reports success, which is the failure typed binds exist to prevent.
    my $bytes = join '', map { chr } 0 .. 255;

    $conn->query('INSERT INTO typed_binds VALUES ($1, $2)',
        1, { type => PG_BYTEA, value => $bytes })->get;
    $conn->query('INSERT INTO typed_binds VALUES ($1, $2)',
        2, { type => 'bytea', value => $bytes })->get;

    my $by_constant = $conn->query_value('SELECT body FROM typed_binds WHERE id = $1', 1)->get;
    my $by_name     = $conn->query_value('SELECT body FROM typed_binds WHERE id = $1', 2)->get;

    is length($by_name), 256, 'the named bind round-trips all 256 bytes';
    is $by_name, $by_constant, 'and is byte-identical to the constant form';

    $conn->query('DROP TABLE typed_binds')->get;
    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

subtest 'a type DBD::Pg cannot bind croaks, naming the type' => sub {
    my $pg = pool();
    my $conn = $pg->connection->get;

    $conn->query('SET client_min_messages = warning')->get;
    $conn->query('DROP TYPE IF EXISTS mapper_mood CASCADE')->get;
    $conn->query("CREATE TYPE mapper_mood AS ENUM ('ok', 'bad')")->get;

    # bind_param refuses any OID outside DBD::Pg's own table, so naming a
    # user-defined type has to fail -- the question is only whether it fails
    # legibly here or as "Cannot bind 1 unknown pg_type 65025" deep inside
    # DBD::Pg. This is the case that decided the design.
    my $err = dies {
        $conn->query_value('SELECT $1::mapper_mood::text',
            { type => 'mapper_mood', value => 'ok' })->get
    };

    like "$err", qr/mapper_mood/, 'the message names the type, not an OID';

    # And it did not need a typed bind in the first place: an enum is text on
    # the wire. This is the documented way to bind one.
    my $value = $conn->query_value('SELECT $1::mapper_mood::text', 'ok')->get;
    is $value, 'ok', 'binding it untyped works, which is why this is no loss';

    $conn->query('DROP TYPE mapper_mood')->get;
    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

subtest 'resolving a name costs no query of its own' => sub {
    my @sql;
    my $pg = pool(on_query => sub { push @sql, $_[0]{sql} });
    my $conn = $pg->connection->get;

    @sql = ();
    $conn->query_value('SELECT length($1)', { type => 'bytea', value => 'abc' })->get;
    $conn->query_value('SELECT length($1)', { type => 'BYTEA', value => 'defg' })->get;

    # The map is built at load time, so the only statements are the caller's.
    is scalar(@sql), 2,
        'two queries in, two statements out -- no lookup round trip, and the '
      . 'name is matched case-insensitively';

    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

subtest 'an unknown type name croaks and names the type' => sub {
    my $pg = pool();
    my $conn = $pg->connection->get;

    my $err = dies {
        $conn->query_value('SELECT $1', { type => 'no_such_type', value => 1 })->get
    };

    like "$err", qr/no_such_type/,
        'the message names the type the caller got wrong';

    ok lives { $conn->query_value('SELECT 42')->get },
        'and the connection is still usable';

    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

subtest 'a bind with type => undef croaks rather than silently losing data' => sub {
    my $pg = pool();
    my $conn = $pg->connection->get;

    # { type => undef, value => ... } is what a mapper produces when its own
    # type lookup misses -- the hashref has both keys, so it looks like a
    # typed bind, but with no type to resolve it used to fall through to
    # bind_param(..., { pg_type => undef }), an untyped bind. For bytea that
    # truncates at the first embedded NUL and reports success: exactly the
    # silent loss typed binds exist to prevent.
    my $err = dies {
        $conn->query_value('SELECT $1::bytea',
            { type => undef, value => "a\0bcd" })->get
    };

    like "$err", qr/type => undef/, 'the message names the problem';

    ok lives { $conn->query_value('SELECT 42')->get },
        'and the connection stays usable afterwards';

    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

subtest 'a numeric type is passed through untouched' => sub {
    my @sql;
    my $pg = pool(on_query => sub { push @sql, $_[0]{sql} });
    my $conn = $pg->connection->get;

    @sql = ();
    my $n = $conn->query_value('SELECT length($1)',
        { type => PG_BYTEA, value => "ab\0cd" })->get;

    is $n, 5, 'the constant form still works, NUL and all';
    is scalar(@sql), 1, 'and adds no statement of its own';

    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

done_testing;

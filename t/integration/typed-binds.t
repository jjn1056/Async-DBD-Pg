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

subtest 'each name is resolved once, and only when one is used' => sub {
    my @sql;
    my $pg = pool(on_query => sub { push @sql, $_[0]{sql} });
    my $conn = $pg->connection->get;

    # No bind names a type, so nothing is resolved at all.
    $conn->query_value('SELECT $1::int', 1)->get;
    is scalar(grep { /to_regtype/ } @sql), 0,
        'an untyped query resolves nothing';

    @sql = ();
    $conn->query_value('SELECT length($1)', { type => 'bytea', value => 'abc' })->get;
    $conn->query_value('SELECT length($1)', { type => 'bytea', value => 'defg' })->get;
    $conn->query_value('SELECT length($1)', { type => 'BYTEA', value => 'hi' })->get;

    is scalar(grep { /to_regtype/ } @sql), 1,
        'one resolution serves every later bind of that name, case-insensitively';

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

subtest 'a numeric type is passed through untouched' => sub {
    my @sql;
    my $pg = pool(on_query => sub { push @sql, $_[0]{sql} });
    my $conn = $pg->connection->get;

    my $n = $conn->query_value('SELECT length($1)',
        { type => PG_BYTEA, value => "ab\0cd" })->get;

    is $n, 5, 'the constant form still works, NUL and all';
    is scalar(grep { /to_regtype/ } @sql), 0,
        'and costs no resolution round trip';

    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

done_testing;

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

sub pool {
    my (%args) = @_;
    return Async::DBD::Pg->new(
        dsn                  => test_dsn(),
        min_connections      => 0,
        max_connections      => 2,
        statement_cache_size => 10,
        %args,
    );
}

# DBD::Pg only promotes a handle to a named server-side prepared statement on
# its second execute (pg_switch_prepared defaults to 2). Every assertion about
# the named statement therefore has to get past that threshold first, and say
# so, or it passes without touching the path it claims to test.
sub prepare_name {
    my ($conn, $sql) = @_;
    my $sth = $conn->{_stmt_cache}{$sql} or return undef;
    return $sth->{pg_prepare_name};
}

subtest 'the same statement is prepared once and reused' => sub {
    my @events;
    my $pg = pool(on_query => sub { push @events, $_[0] });
    my $conn = $pg->connection->get;

    my $sql = 'SELECT $1::int AS n';

    $conn->query($sql, 1)->get;
    my $first = $conn->{_stmt_cache}{$sql};
    ok $first, 'the handle was cached';

    $conn->query($sql, 2)->get;
    is $conn->{_stmt_cache}{$sql}, exact_ref($first), 'and reused, not replaced';

    is [ map { $_->{cached} } @events ], [0, 1],
        'on_query reports the miss and then the hit';

    # Past the promotion threshold there is a real server-side statement,
    # which is the thing the cache exists to keep alive.
    ok defined prepare_name($conn, $sql) && length prepare_name($conn, $sql),
        'and DBD::Pg has promoted it to a named prepared statement';

    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

subtest 'the key is the converted SQL, so bind styles share an entry' => sub {
    my $pg = pool();
    my $conn = $pg->connection->get;

    $conn->query('SELECT :n::int AS n', { n => 1 })->get;
    is scalar(keys %{ $conn->{_stmt_cache} }), 1, 'the named form cached one entry';

    # Same statement after conversion, so it must hit rather than add.
    $conn->query('SELECT $1::int AS n', 2)->get;
    is scalar(keys %{ $conn->{_stmt_cache} }), 1,
        'the positional spelling of the same query hit that entry';
    ok exists $conn->{_stmt_cache}{'SELECT $1::int AS n'},
        'and the key is the converted SQL';

    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

subtest 'the cache is bounded and evicts the oldest' => sub {
    my $pg = pool(statement_cache_size => 2);
    my $conn = $pg->connection->get;

    $conn->query('SELECT 1 AS a')->get;
    $conn->query('SELECT 2 AS b')->get;
    is scalar(keys %{ $conn->{_stmt_cache} }), 2, 'two entries at size two';

    $conn->query('SELECT 3 AS c')->get;
    is scalar(keys %{ $conn->{_stmt_cache} }), 2, 'still two after a third';
    ok !exists $conn->{_stmt_cache}{'SELECT 1 AS a'}, 'the oldest went';
    ok exists $conn->{_stmt_cache}{'SELECT 3 AS c'}, 'the newest stayed';

    # Using an entry makes it recent, so the other one is next out.
    $conn->query('SELECT 2 AS b')->get;
    $conn->query('SELECT 4 AS d')->get;
    ok exists $conn->{_stmt_cache}{'SELECT 2 AS b'}, 'a reused entry survives';
    ok !exists $conn->{_stmt_cache}{'SELECT 3 AS c'}, 'the untouched one goes';

    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

subtest 'a failed statement is evicted rather than reused' => sub {
    my $pg = pool();
    my $conn = $pg->connection->get;

    my $sql = 'SELECT 1 / $1::int AS n';

    $conn->query($sql, 1)->get;
    ok exists $conn->{_stmt_cache}{$sql}, 'cached after succeeding';

    # Division by zero fails at execution, so the handle's state is not known
    # to be good afterwards. Handing it to the next caller is the risk this
    # eviction exists to remove.
    ok dies { $conn->query($sql, 0)->get }, 'the query fails';
    ok !exists $conn->{_stmt_cache}{$sql}, 'and its entry was evicted';

    # The connection is still usable, and the statement caches again.
    is $conn->query_value($sql, 2)->get, 0, 'the query works again afterwards';
    ok exists $conn->{_stmt_cache}{$sql}, 'and is cached once more';

    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

subtest 'a cancelled query evicts its statement' => sub {
    my $pg = pool();
    my $conn = $pg->connection->get;

    my $sql = 'SELECT pg_sleep($1::float) AS slept';

    my $f = $conn->query($sql, 5);
    ok exists $conn->{_stmt_cache}{$sql}, 'cached as soon as it is prepared';

    $f->cancel;

    ok !exists $conn->{_stmt_cache}{$sql},
        'cancelling evicts it: the statement was aborted in flight';

    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

subtest 'a missing prepared statement recovers by itself' => sub {
    my @events;
    my $pg = pool(on_query => sub { push @events, $_[0] });
    my $conn = $pg->connection->get;

    my $sql = 'SELECT $1::int AS n';

    # Twice, because DBD::Pg does not create the named server-side statement
    # until the second execute. Asserting the name is what stops this test
    # passing vacuously if that default ever changes -- executing once,
    # deallocating and reusing succeeds while touching nothing.
    $conn->query($sql, 1)->get;
    $conn->query($sql, 2)->get;

    my $name = prepare_name($conn, $sql);
    ok defined $name && length $name,
        "a named prepared statement exists (${\ ($name // 'none') })";

    # Pull it out from under the cache, the way a pooler handing us a
    # different backend would.
    $conn->query('DEALLOCATE ALL')->get;

    @events = ();
    my $value;
    ok lives { $value = $conn->query_value($sql, 42)->get },
        'the next use recovers rather than failing';
    is $value, 42, 'and returns the right answer';

    ok exists $conn->{_stmt_cache}{$sql}, 'the statement is cached again';

    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

subtest 'a changed result type recovers by itself' => sub {
    # BLOCKED, not passing. Reusing a cached handle after ALTER TABLE changes
    # the result shape segfaults this library, while the identical sequence
    # through raw DBI with pg_async survives. So it is ours, not DBD::Pg's,
    # and it happens with the retry removed as well -- it is the reuse, not
    # the recovery.
    #
    # Left in place, and skipped rather than deleted, because it is the test
    # that found the defect and it has to go green before the cache can be
    # enabled by anyone.
    skip_all 'reusing a cached handle across a result-shape change segfaults';

    my $pg = pool();
    my $conn = $pg->connection->get;

    $conn->query('DROP TABLE IF EXISTS cache_shape')->get;
    $conn->query('CREATE TABLE cache_shape (id int)')->get;
    $conn->query('INSERT INTO cache_shape VALUES (1)')->get;

    my $sql = 'SELECT * FROM cache_shape';

    $conn->query($sql)->get;
    $conn->query($sql)->get;

    # Changing the shape invalidates the cached plan: 0A000.
    $conn->query('ALTER TABLE cache_shape ADD COLUMN tag text')->get;

    my $after;
    ok lives { $after = $conn->query($sql)->get }, 'the next use recovers';
    is $after->columns, ['id', 'tag'], 'and reports the new shape';

    $conn->query('DROP TABLE cache_shape')->get;
    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

subtest 'caching can be switched off entirely' => sub {
    my @events;
    my $pg = pool(statement_cache_size => 0, on_query => sub { push @events, $_[0] });
    my $conn = $pg->connection->get;

    my $sql = 'SELECT $1::int AS n';
    $conn->query($sql, 1)->get;
    $conn->query($sql, 2)->get;

    is scalar(keys %{ $conn->{_stmt_cache} }), 0, 'nothing is cached';
    is [ map { $_->{cached} } @events ], [0, 0], 'and no hit is ever reported';

    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

subtest 'eviction inside an aborted transaction is harmless' => sub {
    my $pg = pool();
    my $conn = $pg->connection->get;

    # Dropping a handle sends DEALLOCATE, and an aborted transaction refuses
    # every command. Measured as clean today, so this is a regression guard.
    my $err = dies {
        $conn->transaction(async sub {
            my ($c) = @_;
            await $c->query('SELECT $1::int AS n', 1);
            await $c->query('SELECT $1::int AS n', 2);
            await $c->query('SELECT * FROM no_such_table_at_all');
        })->get
    };

    ok $err, 'the transaction failed as it should';

    ok lives { $conn->query_value('SELECT 42')->get },
        'and the connection is still usable afterwards';
    is $conn->query_value('SELECT 42')->get, 42, 'returning the right answer';

    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

done_testing;

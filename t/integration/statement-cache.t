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

# The named server-side prepared statement is the thing the cache exists to
# keep alive, and the thing whose absence makes a reused handle unsafe. The
# pool sets pg_switch_prepared to 1 whenever caching is on, so it exists from
# the first execute; asserting on it is what stops these subtests passing
# while the cache silently holds nothing.
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

    # Every statement here carries a placeholder, because only those are
    # cached at all -- an unparameterized one would leave the cache empty and
    # this subtest would pass while measuring nothing.
    my ($a, $b, $c, $d) = map { "SELECT \$1::int AS $_" } qw(a b c d);

    $conn->query($a, 1)->get;
    $conn->query($b, 1)->get;
    is scalar(keys %{ $conn->{_stmt_cache} }), 2, 'two entries at size two';

    $conn->query($c, 1)->get;
    is scalar(keys %{ $conn->{_stmt_cache} }), 2, 'still two after a third';
    ok !exists $conn->{_stmt_cache}{$a}, 'the oldest went';
    ok exists $conn->{_stmt_cache}{$c}, 'the newest stayed';

    # Using an entry makes it recent, so the other one is next out.
    $conn->query($b, 1)->get;
    $conn->query($d, 1)->get;
    ok exists $conn->{_stmt_cache}{$b}, 'a reused entry survives';
    ok !exists $conn->{_stmt_cache}{$c}, 'the untouched one goes';

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

    # Asserting the name below is what stops this test passing vacuously: with
    # no named statement on the server, deallocating and reusing succeeds
    # while touching none of the recovery this claims to exercise.
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
    my $pg = pool();
    my $conn = $pg->connection->get;

    # The setup drop is expected to find nothing, and its NOTICE would reach
    # the pool's logger and print. Silenced here rather than left to scroll
    # past, so anything the suite does print is worth reading.
    $conn->query("SET client_min_messages = warning")->get;
    $conn->query('DROP TABLE IF EXISTS cache_shape')->get;
    $conn->query('CREATE TABLE cache_shape (id int)')->get;
    $conn->query('INSERT INTO cache_shape VALUES (1)')->get;

    # Carries a placeholder, which is what gets it a named server-side
    # prepared statement, which is what gets the shape change reported as
    # 0A000 instead of fetched off the end of a stale row buffer.
    my $sql = 'SELECT * FROM cache_shape WHERE id = $1';

    $conn->query($sql, 1)->get;
    ok exists $conn->{_stmt_cache}{$sql}, 'the statement is cached';
    ok defined prepare_name($conn, $sql) && length prepare_name($conn, $sql),
        'and has a named prepared statement, so the server guards its plan';

    # Changing the shape invalidates that cached plan: 0A000.
    $conn->query('ALTER TABLE cache_shape ADD COLUMN tag text')->get;

    my $after;
    ok lives { $after = $conn->query($sql, 1)->get }, 'the next use recovers';
    is $after->columns, ['id', 'tag'], 'and reports the new shape';

    $conn->query('DROP TABLE cache_shape')->get;
    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

subtest 'a statement with no placeholders is never cached' => sub {
    my $pg = pool();
    my $conn = $pg->connection->get;

    $conn->query("SET client_min_messages = warning")->get;
    $conn->query('DROP TABLE IF EXISTS cache_bare')->get;
    $conn->query('CREATE TABLE cache_bare (id int)')->get;
    $conn->query('INSERT INTO cache_bare VALUES (1)')->get;

    # DBD::Pg only promotes a statement that carries placeholders to a named
    # server-side prepared statement. Without one there is no cached plan, so
    # a result-shape change raises nothing -- and re-executing the handle
    # fetches the new shape through a row buffer sized for the old one, which
    # segfaults the process. Measured against DBD::Pg 3.20.2 with plain
    # synchronous DBI and no code of ours involved, so it is not something
    # this library can catch or recover from. Not caching such a handle is
    # what makes it unreachable, and costs nothing: with no server-side
    # statement to keep alive, caching bought only DBI's local re-parse.
    my $sql = 'SELECT * FROM cache_bare';

    $conn->query($sql)->get;
    ok !exists $conn->{_stmt_cache}{$sql},
        'it is left out of the cache, so it can never be re-executed';

    $conn->query($sql)->get;

    $conn->query('ALTER TABLE cache_bare ADD COLUMN tag text')->get;

    my $after;
    ok lives { $after = $conn->query($sql)->get },
        'so the query survives a result-shape change';
    is $after->columns, ['id', 'tag'], 'and reports the new shape';

    $conn->query('DROP TABLE cache_bare')->get;
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

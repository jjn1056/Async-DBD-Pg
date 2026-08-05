use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use Time::HiRes ();

use lib 't/lib';
use Test::Async::DBD::Pg qw(skip_without_postgres test_dsn);

my $dsn = skip_without_postgres();

use Future::IO;

BEGIN { Future::IO->load_best_impl; }

use Async::DBD::Pg;
use Async::DBD::Pg::Util qw(parse_dsn);
use Test::Async::DBD::Pg::DelayProxy;

# The proxy exists so a benchmark can report what the statement cache is worth
# at a realistic round trip. A proxy that quietly injected nothing would make
# every latency number in that benchmark a lie, so it is tested directly.

sub target_port {
    my $parsed = parse_dsn(test_dsn());
    my ($port) = $parsed->{dbi_dsn} =~ /port=(\d+)/;
    return $port // 5432;
}

subtest 'the library works unchanged through the proxy' => sub {
    my $proxy = Test::Async::DBD::Pg::DelayProxy->new(
        target_port => target_port(), delay => 0,
    );

    my $pg = Async::DBD::Pg->new(
        dsn => $proxy->dsn_from(test_dsn()),
        min_connections => 0, max_connections => 2,
    );

    is $pg->query_value('SELECT 42')->get, 42, 'a query goes through';

    my $rows = $pg->query('SELECT generate_series(1, 3) AS n')->get;
    is [ map { $_->{n} } @{ $rows->rows } ], [1, 2, 3], 'and so do several rows';

    # Bind parameters travel in their own protocol messages, so a proxy that
    # mangled chunk boundaries would show up here rather than above.
    is $pg->query_value('SELECT $1::int + $2::int', 20, 22)->get, 42,
        'binds survive the relay';

    my $wide = 'x' x 100_000;
    is $pg->query_value('SELECT length($1::text)', $wide)->get, 100_000,
        'a payload larger than one read buffer survives';

    $pg->shutdown(timeout => 5)->get;
    $proxy->stop;
};

subtest 'the proxy injects the latency it claims' => sub {
    my $delay = 0.05;

    my $proxy = Test::Async::DBD::Pg::DelayProxy->new(
        target_port => target_port(), delay => $delay,
    );

    my $pg = Async::DBD::Pg->new(
        dsn => $proxy->dsn_from(test_dsn()),
        min_connections => 1, max_connections => 2,
    );

    # Connect first, so the handshake's own delayed chunks are not counted
    # in the measurement below.
    my $conn = $pg->connection->get;
    $conn->query('SELECT 1')->get;

    my $start = Time::HiRes::time();
    $conn->query_value('SELECT 42')->get;
    my $elapsed = Time::HiRes::time() - $start;

    # One request out and one response back, each delayed, so a round trip
    # costs at least twice the per-chunk delay.
    ok $elapsed >= 2 * $delay,
        sprintf('a query took %.3fs, at least 2 x %.3fs of injected delay',
            $elapsed, $delay);

    # And the delay is the proxy's, not something inherently slow: the same
    # query direct to PostgreSQL is far quicker.
    my $direct = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 1, max_connections => 2,
    );
    my $direct_conn = $direct->connection->get;
    $direct_conn->query('SELECT 1')->get;

    my $t0 = Time::HiRes::time();
    $direct_conn->query_value('SELECT 42')->get;
    my $direct_elapsed = Time::HiRes::time() - $t0;

    ok $direct_elapsed < $elapsed,
        sprintf('direct took %.4fs against %.3fs through the proxy',
            $direct_elapsed, $elapsed);

    $direct_conn->release;
    $direct->shutdown(timeout => 5)->get;

    $conn->release;
    $pg->shutdown(timeout => 5)->get;
    $proxy->stop;
};

done_testing;

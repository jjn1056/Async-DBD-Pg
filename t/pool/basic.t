use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 't/lib';
use Test::Future::IO::Pg qw(skip_without_postgres test_dsn);

# Skip if no PostgreSQL available
my $dsn = skip_without_postgres();

# Load Future::IO implementation
use Future::IO::Impl::IOAsync;

use Future::IO::Pg;

subtest 'create pool' => sub {
    my $pg = Future::IO::Pg->new(
        dsn             => test_dsn(),
        min_connections => 1,
        max_connections => 5,
    );

    isa_ok $pg, 'Future::IO::Pg';
    is $pg->min_connections, 1, 'min_connections';
    is $pg->max_connections, 5, 'max_connections';
};

subtest 'get connection from pool' => sub {
    my $pg = Future::IO::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,  # Don't pre-create, we want to test explicit acquisition
        max_connections => 5,
    );

    my $conn = $pg->connection->get;
    isa_ok $conn, 'Future::IO::Pg::Connection';

    is $pg->active_count, 1, 'connection is active';

    my $result = $conn->query('SELECT 1 AS one')->get;
    is $result->first->{one}, 1, 'query works';

    $conn->release;
    is $pg->active_count, 0, 'connection released';
    is $pg->idle_count, 1, 'connection returned to idle';
};

subtest 'connection reuse' => sub {
    my $pg = Future::IO::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
    );

    my $conn1 = $pg->connection->get;
    my $conn1_dbh = $conn1->dbh;
    $conn1->release;

    my $conn2 = $pg->connection->get;
    is $conn2->dbh, $conn1_dbh, 'same connection reused';

    $conn2->release;
};

subtest 'multiple connections' => sub {
    my $pg = Future::IO::Pg->new(
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
    my $pg = Future::IO::Pg->new(
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

    my $pg = Future::IO::Pg->new(
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

subtest 'safe_dsn masks password' => sub {
    my $pg = Future::IO::Pg->new(
        dsn             => 'postgresql://user:secret@localhost/db',
        min_connections => 0,
        max_connections => 1,
    );

    is $pg->safe_dsn, 'postgresql://user:***@localhost/db', 'password masked';
};

done_testing;

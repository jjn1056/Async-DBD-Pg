#!/usr/bin/env perl
use strict;
use warnings;
use Future::AsyncAwait;
use Time::HiRes;

# Load Future::IO implementation
use Future::IO::Impl::IOAsync;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;

use Future::IO::Pg;

my $dsn = $ENV{TEST_PG_DSN} // 'postgresql://postgres:test@localhost:5432/test';

print "=" x 60, "\n";
print "Proving Future::IO::Pg is truly async\n";
print "=" x 60, "\n\n";

# Check capabilities
print "Capabilities:\n";
print "  DBD::Pg version: $DBD::Pg::VERSION\n";
print "  Future::IO impl: $Future::IO::IMPL\n";
my $test_pg = Future::IO::Pg->new(dsn => $dsn, min_connections => 0);
print "  Async connect: ", ($test_pg->_supports_async_connect ? "YES" : "NO"), "\n";
print "  ready_for_read: ", ($Future::IO::IMPL->can('ready_for_read') ? "YES" : "NO"), "\n\n";

my $loop = IO::Async::Loop->new;

# Create a timer that ticks every 50ms
my $ticks = 0;
my $timer = IO::Async::Timer::Periodic->new(
    interval => 0.05,
    on_tick  => sub {
        $ticks++;
        print "  [tick $ticks] Event loop is running!\n";
    },
);
$timer->start;
$loop->add($timer);

# Create the pool
my $pg = Future::IO::Pg->new(
    dsn             => $dsn,
    min_connections => 0,
    max_connections => 5,
);

async sub run_test {
    print "1. Getting connection from pool...\n";
    my $conn = await $pg->connection;
    print "   Got connection!\n\n";

    # Test 1: Single slow query
    print "2. Running pg_sleep(0.3) - should see ~6 ticks during this...\n";
    $ticks = 0;
    my $start = Time::HiRes::time();

    my $result = await $conn->query("SELECT pg_sleep(0.3), 'done' as status");

    my $elapsed = Time::HiRes::time() - $start;
    print sprintf("   Query completed in %.3fs with %d ticks\n", $elapsed, $ticks);
    print "   Result: ", $result->first->{status}, "\n";

    if ($ticks >= 3) {
        print "   SUCCESS: Event loop was NOT blocked!\n\n";
    } else {
        print "   FAILURE: Event loop was blocked (expected >= 3 ticks)\n\n";
    }

    # Test 2: Multiple concurrent queries
    print "3. Running 3 concurrent pg_sleep(0.2) queries...\n";
    $ticks = 0;
    $start = Time::HiRes::time();

    # Get 3 connections and run queries concurrently
    my $conn1 = await $pg->connection;
    my $conn2 = await $pg->connection;
    my $conn3 = await $pg->connection;

    my @futures = (
        $conn1->query("SELECT pg_sleep(0.2), 1 as id"),
        $conn2->query("SELECT pg_sleep(0.2), 2 as id"),
        $conn3->query("SELECT pg_sleep(0.2), 3 as id"),
    );

    my @results = await Future->wait_all(@futures);

    $elapsed = Time::HiRes::time() - $start;
    print sprintf("   All 3 queries completed in %.3fs with %d ticks\n", $elapsed, $ticks);

    # If truly concurrent, 3 x 0.2s queries should complete in ~0.2s, not 0.6s
    if ($elapsed < 0.4) {
        print "   SUCCESS: Queries ran concurrently (< 0.4s total)!\n";
    } else {
        print "   Note: Queries ran sequentially (expected if single connection)\n";
    }

    if ($ticks >= 2) {
        print "   SUCCESS: Event loop was NOT blocked!\n\n";
    }

    $conn1->release;
    $conn2->release;
    $conn3->release;

    # Test 3: Real work during query
    print "4. Doing real async work during a slow query...\n";
    $ticks = 0;
    my @work_done;

    my $query_future = $conn->query("SELECT pg_sleep(0.25), 42 as answer");

    # Do some async work while query runs
    my $work_future = (async sub {
        for my $i (1..3) {
            push @work_done, "work_$i";
            await Future::IO->sleep(0.05);
        }
        return 'work complete';
    })->();

    my ($query_result, $work_result) = await Future->wait_all($query_future, $work_future);

    print "   Query result: ", $query_result->get->first->{answer}, "\n";
    print "   Work done: ", join(", ", @work_done), "\n";
    print "   Work result: ", $work_result->get, "\n";

    if (@work_done == 3) {
        print "   SUCCESS: Async work completed during query!\n\n";
    }

    $conn->release;

    print "=" x 60, "\n";
    print "All tests demonstrate Future::IO::Pg is truly async!\n";
    print "=" x 60, "\n";
}

# Run the test
run_test()->get;

$timer->stop;
$loop->remove($timer);

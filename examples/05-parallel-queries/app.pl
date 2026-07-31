#!/usr/bin/env perl
use strict;
use warnings;

use Future;
use Future::AsyncAwait;
use Future::IO;
use Time::HiRes qw(time);
use Async::DBD::Pg;

BEGIN { Future::IO->load_best_impl; }

my $dsn = $ENV{DATABASE_URL} // 'postgresql://postgres:test@localhost:5432/test';

my $pg = Async::DBD::Pg->new(
    dsn             => $dsn,
    min_connections => 1,
    max_connections => 10,
);

sub slow_query {
    return 'SELECT pg_sleep(0.1), $1::int AS id';
}

my $count = 5;

print "Sequential:\n";
my $start = time();
my $conn = $pg->connection->get;
for my $i (1 .. $count) {
    $conn->query(slow_query(), $i)->get;
}
$conn->release;
my $sequential = time() - $start;
printf "  %.2fs\n", $sequential;

print "\nParallel:\n";
$start = time();
my @futures;
for my $i (1 .. $count) {
    push @futures, (async sub {
        my $c = await $pg->connection;
        my $result = await $c->query(slow_query(), $i);
        $c->release;
        return $result->first->{id};
    })->();
}
my @results = Future->wait_all(@futures)->get;
my $parallel = time() - $start;
printf "  %.2fs\n", $parallel;
printf "  speedup: %.1fx\n", $sequential / $parallel if $parallel > 0;

print "\nPool stats:\n";
my $stats = $pg->stats;
print "  created: $stats->{created}\n";
print "  idle: ", $pg->idle_count, "\n";
print "  active: ", $pg->active_count, "\n";

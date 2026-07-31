#!/usr/bin/env perl
use strict;
use warnings;

use Future::IO;
use Async::DBD::Pg;

BEGIN { Future::IO->load_best_impl; }

my $dsn = $ENV{DATABASE_URL} // 'postgresql://postgres:test@localhost:5432/test';

my $pg = Async::DBD::Pg->new(
    dsn             => $dsn,
    min_connections => 0,
    max_connections => 5,
);

my @received;

$pg->listen('demo_channel', sub {
    my ($channel, $payload, $pid) = @_;
    push @received, [$channel, $payload, $pid];
    print "Received on $channel from pid $pid: $payload\n";
})->get;

print "Sending notification...\n";
$pg->notify('demo_channel', 'hello from Async::DBD::Pg')->get;

my $deadline = time + 2;
while (!@received && time < $deadline) {
    Future::IO->sleep(0.05)->get;
}

@received or die "Timed out waiting for notification\n";

$pg->unlisten_all->get;
$pg->pubsub->disconnect->get;

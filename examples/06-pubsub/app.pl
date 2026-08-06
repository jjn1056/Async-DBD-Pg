#!/usr/bin/env perl
use strict;
use warnings;

use Future::AsyncAwait;
use Future::IO;
use Async::DBD::Pg;

BEGIN { Future::IO->load_best_impl; }

my $dsn = $ENV{DATABASE_URL} // 'postgresql://postgres:test@localhost:5432/test';

my $pg = Async::DBD::Pg->new(
    dsn             => $dsn,
    min_connections => 0,
    max_connections => 5,
);

(async sub {
    my @received;

    await $pg->listen('demo_channel', sub {
        my ($channel, $payload, $pid) = @_;
        push @received, [$channel, $payload, $pid];
        print "Received on $channel from pid $pid: $payload\n";
    });

    print "Sending notification...\n";
    await $pg->notify('demo_channel', 'hello from Async::DBD::Pg');

    # A notification arrives on the listener's own connection, so this waits
    # for the callback above rather than for the notify to return.
    my $deadline = time + 2;
    while (!@received && time < $deadline) {
        await Future::IO->sleep(0.05);
    }

    @received or die "Timed out waiting for notification\n";

    await $pg->unlisten_all;
})->()->get;

await $pg->shutdown(timeout => 5);

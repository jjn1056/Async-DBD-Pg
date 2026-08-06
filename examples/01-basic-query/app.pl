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
    min_connections => 1,
    max_connections => 5,
);

(async sub {
    # Asking the pool runs one statement on any free connection and gives it
    # straight back, so nothing can be left checked out.
    my $version = await $pg->query_value('SELECT version()');
    print "PostgreSQL version:\n  $version\n\n";

    my $series = await $pg->query('SELECT generate_series(1, 5) AS n');
    print "Generated series:\n";
    print "  n = $_->{n}\n" for @{ $series->rows };
})->()->get;

await $pg->shutdown(timeout => 5);

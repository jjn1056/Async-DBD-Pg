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
    print "Positional placeholders:\n";
    my $sum = await $pg->query_value('SELECT $1::int + $2::int', 10, 20);
    print "  10 + 20 = $sum\n";

    print "\nNamed placeholders:\n";
    my $full = await $pg->query_value(
        q{SELECT :first_name || ' ' || :last_name},
        { first_name => 'John', last_name => 'Doe' },
    );
    print "  Full name = $full\n";

    # The value is data, never SQL. Nothing here is escaped by hand.
    my $malicious = q{'; DROP TABLE users; --};
    my $safe = await $pg->query_value('SELECT $1::text', $malicious);
    print "\nSafely escaped:\n  $safe\n";
})->()->get;

await $pg->shutdown(timeout => 5);

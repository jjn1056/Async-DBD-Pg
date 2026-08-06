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
    await $pg->with_connection(async sub {
        my ($conn) = @_;

        # A cursor lives on the connection that opened it, so every statement
        # here has to run on that same connection -- which is what this block
        # guarantees, including if something below dies.
        await $conn->query('SET client_min_messages TO warning');
        await $conn->query('DROP TABLE IF EXISTS large_data');
        await $conn->query(q{
            CREATE TABLE large_data (id SERIAL PRIMARY KEY, value TEXT)
        });
        await $conn->query(q{
            INSERT INTO large_data (value)
            SELECT 'row_' || generate_series(1, 250)
        });

        my $cursor = await $conn->cursor(
            'SELECT * FROM large_data ORDER BY id', { batch_size => 50 });

        # next yields one row at a time. batch_size is how many rows come back
        # per round trip, which this loop never has to think about.
        my ($seen, $first, $last) = (0, undef, undef);
        while (my $row = await $cursor->next) {
            $seen++;
            $first //= $row->{id};
            $last = $row->{id};
        }
        await $cursor->close;
        print "Streamed $seen rows, ids $first - $last, 50 at a time\n";

        print "\nCursor with parameters:\n";
        my $ranged = await $conn->cursor(
            'SELECT * FROM large_data WHERE id BETWEEN $1 AND $2 ORDER BY id',
            10, 25, { batch_size => 5 });

        my $count = 0;
        $count++ while await $ranged->next;
        await $ranged->close;
        print "  fetched $count rows\n";

        await $conn->query('DROP TABLE large_data');
    });
})->()->get;

await $pg->shutdown(timeout => 5);

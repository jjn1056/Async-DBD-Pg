#!/usr/bin/env perl
use strict;
use warnings;

use Future::IO;
use Async::DBD::Pg;

BEGIN { Future::IO->load_best_impl; }

my $dsn = $ENV{DATABASE_URL} // 'postgresql://postgres:test@localhost:5432/test';

my $pg = Async::DBD::Pg->new(
    dsn             => $dsn,
    min_connections => 1,
    max_connections => 5,
);

my $conn = $pg->connection->get;

$conn->query("SET client_min_messages TO warning")->get;
$conn->query('DROP TABLE IF EXISTS large_data')->get;
$conn->query(q{
    CREATE TABLE large_data (
        id SERIAL PRIMARY KEY,
        value TEXT
    )
})->get;

$conn->query(q{
    INSERT INTO large_data (value)
    SELECT 'row_' || generate_series(1, 250)
})->get;

my $cursor = $conn->cursor(
    'SELECT * FROM large_data ORDER BY id',
    { batch_size => 50 }
)->get;

# next yields one row at a time. batch_size above is how many rows come back
# per round trip, which this loop never has to think about.
my ($seen, $first, $last) = (0, undef, undef);
while (my $row = $cursor->next->get) {
    $seen++;
    $first //= $row->{id};
    $last = $row->{id};
}
print "Streamed $seen rows, ids $first - $last, 50 at a time\n";
$cursor->close->get;

print "\nCursor with parameters:\n";
$cursor = $conn->cursor(
    'SELECT * FROM large_data WHERE id BETWEEN $1 AND $2 ORDER BY id',
    10, 25,
    { batch_size => 5 }
)->get;

my $count = 0;
while (my $row = $cursor->next->get) {
    $count++;
}
$cursor->close->get;
print "  fetched $count rows\n";

$conn->query('DROP TABLE large_data')->get;
$conn->release;

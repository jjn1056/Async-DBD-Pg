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

my $conn = eval { $pg->connection->get }
    or die "Connection failed: $@\n";

my $result = $conn->query('SELECT version() AS version')->get;
print "PostgreSQL version:\n";
print "  ", $result->first->{version}, "\n\n";

$result = $conn->query('SELECT generate_series(1, 5) AS n')->get;
print "Generated series:\n";
for my $row (@{$result->rows}) {
    print "  n = $row->{n}\n";
}

$conn->release;

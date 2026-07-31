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

print "Positional placeholders:\n";
my $result = $conn->query('SELECT $1::int + $2::int AS sum', 10, 20)->get;
print "  10 + 20 = ", $result->first->{sum}, "\n";

print "\nNamed placeholders:\n";
$result = $conn->query(
    q{SELECT :first_name || ' ' || :last_name AS full_name},
    { first_name => 'John', last_name => 'Doe' }
)->get;
print "  Full name = ", $result->first->{full_name}, "\n";

my $malicious = q{'; DROP TABLE users; --};
$result = $conn->query('SELECT $1::text AS safely_escaped', $malicious)->get;
print "\nSafely escaped:\n";
print "  ", $result->first->{safely_escaped}, "\n";

$conn->release;

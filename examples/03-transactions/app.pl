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

my $conn = $pg->connection->get;

$conn->query("SET client_min_messages TO warning")->get;
$conn->query('DROP TABLE IF EXISTS accounts')->get;
$conn->query(q{
    CREATE TABLE accounts (
        id SERIAL PRIMARY KEY,
        name TEXT NOT NULL,
        balance NUMERIC(10,2) NOT NULL DEFAULT 0
    )
})->get;

print "Basic transaction:\n";
$conn->transaction(async sub {
    my ($tx) = @_;

    await $tx->query(
        'INSERT INTO accounts (name, balance) VALUES ($1, $2)',
        'Alice', 1000
    );
    await $tx->query(
        'INSERT INTO accounts (name, balance) VALUES ($1, $2)',
        'Bob', 500
    );
})->get;

my $result = $conn->query('SELECT name, balance FROM accounts ORDER BY id')->get;
for my $row (@{$result->rows}) {
    print "  $row->{name}: \$", $row->{balance}, "\n";
}

print "\nRollback on error:\n";
eval {
    $conn->transaction(async sub {
        my ($tx) = @_;
        await $tx->query(
            'UPDATE accounts SET balance = balance - 200 WHERE name = $1',
            'Alice'
        );
        die "Oops, rollback\n";
    })->get;
};
print "  Caught: $@" if $@;

print "\nNested transaction:\n";
$conn->transaction(async sub {
    my ($tx) = @_;

    await $tx->query(
        'UPDATE accounts SET balance = balance - 100 WHERE name = $1',
        'Alice'
    );

    eval {
        await $tx->transaction(async sub {
            my ($tx2) = @_;
            await $tx2->query(
                'UPDATE accounts SET balance = balance + 100 WHERE name = $1',
                'Bob'
            );
            die "inner failure\n";
        });
    };

    await $tx->query(
        'INSERT INTO accounts (name, balance) VALUES ($1, $2)',
        'Charlie', 100
    );
})->get;

$result = $conn->query('SELECT name, balance FROM accounts ORDER BY id')->get;
for my $row (@{$result->rows}) {
    print "  $row->{name}: \$", $row->{balance}, "\n";
}

$conn->query('DROP TABLE accounts')->get;
$conn->release;

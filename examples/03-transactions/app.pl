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
    # Setup needs one connection held across statements: client_min_messages
    # is session-scoped and has to be in effect before DROP/CREATE run.
    await $pg->with_connection(async sub {
        my ($conn) = @_;

        await $conn->query("SET client_min_messages TO warning");
        await $conn->query('DROP TABLE IF EXISTS accounts');
        await $conn->query(q{
            CREATE TABLE accounts (
                id SERIAL PRIMARY KEY,
                name TEXT NOT NULL,
                balance NUMERIC(10,2) NOT NULL DEFAULT 0
            )
        });
    });

    print "Basic transaction:\n";
    await $pg->transaction(async sub {
        my ($tx) = @_;

        await $tx->query(
            'INSERT INTO accounts (name, balance) VALUES ($1, $2)',
            'Alice', 1000
        );
        await $tx->query(
            'INSERT INTO accounts (name, balance) VALUES ($1, $2)',
            'Bob', 500
        );
    });

    my $result = await $pg->query('SELECT name, balance FROM accounts ORDER BY id');
    for my $row (@{$result->rows}) {
        print "  $row->{name}: \$", $row->{balance}, "\n";
    }

    print "\nRollback on error:\n";
    eval {
        await $pg->transaction(async sub {
            my ($tx) = @_;
            await $tx->query(
                'UPDATE accounts SET balance = balance - 200 WHERE name = $1',
                'Alice'
            );
            die "Oops, rollback\n";
        });
    };
    print "  Caught: $@" if $@;

    print "\nNested transaction:\n";
    await $pg->transaction(async sub {
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
    });

    $result = await $pg->query('SELECT name, balance FROM accounts ORDER BY id');
    for my $row (@{$result->rows}) {
        print "  $row->{name}: \$", $row->{balance}, "\n";
    }

    await $pg->query('DROP TABLE accounts');
})->()->get;

await $pg->shutdown(timeout => 5);

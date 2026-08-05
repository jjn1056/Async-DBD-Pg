use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 't/lib';
use Test::Async::DBD::Pg qw(skip_without_postgres test_dsn);

# Skip if no PostgreSQL available
my $dsn = skip_without_postgres();

use Future::IO;

BEGIN { Future::IO->load_best_impl; }

use Async::DBD::Pg;
use Async::DBD::Pg::Connection;
use Async::DBD::Pg::Error;
use Async::DBD::Pg::Util qw(parse_dsn);
use Scalar::Util qw(refaddr);
use DBI;

# Helper to create a connection
sub make_connection {
    my $parsed = parse_dsn(test_dsn());

    my $dbh = DBI->connect(
        $parsed->{dbi_dsn},
        $parsed->{user},
        $parsed->{password},
        {
            AutoCommit     => 1,
            RaiseError     => 1,
            PrintError     => 0,
            pg_enable_utf8 => 1,
        }
    ) or die "Cannot connect: " . DBI->errstr;

    return Async::DBD::Pg::Connection->new(
        dbh => $dbh,
    );
}

subtest 'a transaction keeps its connection across every await' => sub {
    # The bug hand-rolled transaction helpers have is interleaving another
    # query onto the connection between BEGIN and COMMIT. Nothing about that
    # is visible from the return value, so it is asserted directly: every
    # statement the pool runs is recorded with the connection that ran it,
    # and a competing query is deliberately started mid-transaction.
    my @seen;
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 4,
        on_query        => sub { push @seen, $_[0]{sql} },
    );

    $pg->query('CREATE TABLE IF NOT EXISTS tx_iso (id int)')->get;
    $pg->query('DELETE FROM tx_iso')->get;
    @seen = ();

    my ($inside, $other);

    $pg->transaction(async sub {
        my ($conn) = @_;
        $inside = $conn;

        await $conn->query('INSERT INTO tx_iso VALUES (1)');

        # Run an unrelated query to completion while this transaction is
        # suspended, and record which connection it got. Interleaving it onto
        # this one would put a statement inside a transaction it knows
        # nothing about, and roll it back on failure.
        await $pg->with_connection(async sub {
            my ($c) = @_;
            $other = $c;
            await $c->query('SELECT pg_sleep(0.05)');
        });

        await $conn->query('INSERT INTO tx_iso VALUES (3)');
        return 1;
    })->get;

    ok defined $other, 'the competing query ran while the transaction was open';
    isnt refaddr($other), refaddr($inside),
        'and on a different connection, not this transaction\'s';

    is $pg->query_value('SELECT count(*) FROM tx_iso')->get, 2,
        'both statements committed together';

    # BEGIN and COMMIT must bracket this transaction's own statements, with
    # the competing SELECT outside that bracket on the connection level.
    my ($begin) = grep { $seen[$_] =~ /^BEGIN/ } 0 .. $#seen;
    my ($commit) = grep { $seen[$_] =~ /^COMMIT/ } 0 .. $#seen;
    ok defined $begin && defined $commit, 'the transaction bracketed itself';
    ok $begin < $commit, 'in that order';

    ok $inside->is_released, 'the transaction connection went back afterwards';
    is $pg->active_count, 0, 'and so did the competing one';

    $pg->query('DROP TABLE tx_iso')->get;
    $pg->shutdown(timeout => 5)->get;
};

subtest 'retry re-runs the whole transaction, and only for the right errors' => sub {
    my $conn = make_connection();
    $conn->query('CREATE TEMP TABLE tx_retry (id int)')->get;

    # A serialization failure is what the server raises when a transaction
    # loses a race it could win next time, so the whole block runs again.
    my $attempts = 0;
    my $result = $conn->transaction({ retry => 3 }, async sub {
        my ($c) = @_;
        $attempts++;

        await $c->query('INSERT INTO tx_retry VALUES ($1)', $attempts);

        die Async::DBD::Pg::Error::Query->new(
            message => 'could not serialize access', code => '40001',
        ) if $attempts < 3;

        return "ok after $attempts";
    })->get;

    is $result, 'ok after 3', 'the block ran until it succeeded';
    is $attempts, 3, 'three attempts';

    # The rows from the failed attempts must be gone: each attempt is rolled
    # back before the next begins, or a retry would double-insert.
    is $conn->query_value('SELECT count(*) FROM tx_retry')->get, 1,
        'only the successful attempt left anything behind';
    is $conn->query_value('SELECT id FROM tx_retry')->get, 3,
        'and it is the last one';

    $conn->_close_dbh;
};

subtest 'retry gives up, and refuses errors that will not improve' => sub {
    my $conn = make_connection();

    my $tries = 0;
    my $err = dies {
        $conn->transaction({ retry => 2 }, async sub {
            $tries++;
            die Async::DBD::Pg::Error::Query->new(
                message => 'deadlock detected', code => '40P01',
            );
        })->get
    };

    is $tries, 3, 'the first attempt plus two retries';
    like "$err", qr/deadlock detected/, 'the last failure is what propagates';

    # A unique violation will violate uniqueness again. Retrying it is a
    # slower failure, so it is not retried at all.
    my $once = 0;
    my $permanent = dies {
        $conn->transaction({ retry => 5 }, async sub {
            $once++;
            die Async::DBD::Pg::Error::Query->new(
                message => 'duplicate key', code => '23505',
            );
        })->get
    };

    is $once, 1, 'a non-retryable error is attempted exactly once';
    like "$permanent", qr/duplicate key/, 'and propagates unchanged';

    # A plain string exception carries no SQLSTATE and is not retryable.
    my $plain = 0;
    my $plain_err = dies {
        $conn->transaction({ retry => 5 }, async sub { $plain++; die "boom\n" })->get
    };
    like $plain_err, qr/boom/, 'an ordinary die reaches the caller';
    is $plain, 1, 'an ordinary die is attempted once';

    $conn->_close_dbh;
};

subtest 'retry is off unless asked for' => sub {
    my $conn = make_connection();

    my $tries = 0;
    my $err = dies {
        $conn->transaction(async sub {
            $tries++;
            die Async::DBD::Pg::Error::Query->new(
                message => 'serialization failure', code => '40001',
            );
        })->get
    };

    like "$err", qr/serialization failure/,
        'the retryable error reaches the caller instead';
    is $tries, 1, 'a retryable error is not retried by default';

    $conn->_close_dbh;
};

subtest 'retry applies to the transaction, never to a savepoint' => sub {
    my $conn = make_connection();

    # Retrying an inner block would re-run a savepoint rather than the
    # transaction, which is the "retried the wrong scope" bug this feature
    # exists to prevent. Asking for it there is an error, not a silent
    # nothing.
    my $err = dies {
        $conn->transaction(async sub {
            my ($c) = @_;
            await $c->transaction({ retry => 3 }, async sub { 1 });
        })->get
    };

    like "$err", qr/retry.*outermost|outermost.*retry/i,
        'asking for retry inside a transaction is refused';

    $conn->_close_dbh;
};

subtest 'advisory locks are held by the transaction, not the session' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 4,
    );

    my $held = sub {
        my ($conn) = @_;
        return $conn->query_value(
            q{SELECT count(*) FROM pg_locks
               WHERE locktype = 'advisory' AND pid = pg_backend_pid()}
        );
    };

    my $inside;
    $pg->transaction(async sub {
        my ($c) = @_;
        $inside = $c;

        await $c->advisory_lock(4242);
        is await $held->($c), 1, 'the lock is held inside the transaction';

        # A second lock on the same key from the same transaction is free:
        # advisory locks are re-entrant within a session.
        await $c->advisory_lock(4242);
    })->get;

    # This is why the lock is transaction-scoped rather than session-scoped:
    # the connection goes back to the pool, and a session lock would still be
    # held by whoever checks it out next.
    is $pg->with_connection(async sub { await $held->($_[0]) })->get, 0,
        'and released by the transaction ending, with no cleanup call';

    $pg->shutdown(timeout => 5)->get;
};

subtest 'an advisory lock outside a transaction is refused' => sub {
    my $conn = make_connection();

    # pg_advisory_xact_lock outside an explicit transaction is released the
    # instant the implicit one ends, so it locks nothing. Silently doing
    # nothing is the worst outcome for a mutex.
    like dies { $conn->advisory_lock(1)->get },
        qr/advisory_lock needs a transaction/,
        'refused rather than silently useless';

    $conn->_close_dbh;
};

subtest 'try_advisory_lock reports whether it got the lock' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 4,
    );

    # Hold the lock in one transaction while a second tries for it. The
    # blocking form would wait forever here, which is what makes the
    # non-blocking one worth having.
    my $holder_has_it;
    my $other_got_it = 'not run';

    $pg->transaction(async sub {
        my ($c) = @_;
        $holder_has_it = await $c->try_advisory_lock(9191);

        $other_got_it = await $pg->transaction(async sub {
            my ($c2) = @_;
            return await $c2->try_advisory_lock(9191);
        });
    })->get;

    ok $holder_has_it, 'the first transaction took the lock';
    ok !$other_got_it, 'the second was told it could not have it, rather than waiting';

    # Once the holder's transaction is over the key is free again.
    my $after = $pg->transaction(async sub {
        return await $_[0]->try_advisory_lock(9191);
    })->get;
    ok $after, 'and the key is available afterwards';

    $pg->shutdown(timeout => 5)->get;
};

subtest 'advisory locks accept the two-integer key form' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 2,
    );

    # PostgreSQL keys advisory locks by one bigint or two ints, and the two
    # spaces do not collide -- a classifier plus an id is the common use.
    my $ok = $pg->transaction(async sub {
        my ($c) = @_;
        await $c->advisory_lock(17, 99);
        return await $c->query_value(
            q{SELECT count(*) FROM pg_locks
               WHERE locktype = 'advisory' AND pid = pg_backend_pid()}
        );
    })->get;

    is $ok, 1, 'a two-part key locks';

    $pg->shutdown(timeout => 5)->get;
};

subtest 'basic transaction commit' => sub {
    my $conn = make_connection();

    # Create a temp table
    $conn->query('CREATE TEMP TABLE test_tx (id serial PRIMARY KEY, value text)')->get;

    my $result = $conn->transaction(async sub {
        my ($c) = @_;
        await $c->query("INSERT INTO test_tx (value) VALUES ('hello')");
        await $c->query("INSERT INTO test_tx (value) VALUES ('world')");
        return 'done';
    })->get;

    is $result, 'done', 'transaction returned value';

    my $count = $conn->query('SELECT COUNT(*) FROM test_tx')->get;
    is $count->single_value, 2, 'both inserts committed';

    $conn->_close_dbh;
};

subtest 'transaction rollback on error' => sub {
    my $conn = make_connection();

    # Create a temp table
    $conn->query('CREATE TEMP TABLE test_tx2 (id serial PRIMARY KEY, value text NOT NULL)')->get;
    $conn->query("INSERT INTO test_tx2 (value) VALUES ('existing')")->get;

    eval {
        $conn->transaction(async sub {
            my ($c) = @_;
            await $c->query("INSERT INTO test_tx2 (value) VALUES ('new')");
            # This will fail (NULL violation)
            await $c->query("INSERT INTO test_tx2 (value) VALUES (NULL)");
            return 'done';
        })->get;
    };
    my $err = $@;

    ok $err, 'transaction failed';

    my $count = $conn->query('SELECT COUNT(*) FROM test_tx2')->get;
    is $count->single_value, 1, 'only original row exists (transaction rolled back)';

    $conn->_close_dbh;
};

subtest 'nested transaction with savepoints' => sub {
    my $conn = make_connection();

    $conn->query('CREATE TEMP TABLE test_tx3 (id serial PRIMARY KEY, value text)')->get;

    my $result = $conn->transaction(async sub {
        my ($c) = @_;
        await $c->query("INSERT INTO test_tx3 (value) VALUES ('outer')");

        # Nested transaction
        await $c->transaction(async sub {
            my ($c2) = @_;
            await $c2->query("INSERT INTO test_tx3 (value) VALUES ('inner')");
            return 'inner done';
        });

        return 'outer done';
    })->get;

    is $result, 'outer done', 'outer transaction returned';

    my $count = $conn->query('SELECT COUNT(*) FROM test_tx3')->get;
    is $count->single_value, 2, 'both inserts committed';

    $conn->_close_dbh;
};

subtest 'nested transaction rollback' => sub {
    my $conn = make_connection();

    $conn->query('CREATE TEMP TABLE test_tx4 (id serial PRIMARY KEY, value text NOT NULL)')->get;

    my $result = $conn->transaction(async sub {
        my ($c) = @_;
        await $c->query("INSERT INTO test_tx4 (value) VALUES ('outer')");

        # Nested transaction that fails
        eval {
            await $c->transaction(async sub {
                my ($c2) = @_;
                await $c2->query("INSERT INTO test_tx4 (value) VALUES ('inner')");
                die "abort inner";
            });
        };

        # Outer transaction continues
        await $c->query("INSERT INTO test_tx4 (value) VALUES ('after inner')");
        return 'outer done';
    })->get;

    is $result, 'outer done', 'outer transaction completed';

    my $rows = $conn->query('SELECT value FROM test_tx4 ORDER BY id')->get;
    is [ map { $_->{value} } @{$rows->rows} ], ['outer', 'after inner'],
       'inner insert rolled back, outer inserts committed';

    $conn->_close_dbh;
};

subtest 'transaction with isolation level' => sub {
    my $conn = make_connection();

    $conn->query('CREATE TEMP TABLE test_tx5 (id serial PRIMARY KEY, value int)')->get;

    my $result = $conn->transaction({ isolation => 'serializable' }, async sub {
        my ($c) = @_;
        await $c->query("INSERT INTO test_tx5 (value) VALUES (42)");
        return 'done';
    })->get;

    is $result, 'done', 'transaction with isolation level completed';

    $conn->_close_dbh;
};

subtest 'transaction forwards trailing arguments to its callback' => sub {
    my $pg   = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 3);
    my $conn = $pg->connection->get;
    $conn->query('CREATE TEMP TABLE argtest (n int, tag text)')->get;

    # Passed in rather than closed over, so a caller looping over work does
    # not have to reason about what each closure captured.
    $conn->transaction(async sub {
        my ($tx, $n, $tag) = @_;
        await $tx->query('INSERT INTO argtest VALUES ($1, $2)', $n, $tag);
    }, 42, 'from-args')->get;

    my $r = $conn->query('SELECT n, tag FROM argtest')->get->first;
    is $r->{n}, 42, 'a trailing argument reached the callback';
    is $r->{tag}, 'from-args', 'and so did the second';

    $conn->release;
    $pg->shutdown->get;
};

subtest 'transaction takes its options first, where they are visible' => sub {
    my $pg   = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 3);
    my $conn = $pg->connection->get;

    my $level = $conn->transaction({ isolation => 'serializable' }, async sub {
        my ($tx) = @_;
        return await $tx->query('SHOW transaction_isolation');
    })->get;
    is $level->first->{transaction_isolation}, 'serializable',
        'a leading options hashref is read as options';

    # And options plus arguments together, which is the shape that has to work
    # for the convention to be worth having.
    my $got = $conn->transaction({ isolation => 'serializable' }, async sub {
        my ($tx, $value) = @_;
        return $value;
    }, 'passed-through')->get;
    is $got, 'passed-through', 'options and arguments coexist';

    $conn->release;
    $pg->shutdown->get;
};

subtest 'a nested transaction forwards arguments too' => sub {
    my $pg   = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 3);
    my $conn = $pg->connection->get;
    $conn->query('CREATE TEMP TABLE nestargs (tag text)')->get;

    # The inner transaction takes the savepoint path, a different $code->()
    # call site from the outer, top-level one. Forwarding was added to both;
    # the subtests above only ever exercised the top-level one.
    $conn->transaction(async sub {
        my ($c, $outer) = @_;
        await $c->query('INSERT INTO nestargs VALUES ($1)', $outer);

        await $c->transaction(async sub {
            my ($c2, $inner) = @_;
            await $c2->query('INSERT INTO nestargs VALUES ($1)', $inner);
        }, 'from-savepoint');
    }, 'from-outer')->get;

    my @tags = map { $_->{tag} }
        @{ $conn->query('SELECT tag FROM nestargs ORDER BY tag')->get->rows };
    is \@tags, ['from-outer', 'from-savepoint'],
        'both the outer and the nested callback received their arguments';

    $conn->release;
    $pg->shutdown->get;
};

done_testing;

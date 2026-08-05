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

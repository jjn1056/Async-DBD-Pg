use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 't/lib';
use Test::Future::IO::Pg qw(skip_without_postgres test_dsn);

# Skip if no PostgreSQL available
my $dsn = skip_without_postgres();

# Load Future::IO implementation
use Future::IO::Impl::IOAsync;

use Future::IO::Pg::Connection;
use Future::IO::Pg::Util qw(parse_dsn);
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

    return Future::IO::Pg::Connection->new(
        dbh => $dbh,
    );
}

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
    is $count->scalar, 2, 'both inserts committed';

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
    is $count->scalar, 1, 'only original row exists (transaction rolled back)';

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
    is $count->scalar, 2, 'both inserts committed';

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

    my $result = $conn->transaction(async sub {
        my ($c) = @_;
        await $c->query("INSERT INTO test_tx5 (value) VALUES (42)");
        return 'done';
    }, isolation => 'serializable')->get;

    is $result, 'done', 'transaction with isolation level completed';

    $conn->_close_dbh;
};

done_testing;

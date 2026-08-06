use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 't/lib';
use Test::Async::DBD::Pg qw(skip_without_postgres test_dsn);

my $dsn = skip_without_postgres();

use Future::IO;
BEGIN { Future::IO->load_best_impl; }

use Async::DBD::Pg;

# Driven by real violations rather than constructed errors, because the point
# is that the server's diagnostics reach the caller, not that a hash holds
# what was put in it.
sub with_table {
    my ($cache, $code) = @_;

    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 1,
        statement_cache_size => $cache,
    );
    my $conn = $pg->connection->get;

    $conn->query('SET client_min_messages = warning')->get;
    $conn->query('DROP TABLE IF EXISTS diag_child')->get;
    $conn->query('DROP TABLE IF EXISTS diag_parent')->get;
    $conn->query('CREATE TABLE diag_parent (
        id int PRIMARY KEY,
        email text CONSTRAINT diag_parent_email_key UNIQUE,
        qty int NOT NULL
    )')->get;
    $conn->query('CREATE TABLE diag_child (
        id int PRIMARY KEY,
        parent_id int CONSTRAINT diag_child_parent_fk REFERENCES diag_parent(id)
    )')->get;
    $conn->query('INSERT INTO diag_parent VALUES ($1,$2,$3)', 1, 'a@b.c', 1)->get;

    $code->($conn);

    $conn->query('DROP TABLE diag_child')->get;
    $conn->query('DROP TABLE diag_parent')->get;
    $conn->release;
    $pg->shutdown(timeout => 5)->get;
}

subtest 'each predicate is true only for its own violation' => sub {
    with_table(0, sub {
        my ($conn) = @_;

        my $unique = dies {
            $conn->query('INSERT INTO diag_parent VALUES ($1,$2,$3)', 2, 'a@b.c', 1)->get
        };
        ok $unique->is_unique_violation, 'unique: is_unique_violation';
        ok !$unique->is_foreign_key_violation, 'unique: not foreign key';
        ok !$unique->is_not_null_violation, 'unique: not null violation is false';
        ok !$unique->is_retryable, 'unique: not retryable';
        is $unique->constraint, 'diag_parent_email_key', 'unique: names the constraint';

        my $notnull = dies {
            $conn->query('INSERT INTO diag_parent VALUES ($1,$2,$3)', 3, 'x@y.z', undef)->get
        };
        ok $notnull->is_not_null_violation, 'not null: is_not_null_violation';
        ok !$notnull->is_unique_violation, 'not null: not unique';
        is $notnull->column, 'qty', 'not null: names the column';

        my $fk = dies {
            $conn->query('INSERT INTO diag_child VALUES ($1,$2)', 1, 999)->get
        };
        ok $fk->is_foreign_key_violation, 'fk: is_foreign_key_violation';
        ok !$fk->is_unique_violation, 'fk: not unique';
        is $fk->constraint, 'diag_child_parent_fk', 'fk: names the constraint';
    });
};

subtest 'diagnostics survive with the statement cache on' => sub {
    # The cache is the configuration whose eviction sends DEALLOCATE, which
    # pg_error_field documents as resetting every field. It survives because
    # the statement handle outlives the capture; this asserts that it does.
    with_table(10, sub {
        my ($conn) = @_;

        my $err = dies {
            $conn->query('INSERT INTO diag_parent VALUES ($1,$2,$3)', 2, 'a@b.c', 1)->get
        };

        ok $err->is_unique_violation, 'still classified with the cache on';
        is $err->constraint, 'diag_parent_email_key', 'constraint survives';
        is $err->table, 'diag_parent', 'table survives';
        like $err->detail, qr/already exists/, 'detail survives';
    });
};

done_testing;

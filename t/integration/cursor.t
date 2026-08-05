use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;
use File::Temp qw(tempfile);

use lib 't/lib';
use Test::Async::DBD::Pg qw(skip_without_postgres test_dsn);

my $dsn = skip_without_postgres();

use Future::IO;

BEGIN { Future::IO->load_best_impl; }

use Async::DBD::Pg;

sub make_pool {
    return Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 2,
    );
}

# See t/integration/pubsub.t for why this captures the file descriptor
# rather than trusting a warning handler alone.
sub capture_stderr {
    my ($code) = @_;

    my ($fh, $path) = tempfile(UNLINK => 1);
    close $fh;

    open my $saved_stderr, '>&', \*STDERR or die "dup stderr: $!";
    open STDERR, '>', $path or die "redirect stderr: $!";

    my $ok = eval { $code->(); 1 };
    my $err = $@;

    open STDERR, '>&', $saved_stderr or die "restore stderr: $!";
    close $saved_stderr;

    die $err unless $ok;

    open my $read_fh, '<', $path or die "read captured stderr: $!";
    local $/;
    my $captured = <$read_fh>;
    close $read_fh;

    return $captured;
}

subtest 'next walks the result in batches' => sub {
    my $pg = make_pool();
    my $conn = $pg->connection->get;

    my $cursor = $conn->cursor(
        'SELECT generate_series(1, 25) AS n', { batch_size => 10 }
    )->get;

    is $cursor->batch_size, 10, 'batch size recorded';
    ok !$cursor->is_exhausted, 'not exhausted before fetching';

    # next yields one row, so a cursor loop reads the same way an eager one
    # does. batch_size is how many rows come back per round trip, which is a
    # transport detail rather than something the caller sees.
    my @seen;
    while (defined(my $row = $cursor->next->get)) {
        push @seen, $row->{n};
    }

    is scalar @seen, 25, 'every row was delivered one at a time';
    is [ @seen[0, 1] ], [1, 2], 'in order from the first';
    is $seen[-1], 25, 'through to the last';
    ok $cursor->is_exhausted, 'exhausted once the rows run out';
    is $cursor->next->get, undef, 'and stays undef';

    $cursor->close->get;
    $conn->release;
};

subtest 'batch_size changes round trips, not results' => sub {
    my $pg = make_pool();
    my $conn = $pg->connection->get;

    # The connection counts every statement it runs, which is how the cost of
    # a batch size can be observed at all now that the caller only sees rows.
    my $fetches = sub {
        my ($size) = @_;

        my $before = $conn->query_count;
        my $cursor = $conn->cursor(
            'SELECT generate_series(1, 20) AS n', { batch_size => $size }
        )->get;

        my @rows;
        while (defined(my $row = $cursor->next->get)) { push @rows, $row->{n} }
        $cursor->close->get;

        return ($conn->query_count - $before, \@rows);
    };

    my ($few_trips, $rows_a) = $fetches->(20);
    my ($many_trips, $rows_b) = $fetches->(2);

    is $rows_a, [1 .. 20], 'twenty rows at a batch size of twenty';
    is $rows_b, [1 .. 20], 'the same twenty rows at a batch size of two';
    ok $many_trips > $few_trips,
        "a smaller batch costs more round trips ($many_trips against $few_trips)";

    $conn->release;
};

subtest 'each visits every row and counts them' => sub {
    my $pg = make_pool();
    my $conn = $pg->connection->get;

    my $cursor = $conn->cursor(
        'SELECT generate_series(1, 7) AS n', { batch_size => 3 }
    )->get;

    my @seen;
    my $count = $cursor->each(sub { push @seen, $_[0]{n} })->get;

    is $count, 7, 'returns the number of rows visited';
    is \@seen, [1 .. 7], 'every row visited once, in order, across batches';

    $cursor->close->get;
    $conn->release;
};

subtest 'all collects the remaining rows' => sub {
    my $pg = make_pool();
    my $conn = $pg->connection->get;

    my $cursor = $conn->cursor(
        'SELECT generate_series(1, 5) AS n', { batch_size => 2 }
    )->get;

    # Take one row first, so "remaining" is what is actually returned. The
    # rest of that row's batch is already in hand and must not be lost.
    my $first = $cursor->next->get;
    is $first->{n}, 1, 'one row taken';

    my $rest = $cursor->all->get;
    isa_ok $rest, 'Async::DBD::Pg::Collection';
    is [ map { $_->{n} } @$rest ], [2, 3, 4, 5],
        'all returns every row that was left, buffered ones included';
    is $rest->size, 4, 'and it is the same collection Results::all returns';

    $cursor->close->get;
    $conn->release;
};

subtest 'a cursor over no rows is exhausted immediately' => sub {
    my $pg = make_pool();
    my $conn = $pg->connection->get;

    my $cursor = $conn->cursor('SELECT 1 AS n WHERE false')->get;

    is $cursor->next->get, undef, 'no row to fetch';
    ok $cursor->is_exhausted, 'exhausted';
    is $cursor->all->get, [], 'all returns nothing';

    $cursor->close->get;
    $conn->release;
};

subtest 'closing commits the transaction the cursor started' => sub {
    my $pg = make_pool();
    my $conn = $pg->connection->get;

    ok !$conn->in_transaction, 'no transaction before the cursor';

    my $cursor = $conn->cursor('SELECT generate_series(1, 3) AS n')->get;
    ok $conn->in_transaction, 'cursor opened a transaction to live in';

    $cursor->close->get;

    ok $cursor->is_closed, 'cursor reports closed';
    ok !$conn->in_transaction, 'transaction finished with the cursor';

    # The connection is usable straight afterwards.
    my $after = $conn->query('SELECT 42 AS answer')->get;
    is $after->first->{answer}, 42, 'connection still works';

    $conn->release;
};

subtest 'a cursor inside a caller transaction leaves it alone' => sub {
    my $pg = make_pool();
    my $conn = $pg->connection->get;

    my $rows = $conn->transaction(async sub {
        my ($c) = @_;

        my $cursor = await $c->cursor(
            'SELECT generate_series(1, 4) AS n', { batch_size => 2 }
        );
        my $all = await $cursor->all;
        await $cursor->close;

        # Closing the cursor must not have ended the caller's transaction,
        # which still has work to do.
        ok $c->in_transaction, 'still inside the caller transaction';

        return $all;
    })->get;

    is scalar @$rows, 4, 'cursor read inside a transaction';
    ok !$conn->in_transaction, 'transaction committed by its own block';

    $conn->release;
};

subtest 'closing twice is harmless' => sub {
    my $pg = make_pool();
    my $conn = $pg->connection->get;

    my $cursor = $conn->cursor('SELECT generate_series(1, 3) AS n')->get;
    $cursor->close->get;

    ok lives { $cursor->close->get }, 'second close does nothing';

    $conn->release;
};

subtest 'draining a cursor finishes it' => sub {
    my $pg   = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 3);
    my $conn = $pg->connection->get;
    $conn->query('CREATE TEMP TABLE drained AS SELECT g AS id FROM generate_series(1,250) g')->get;

    my $cursor = $conn->cursor('SELECT id FROM drained', { batch_size => 100 })->get;

    my $seen = 0;
    my $noise = capture_stderr(sub {
        $cursor->each(async sub { $seen++ })->get;
    });

    is $seen, 250, 'every row was delivered';
    ok $cursor->is_exhausted, 'the cursor knows it is exhausted';
    ok $cursor->is_closed, 'and closed itself rather than warning about it later';
    ok !$conn->in_transaction,
        'the transaction the cursor opened was ended, not left on the connection';
    is $noise, '', 'nothing was written to stderr';

    $conn->release;
    $pg->shutdown->get;
};

subtest 'a cursor abandoned before exhaustion still warns' => sub {
    my $pg   = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 3);
    my $conn = $pg->connection->get;
    $conn->query('CREATE TEMP TABLE partial AS SELECT g AS id FROM generate_series(1,250) g')->get;

    # Closing on exhaustion must not silence the case the warning is for:
    # a caller who walks away mid-stream still leaves a cursor open.
    my $noise = capture_stderr(sub {
        my $cursor = $conn->cursor('SELECT id FROM partial', { batch_size => 10 })->get;
        $cursor->next->get;
        undef $cursor;
    });
    like $noise, qr/discarded without close/,
        'abandoning a cursor part-way through is still reported';

    $conn->release;
    $pg->shutdown->get;
};

subtest 'each forwards trailing arguments to its callback' => sub {
    my $pg   = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 3);
    my $conn = $pg->connection->get;
    $conn->query('CREATE TEMP TABLE eachargs AS SELECT g AS id FROM generate_series(1,5) g')->get;

    my $cursor = $conn->cursor('SELECT id FROM eachargs', { batch_size => 2 })->get;
    my @seen;
    $cursor->each(async sub {
        my ($row, $prefix) = @_;
        push @seen, "$prefix$row->{id}";
    }, 'row-')->get;

    is scalar(@seen), 5, 'every row was delivered';
    is $seen[0], 'row-1', 'and the trailing argument came with it';

    $conn->release;
    $pg->shutdown->get;
};

done_testing;

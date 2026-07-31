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
use DBD::Pg;

# libpq may drop and re-establish the socket while the startup handshake is
# in progress, e.g. when GSSAPI or SSL encryption is offered and declined.
# DBD::Pg documents this: "The socket may have changed after each call to
# the method." A pool that captures pg_socket once waits on the abandoned
# connection forever, so bound the wait and fail rather than hang.
my $DEADLINE = 15;

sub acquire_within {
    my ($pg, $label) = @_;

    my $connection = $pg->connection;
    my $deadline   = Future::IO->sleep($DEADLINE);

    # wait_any cancels the loser, and a cancelled future reports is_ready,
    # so completion has to be tested with is_done.
    eval { Future->wait_any($connection, $deadline)->get; 1 }
        or diag("$label: connect failed: $@");

    return $connection->is_done ? $connection->get : undef;
}

subtest 'pooled connection completes the async connect handshake' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
    );

    my $conn = acquire_within($pg, 'first');

    ok $conn, "acquired a pooled connection within ${DEADLINE}s"
        or return;

    isa_ok $conn, 'Async::DBD::Pg::Connection';

    my $result = $conn->query('SELECT 42 AS answer')->get;
    is $result->first->{answer}, 42, 'connection acquired from the pool is usable';

    $conn->release;
};

subtest 'handshake succeeds repeatedly' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
    );

    # Each new connection runs its own handshake, so a socket swap has to be
    # tolerated every time rather than only on a lucky first attempt.
    my @conns;
    for my $n (1 .. 3) {
        my $conn = acquire_within($pg, "connection $n");
        ok $conn, "connection $n established within ${DEADLINE}s"
            or next;
        push @conns, $conn;
    }

    is scalar @conns, 3, 'three concurrent pooled connections established';

    $_->release for @conns;
};

done_testing;

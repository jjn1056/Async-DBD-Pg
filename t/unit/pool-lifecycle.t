use strict;
use warnings;
use Test2::V0;

use Async::DBD::Pg;
use Async::DBD::Pg::Connection;

{
    package Test::Async::DBD::Pg::FakeDBH;

    sub new {
        my ($class, %args) = @_;
        return bless {
            disconnects => 0,
            ping        => $args{ping} // 1,
        }, $class;
    }

    sub disconnect {
        my ($self) = @_;
        $self->{disconnects}++;
        return 1;
    }

    # Connection::DESTROY releases back to the pool, which pings.
    sub ping {
        my ($self) = @_;
        $self->{pings}++;
        return $self->{ping};
    }

    sub pings { shift->{pings} // 0 }

    sub disconnects {
        my ($self) = @_;
        return $self->{disconnects};
    }
}

{
    package Test::Async::DBD::Pg::FakePool;

    sub new {
        my ($class) = @_;
        return bless { returned => [] }, $class;
    }

    sub _return_connection {
        my ($self, $conn) = @_;
        push @{$self->{returned}}, $conn;
    }

    sub returned_count {
        my ($self) = @_;
        return scalar @{$self->{returned}};
    }
}

subtest 'connection destroy returns to pool without closing dbh' => sub {
    my $pool = Test::Async::DBD::Pg::FakePool->new;
    my $dbh = Test::Async::DBD::Pg::FakeDBH->new;

    {
        my $conn = Async::DBD::Pg::Connection->new(
            dbh  => $dbh,
            pool => $pool,
        );
    }

    is $pool->returned_count, 1, 'connection returned to pool';
    is $dbh->disconnects, 0, 'dbh not closed during pool return';
};

subtest 'fork cleanup closes pooled connections' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => 'postgresql://user:pass@localhost/db',
        min_connections => 0,
        max_connections => 2,
    );

    my $dbh1 = Test::Async::DBD::Pg::FakeDBH->new;
    my $dbh2 = Test::Async::DBD::Pg::FakeDBH->new;

    push @{$pg->{idle}}, Async::DBD::Pg::Connection->new(dbh => $dbh1, pool => $pg);
    push @{$pg->{active}}, Async::DBD::Pg::Connection->new(dbh => $dbh2, pool => $pg);

    local $pg->{pid} = $$ - 1;
    $pg->_check_fork;

    is $dbh1->disconnects, 1, 'idle connection closed';
    is $dbh2->disconnects, 1, 'active connection closed';
    is $pg->idle_count, 0, 'idle pool cleared';
    is $pg->active_count, 0, 'active pool cleared';
};

sub make_pool {
    my (%args) = @_;

    # min_connections stays 0 during construction so no connection is
    # attempted, then is set directly for tests that need a floor.
    my $min = delete $args{min_connections} // 0;

    my $pg = Async::DBD::Pg->new(
        dsn             => 'postgresql://user:pass@localhost/db',
        min_connections => 0,
        max_connections => 5,
        %args,
    );

    $pg->{min_connections} = $min;
    return $pg;
}

sub add_idle {
    my ($pg, $idle_for) = @_;

    my $dbh = Test::Async::DBD::Pg::FakeDBH->new;
    my $conn = Async::DBD::Pg::Connection->new(dbh => $dbh, pool => $pg);
    $conn->{last_used} = time() - ($idle_for // 0);
    push @{$pg->{idle}}, $conn;

    return $dbh;
}

subtest 'a connection that fails its check is discarded' => sub {
    my $pg = make_pool();
    my $dbh = Test::Async::DBD::Pg::FakeDBH->new(ping => 0);

    my $conn = Async::DBD::Pg::Connection->new(dbh => $dbh, pool => $pg);
    push @{$pg->{active}}, $conn;
    $conn->release;

    is $pg->idle_count, 0, 'dead connection not put back for reuse';
    is $dbh->disconnects, 1, 'dead connection closed';
    is $pg->stats->{discarded}, 1, 'discard recorded';
};

subtest 'a connection past max_queries is retired' => sub {
    my $pg = make_pool(max_queries => 5);
    my $dbh = Test::Async::DBD::Pg::FakeDBH->new;

    my $conn = Async::DBD::Pg::Connection->new(dbh => $dbh, pool => $pg);
    $conn->{query_count} = 5;
    push @{$pg->{active}}, $conn;
    $conn->release;

    is $pg->idle_count, 0, 'worn out connection not reused';
    is $dbh->disconnects, 1, 'worn out connection closed';

    # A connection still short of the limit goes back as normal.
    my $fresh_dbh = Test::Async::DBD::Pg::FakeDBH->new;
    my $fresh = Async::DBD::Pg::Connection->new(dbh => $fresh_dbh, pool => $pg);
    $fresh->{query_count} = 4;
    push @{$pg->{active}}, $fresh;
    $fresh->release;

    is $pg->idle_count, 1, 'connection under the limit returned to the pool';
    is $fresh_dbh->disconnects, 0, 'and left open';
};

subtest 'destroying a connection does not make a blocking round trip' => sub {
    my $pg = make_pool();
    my $dbh = Test::Async::DBD::Pg::FakeDBH->new;

    {
        my $conn = Async::DBD::Pg::Connection->new(dbh => $dbh, pool => $pg);
    }

    # ping is a network round trip. Running one from DESTROY can stall the
    # reactor while the event loop is being torn down.
    is $dbh->pings, 0, 'no ping issued while destroying the connection';
    is $pg->idle_count, 1, 'connection still returned to the pool';
    is $dbh->disconnects, 0, 'connection not closed';
};

subtest 'an explicit release still validates the connection' => sub {
    my $pg = make_pool();
    my $dbh = Test::Async::DBD::Pg::FakeDBH->new;

    my $conn = Async::DBD::Pg::Connection->new(dbh => $dbh, pool => $pg);
    $conn->release;

    is $dbh->pings, 1, 'released connection checked before reuse';
    is $pg->idle_count, 1, 'connection returned to the pool';
};

subtest 'is_healthy reports whether a connection can be served now' => sub {
    my $pg = make_pool(max_connections => 2);

    ok $pg->is_healthy, 'healthy while there is room to create a connection';

    add_idle($pg);
    ok $pg->is_healthy, 'healthy while a connection is sitting idle';

    # One idle, one busy, at the limit: the idle one can still be handed out.
    push @{$pg->{active}},
        Async::DBD::Pg::Connection->new(
            dbh  => Test::Async::DBD::Pg::FakeDBH->new,
            pool => $pg,
        );
    ok $pg->is_healthy, 'healthy at the limit while a connection is idle';

    # Every connection busy and no room to grow: a caller would have to queue.
    @{$pg->{idle}} = ();
    push @{$pg->{active}},
        Async::DBD::Pg::Connection->new(
            dbh  => Test::Async::DBD::Pg::FakeDBH->new,
            pool => $pg,
        );
    ok !$pg->is_healthy, 'not healthy when every connection is busy at the limit';
};

subtest 'idle connections are closed once idle_timeout passes' => sub {
    my $pg = make_pool(idle_timeout => 60);

    my $stale   = add_idle($pg, 120);
    my $stale2  = add_idle($pg, 61);
    my $fresh   = add_idle($pg, 5);

    $pg->_reap_idle_connections;

    is $pg->idle_count, 1, 'only the connection inside the timeout is kept';
    is $stale->disconnects,  1, 'first expired connection closed';
    is $stale2->disconnects, 1, 'second expired connection closed';
    is $fresh->disconnects,  0, 'connection inside the timeout left alone';
};

subtest 'reaping keeps min_connections' => sub {
    my $pg = make_pool(idle_timeout => 60, min_connections => 2);

    add_idle($pg, 120) for 1 .. 3;

    $pg->_reap_idle_connections;

    is $pg->idle_count, 2, 'floor retained even though all were expired';
};

subtest 'active connections count towards the floor' => sub {
    my $pg = make_pool(idle_timeout => 60, min_connections => 2);

    push @{$pg->{active}},
        Async::DBD::Pg::Connection->new(
            dbh  => Test::Async::DBD::Pg::FakeDBH->new,
            pool => $pg,
        );
    add_idle($pg, 120) for 1 .. 3;

    $pg->_reap_idle_connections;

    is $pg->idle_count, 1, 'one idle kept because a busy connection counts';
    is $pg->total_count, 2, 'pool held at min_connections';
};

subtest 'idle_timeout of 0 disables reaping' => sub {
    my $pg = make_pool(idle_timeout => 0);

    my $stale = add_idle($pg, 10_000);

    $pg->_reap_idle_connections;

    is $pg->idle_count, 1, 'nothing reaped when the timeout is disabled';
    is $stale->disconnects, 0, 'connection left open';
};

subtest 'healing dead connections is on unless turned off' => sub {
    my $on = make_pool();
    is $on->{heal_dead_connections}, 1, 'on by default';

    my $off = make_pool(heal_dead_connections => 0);
    is $off->{heal_dead_connections}, 0, 'can be turned off';
};

subtest 'discarding idle connections leaves checked out ones alone' => sub {
    my $pg = make_pool();

    my @idle_dbh = map { add_idle($pg) } 1 .. 3;

    my $busy_dbh = Test::Async::DBD::Pg::FakeDBH->new;
    push @{$pg->{active}},
        Async::DBD::Pg::Connection->new(dbh => $busy_dbh, pool => $pg);

    my $discarded = $pg->_discard_idle_connections;

    is $discarded, 3, 'reports how many it closed';
    is $pg->idle_count, 0, 'idle list emptied';
    is $_->disconnects, 1, 'idle connection closed' for @idle_dbh;

    # Somebody else is using this one. Closing it underneath them would be
    # worse than the outage.
    is $pg->active_count, 1, 'checked out connection still in the pool';
    is $busy_dbh->disconnects, 0, 'and still open';

    is $pg->stats->{discarded}, 3, 'counted as discarded';
};

subtest 'discarding idle connections with none idle is harmless' => sub {
    my $pg = make_pool();
    is $pg->_discard_idle_connections, 0, 'nothing to do, nothing done';
};

done_testing;

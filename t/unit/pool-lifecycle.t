use strict;
use warnings;
use Test2::V0;

use Async::DBD::Pg;
use Async::DBD::Pg::Connection;

{
    package Test::Async::DBD::Pg::FakeDBH;

    sub new {
        my ($class) = @_;
        return bless { disconnects => 0 }, $class;
    }

    sub disconnect {
        my ($self) = @_;
        $self->{disconnects}++;
        return 1;
    }

    # Connection::DESTROY releases back to the pool, which pings.
    sub ping { 1 }

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

done_testing;

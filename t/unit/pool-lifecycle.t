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

done_testing;

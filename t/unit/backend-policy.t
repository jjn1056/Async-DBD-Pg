use strict;
use warnings;
use Test2::V0;

use Async::DBD::Pg;

sub make_pg {
    return Async::DBD::Pg->new(
        dsn             => 'postgresql://user:pass@localhost/db',
        min_connections => 0,
        max_connections => 1,
    );
}

subtest 'async connect supported with capable impl and DBD::Pg 3.19+' => sub {
    my $pg = make_pg();

    local $DBD::Pg::VERSION = '3.19.0';

    ok $pg->_supports_async_connect, 'async connect enabled';
};

subtest 'async connect disabled before DBD::Pg 3.19.0' => sub {
    my $pg = make_pg();

    local $DBD::Pg::VERSION = '3.18';

    ok !$pg->_supports_async_connect, 'async connect disabled';
};

done_testing;

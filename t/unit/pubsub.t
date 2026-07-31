use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(refaddr);

use Async::DBD::Pg;
use Async::DBD::Pg::PubSub;

subtest 'constructor' => sub {
    my $pubsub = Async::DBD::Pg::PubSub->new();

    isa_ok $pubsub, 'Async::DBD::Pg::PubSub';
    is $pubsub->subscribed_channels, 0, 'no channels initially';
    ok !$pubsub->is_connected, 'not connected initially';
};

subtest 'channel name validation' => sub {
    my $pubsub = Async::DBD::Pg::PubSub->new();

    ok $pubsub->_validate_channel('my_channel'), 'valid: lowercase and underscore';
    ok $pubsub->_validate_channel('Channel123'), 'valid: mixed case and numbers';
    ok $pubsub->_validate_channel('a'), 'valid: single char';

    ok !$pubsub->_validate_channel(''), 'invalid: empty';
    ok !$pubsub->_validate_channel('has space'), 'invalid: contains space';
    ok !$pubsub->_validate_channel('has;semicolon'), 'invalid: contains semicolon';
    ok !$pubsub->_validate_channel("has\nnewline"), 'invalid: contains newline';
};

subtest 'pool returns cached pubsub instance' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => 'postgresql://user:secret@localhost/test',
        min_connections => 0,
        max_connections => 1,
    );

    my $first = $pg->pubsub;
    my $second = $pg->pubsub;

    isa_ok $first, 'Async::DBD::Pg::PubSub';
    is refaddr($second), refaddr($first), 'cached pubsub reused';
};

done_testing;

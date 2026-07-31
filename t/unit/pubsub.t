use strict;
use warnings;
use Test2::V0;
use Scalar::Util qw(refaddr);
use Future;

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

{
    package Test::Async::DBD::Pg::FlakyConn;

    use Future;

    sub new {
        my ($class, %args) = @_;
        return bless { fail_next => $args{fail_next} // 0, seen => [] }, $class;
    }

    sub dbh { 1 }

    sub query {
        my ($self, $sql, @bind) = @_;
        push @{$self->{seen}}, $sql;

        if ($self->{fail_next}) {
            $self->{fail_next}--;
            return Future->fail("control query failed\n");
        }

        return Future->done(1);
    }

    sub statements { shift->{seen} }
}

subtest 'a failed control query leaves pub/sub usable' => sub {
    my $pubsub = Async::DBD::Pg::PubSub->new();

    # Stand in for a live listener connection whose first statement fails.
    # A listener future has to be present, because stopping it is what sets
    # _stopping in the first place. connected stays false so the listener is
    # not restarted here, which would need a real socket; restarting it is
    # covered by t/integration/pubsub.t.
    my $conn = Test::Async::DBD::Pg::FlakyConn->new(fail_next => 1);
    $pubsub->{conn} = $conn;
    $pubsub->{connected} = 0;
    $pubsub->{_listener_future} = Future->done(1);

    my $err = dies { $pubsub->_run_control_query('LISTEN failing')->get };
    ok $err, 'the failing statement is reported to the caller';

    # _stopping gates the listener loop. Left set, every later listen and
    # unlisten silently does nothing.
    is $pubsub->{_stopping}, 0, 'listener not left in the stopping state';

    ok lives { $pubsub->_run_control_query('LISTEN working')->get },
        'a later control query still runs';
    like $conn->statements->[-1], qr/LISTEN working/,
        'the later statement reached the connection';
};

done_testing;

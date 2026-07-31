use strict;
use warnings;
use Test2::V0;
use Time::HiRes qw(time);

use lib 't/lib';
use Test::Async::DBD::Pg qw(skip_without_postgres test_dsn);

my $dsn = skip_without_postgres();

use Future::IO;

BEGIN { Future::IO->load_best_impl; }

use Async::DBD::Pg;

sub wait_until {
    my ($code, $label, $timeout) = @_;

    $timeout //= 1;
    my $deadline = time + $timeout;

    while (time < $deadline) {
        return 1 if $code->();
        Future::IO->sleep(0.05)->get;
    }

    return 0;
}

subtest 'create pubsub instance' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
    );

    my $pubsub = $pg->pubsub;

    isa_ok $pubsub, 'Async::DBD::Pg::PubSub';
    ok !$pubsub->is_connected, 'not connected before listen';
    is $pubsub->subscribed_channels, 0, 'no channels';

    $pubsub->disconnect->get;
};

subtest 'a callback that dies does not stop the others or the listener' => sub {
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
        on_log          => sub { push @logged, $_[1] },
    );
    my $pubsub = $pg->pubsub;

    my (@second, @later);

    $pubsub->listen('cb_error_test', sub { die "callback exploded\n" })->get;
    $pubsub->listen('cb_error_test', sub { push @second, $_[1] })->get;

    $pubsub->notify('cb_error_test', 'first')->get;
    wait_until(sub { @second }, 'second callback ran', 3);

    is \@second, ['first'], 'a callback dying does not stop the next one';
    ok scalar(grep { /callback exploded/ } @logged),
        'the failure is reported rather than swallowed';

    # The listener has to survive, or one bad callback ends every
    # subscription on the connection.
    $pubsub->listen('cb_error_later', sub { push @later, $_[1] })->get;
    $pubsub->notify('cb_error_later', 'second')->get;
    wait_until(sub { @later }, 'listener still running', 3);

    is \@later, ['second'], 'listener still delivering after the failure';

    $pubsub->disconnect->get;
};

subtest 'concurrent connect checks out a single connection' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
    );
    my $pubsub = $pg->pubsub;

    # connected is only set once a connection has been handed over, so two
    # callers arriving together must still share one attempt. Otherwise each
    # checks one out and only the last is kept; the rest are never released.
    my @attempts = map { $pubsub->connect } 1 .. 3;
    $_->get for @attempts;

    ok $pubsub->is_connected, 'pub/sub connected';
    is $pg->active_count, 1, 'exactly one connection checked out of the pool';

    $pubsub->disconnect->get;
    is $pg->active_count, 0, 'connection returned on disconnect';
};

subtest 'listen and receive notification' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
    );
    my $pubsub = $pg->pubsub;
    my @received;

    $pubsub->listen('notify_test', sub {
        my ($channel, $payload, $pid) = @_;
        push @received, { channel => $channel, payload => $payload, pid => $pid };
    })->get;

    ok $pubsub->is_connected, 'connected after listen';
    is $pubsub->subscribed_channels, 1, 'one channel subscribed';

    my $conn = $pg->connection->get;
    $conn->query("NOTIFY notify_test, 'hello'")->get;
    $conn->release;

    ok wait_until(sub { @received == 1 }, 'notification delivery'), 'received notification';
    is $received[0]{channel}, 'notify_test', 'correct channel';
    is $received[0]{payload}, 'hello', 'correct payload';

    $pubsub->disconnect->get;
};

subtest 'notify via pubsub helper' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
    );
    my @received;

    $pg->listen('pubsub_notify', sub {
        my ($channel, $payload, $pid) = @_;
        push @received, { channel => $channel, payload => $payload, pid => $pid };
    })->get;

    $pg->notify('pubsub_notify', 'test message')->get;

    ok wait_until(sub { @received == 1 }, 'notification delivery'), 'received notification';
    is $received[0]{payload}, 'test message', 'correct payload';

    $pg->pubsub->disconnect->get;
};

subtest 'multiple callbacks on one channel' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
    );
    my $pubsub = $pg->pubsub;
    my @received1;
    my @received2;

    $pubsub->listen('multi_channel', sub {
        my ($channel, $payload) = @_;
        push @received1, $payload;
    })->get;

    $pubsub->listen('multi_channel', sub {
        my ($channel, $payload) = @_;
        push @received2, $payload;
    })->get;

    is $pubsub->subscribed_channels, 1, 'one subscribed channel';

    $pubsub->notify('multi_channel', 'broadcast')->get;

    ok wait_until(sub { @received1 == 1 && @received2 == 1 }, 'broadcast delivery'),
        'both callbacks received notification';
    is $received1[0], 'broadcast', 'first callback got payload';
    is $received2[0], 'broadcast', 'second callback got payload';

    $pubsub->disconnect->get;
};

subtest 'unlisten removes a specific callback' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
    );
    my $pubsub = $pg->pubsub;
    my @kept;
    my @removed;

    my $keep_cb = sub {
        my ($channel, $payload) = @_;
        push @kept, $payload;
    };
    my $drop_cb = sub {
        my ($channel, $payload) = @_;
        push @removed, $payload;
    };

    $pubsub->listen('unsub_test', $keep_cb)->get;
    $pubsub->listen('unsub_test', $drop_cb)->get;

    $pubsub->unlisten('unsub_test', $drop_cb)->get;

    $pubsub->notify('unsub_test', 'remaining')->get;

    ok wait_until(sub { @kept == 1 }, 'remaining callback delivery'), 'kept callback received';
    is \@removed, [], 'removed callback not invoked';
    is $pubsub->subscribed_channels, 1, 'channel still subscribed';

    $pubsub->unlisten('unsub_test', $keep_cb)->get;
    is $pubsub->subscribed_channels, 0, 'channel removed after last callback';

    $pubsub->disconnect->get;
};

subtest 'unlisten all clears all subscriptions' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('channel1', sub {})->get;
    $pubsub->listen('channel2', sub {})->get;
    $pubsub->listen('channel3', sub {})->get;

    is $pubsub->subscribed_channels, 3, 'three channels subscribed';

    $pg->unlisten_all->get;
    is $pubsub->subscribed_channels, 0, 'all subscriptions removed';

    $pubsub->disconnect->get;
};

subtest 'invalid channel name' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 5,
    );

    my $err;
    eval { $pg->listen('bad;channel', sub {})->get };
    $err = $@;

    like $err, qr/Invalid channel name/, 'error for invalid channel';

    $pg->pubsub->disconnect->get;
};

done_testing;

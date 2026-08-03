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

    # No-op: the pub/sub object's DESTROY releases the listener connection
    # when it goes out of scope, and this double stands in for that
    # connection, so it needs a release to answer to as well.
    sub release { }

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

subtest 'backoff ceiling doubles and then holds' => sub {
    my @ceilings = map {
        Async::DBD::Pg::PubSub::_backoff_ceiling($_, 0.5, 30)
    } 1 .. 8;

    is \@ceilings, [ 0.5, 1, 2, 4, 8, 16, 30, 30 ],
        'doubles from the minimum and stops at the maximum';

    is Async::DBD::Pg::PubSub::_backoff_ceiling(1, 2, 10), 2,
        'first attempt waits the minimum';
    is Async::DBD::Pg::PubSub::_backoff_ceiling(99, 0.5, 30), 30,
        'never exceeds the maximum';
};

subtest 'backoff delay is jittered within its ceiling' => sub {
    # Equal jitter: half the ceiling, plus a random half. Decorrelates many
    # listeners reconnecting at once while keeping a predictable floor.
    for my $attempt (1 .. 6) {
        my $ceiling = Async::DBD::Pg::PubSub::_backoff_ceiling($attempt, 0.5, 30);
        my @delays;

        for (1 .. 25) {
            my $delay = Async::DBD::Pg::PubSub::_backoff_delay($attempt, 0.5, 30);
            ok $delay >= $ceiling / 2, "attempt $attempt delay at or above half the ceiling";
            ok $delay <= $ceiling,     "attempt $attempt delay at or below the ceiling";
            push @delays, $delay;
        }

        # Verify jitter actually varies. If delays were constant (e.g., all
        # returned $ceiling), all values would be identical. With 25 draws from
        # a continuous distribution, the chance of all values coinciding is
        # negligible, but sufficient for the implementation to be tested.
        my $first = $delays[0];
        my $has_variance = grep { $_ != $first } @delays;
        ok $has_variance, "attempt $attempt has variance in delay (not constant)";
    }
};

subtest '_AwaiterGuard checks identity before touching a different attempt' => sub {
    my $pubsub = Async::DBD::Pg::PubSub->new();

    my $attempt_a = Future->new;
    my $attempt_b = Future->new;

    # Attempt A in flight, one guard holding it -- the same pattern
    # connect() uses: set the slot, then construct the guard.
    $pubsub->{_connecting}         = $attempt_a;
    $pubsub->{_connecting_waiters} = 0;
    my $guard = Async::DBD::Pg::PubSub::_AwaiterGuard->new($pubsub, $attempt_a);

    # Simulate A being cleared and a later connect() starting attempt B,
    # with a real waiter of its own -- the ordering the identity check
    # exists to defend even though nothing in today's call patterns can
    # currently produce it (see task-2-review.md). A's guard, above, has
    # not been destroyed yet.
    $pubsub->{_connecting}         = $attempt_b;
    $pubsub->{_connecting_waiters} = 1;

    # A's guard is destroyed now, belatedly, after B has already taken
    # over the slot.
    undef $guard;

    ok defined $pubsub->{_connecting}, 'the current attempt was not deleted';
    is refaddr($pubsub->{_connecting}), refaddr($attempt_b),
        'the current attempt is still attempt B, untouched';
    is $pubsub->{_connecting_waiters}, 1,
        "attempt B's own waiter count is untouched";
    ok !$attempt_b->is_cancelled, 'attempt B was not cancelled';
};

subtest 'reconnect settings are taken from the pool' => sub {
    my $off = Async::DBD::Pg->new(
        dsn             => 'postgresql://user:secret@localhost/test',
        min_connections => 0,
        max_connections => 1,
    )->pubsub;

    is $off->{reconnect}, 0, 'reconnect is off unless asked for';
    is $off->{reconnect_min_interval}, 0.5, 'default minimum interval';
    is $off->{reconnect_max_interval}, 30, 'default maximum interval';
    is $off->{on_reconnect}, undef, 'no reconnect callback by default';

    my $cb = sub { };
    my $on = Async::DBD::Pg->new(
        dsn                    => 'postgresql://user:secret@localhost/test',
        min_connections        => 0,
        max_connections        => 1,
        reconnect              => 1,
        reconnect_min_interval => 2,
        reconnect_max_interval => 60,
        on_reconnect           => $cb,
    )->pubsub;

    is $on->{reconnect}, 1, 'reconnect enabled';
    is $on->{reconnect_min_interval}, 2, 'minimum interval carried across';
    is $on->{reconnect_max_interval}, 60, 'maximum interval carried across';
    is $on->{on_reconnect}, $cb, 'callback carried across';
};

done_testing;

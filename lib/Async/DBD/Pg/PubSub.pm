package Async::DBD::Pg::PubSub;

use strict;
use warnings;

use Future::AsyncAwait;
use Future::IO qw(POLLIN);
use Scalar::Util qw(refaddr weaken);

sub new {
    my ($class, %args) = @_;

    my $pool = $args{pool};

    my $self = bless {
        pool             => $pool,
        conn             => undef,
        channels         => {},
        connected        => 0,
        _listener_future => undef,
        _stopping        => 0,

        # Read from the pool, which is where an application sets them.
        reconnect              => $pool ? $pool->{reconnect}              : 0,
        reconnect_min_interval => $pool ? $pool->{reconnect_min_interval} : 0.5,
        reconnect_max_interval => $pool ? $pool->{reconnect_max_interval} : 30,
        on_reconnect           => $pool ? $pool->{on_reconnect}           : undef,

        _reconnect_future => undef,
    }, $class;

    weaken($self->{pool}) if $self->{pool};

    return $self;
}

sub pool                { shift->{pool} }
sub conn                { shift->{conn} }
sub is_connected        { shift->{connected} }
sub subscribed_channels { scalar keys %{shift->{channels}} }

sub _validate_channel {
    my ($self, $channel) = @_;

    return 0 unless defined $channel && length $channel;
    return 0 if $channel =~ /[\s;'"\\]/;
    return 0 if $channel =~ /[\x00-\x1f]/;
    return 1;
}

sub _log {
    my ($self, $level, $message) = @_;

    if (my $pool = $self->{pool}) {
        $pool->_log($level, $message);
        return;
    }

    warn "Async::DBD::Pg::PubSub [$level]: $message\n";
}

# How long to wait before reconnect attempt $attempt, counting from 1. The
# ceiling doubles from the minimum until it reaches the maximum and stays
# there.
sub _backoff_ceiling {
    my ($attempt, $min, $max) = @_;

    my $ceiling = $min * (2 ** ($attempt - 1));

    return $ceiling > $max ? $max : $ceiling;
}

# Equal jitter: half the ceiling plus a random half. Keeps a predictable floor
# while spreading out many listeners reconnecting to the same server, so one
# coming back does not receive every reconnect at the same instant.
sub _backoff_delay {
    my ($attempt, $min, $max) = @_;

    my $ceiling = _backoff_ceiling($attempt, $min, $max);

    return ($ceiling / 2) + rand($ceiling / 2);
}

async sub connect {
    my ($self) = @_;

    return $self if $self->{connected} && $self->{conn} && $self->{conn}->dbh;

    # One attempt, shared by everyone who needs a connection -- explicit
    # callers and the reconnect supervisor alike. Callers arriving together
    # would otherwise each check one out and all but the last would be dropped
    # without ever being released.
    #
    # Reading this slot and assigning it are not separated by an await: calling
    # an async sub returns a future without suspending us, so no second caller
    # can slip in between. That is what makes this the only place in the class
    # allowed to decide a new connection is needed.
    my $attempt = $self->{_connecting};

    unless ($attempt) {
        my $pool = $self->{pool} or die "No pool configured";

        $attempt = $self->_establish($pool);
        $self->{_connecting}         = $attempt;
        $self->{_connecting_waiters} = 0;

        # Clear the shared attempt however it ends. Doing it after the await
        # would be skipped when a caller gives up, because cancelling tears
        # this sub down where it is suspended, and every later connect would
        # then wait on an attempt that had already been cancelled.
        my $pubsub = $self;
        weaken($pubsub);

        $attempt->on_ready(sub {
            my $live = $pubsub or return;
            delete $live->{_connecting};
            delete $live->{_connecting_waiters};
        });
    }

    # Held for the duration of the await. See _AwaiterGuard: the view keeps one
    # caller's cancellation from failing the others, and the guard makes sure
    # the attempt is still cancelled once the last caller has gone.
    my $guard = Async::DBD::Pg::PubSub::_AwaiterGuard->new($self, $attempt);

    # Teardown is the only thing that can cancel the shared attempt now, and a
    # cancelled future reaches its awaiters as "Future=HASH(0x...) was
    # cancelled" -- an address and no explanation. Callers get told what
    # actually happened to them.
    my $connected = eval { await $attempt->without_cancel; 1 };

    unless ($connected) {
        my $err = $@;
        die $err unless $attempt->is_cancelled;
        die "PubSub connect was cancelled\n";
    }

    return $self;
}

async sub _establish {
    my ($self, $pool) = @_;

    $self->{conn} = await $pool->connection;
    $self->{connected} = 1;
    $self->{_stopping} = 0;

    await $self->_start_listener;

    return $self;
}

async sub listen {
    my ($self, $channel, $callback) = @_;

    die "Invalid channel name: $channel"
        unless $self->_validate_channel($channel);
    die "listen requires a callback"
        unless ref $callback eq 'CODE';

    await $self->connect unless $self->{connected};

    my $callbacks = $self->{channels}{$channel} ||= [];
    my $first_subscription = !@$callbacks;

    push @$callbacks, $callback;

    if ($first_subscription) {
        await $self->_run_control_query("LISTEN $channel");
    }

    return $self;
}

async sub unlisten {
    my ($self, $channel, $callback) = @_;

    return $self unless exists $self->{channels}{$channel};

    if ($callback) {
        my $target = refaddr($callback);
        @{$self->{channels}{$channel}} = grep {
            refaddr($_) != $target
        } @{$self->{channels}{$channel}};
    }
    else {
        $self->{channels}{$channel} = [];
    }

    if (!@{$self->{channels}{$channel}}) {
        delete $self->{channels}{$channel};
        if ($self->{conn}) {
            await $self->_run_control_query("UNLISTEN $channel");
        }
    }

    return $self;
}

async sub unlisten_all {
    my ($self) = @_;

    $self->{channels} = {};

    if ($self->{conn}) {
        await $self->_run_control_query('UNLISTEN *');
    }

    return $self;
}

async sub notify {
    my ($self, $channel, $payload) = @_;

    die "Invalid channel name: $channel"
        unless $self->_validate_channel($channel);

    my $pool = $self->{pool} or die "No pool configured";
    my $conn = await $pool->connection;

    my $result = eval {
        await $conn->query('SELECT pg_notify($1, $2)', $channel, $payload);
    };
    my $err = $@;

    $conn->release;

    die $err if $err;
    return $result;
}

# The connection is passed in rather than read from $self. The listener loop
# polls one specific socket for its whole life, so it must read notifications
# from that same connection: if {conn} is replaced underneath it, re-reading
# here would poll one connection and ask a different one what arrived, and the
# notification would be dropped with no error and no log line.
sub _process_notifications {
    my ($self, $conn) = @_;

    $conn or return 0;
    my $dbh = $conn->dbh or return 0;

    my $count = 0;

    # pg_notifies is the one synchronous call on this connection that reads
    # the socket outside _execute_async, and it can surface a server message
    # the same way execute/pg_ready/pg_result can -- wrapped here for the
    # same reason. Only the call is wrapped, not the loop body: the body runs
    # user callbacks below, which must reach the user's own $SIG{__WARN__} if
    # they warn, not have a warning of theirs relabelled as a server notice.
    # $conn always has a pool here (it comes from $pool->connection in
    # _establish), and nothing in this loop awaits, so the plain, synchronous
    # form of _capture_pg_notices applies with no changes.
    while (my $notification = $conn->_capture_pg_notices(sub { $dbh->pg_notifies })) {
        my ($channel, $pid, $payload) = @$notification;
        my $callbacks = $self->{channels}{$channel} || [];

        for my $cb (@$callbacks) {
            eval { $cb->($channel, $payload, $pid) };
            next unless $@;
            $self->_log(warn => "PubSub callback error for $channel: $@");
        }

        $count++;
    }

    return $count;
}

async sub _listener_loop {
    my ($self) = @_;

    my $conn = $self->{conn} or return;
    my $sock = $conn->_get_socket;

    while (!$self->{_stopping}) {
        await Future::IO->poll($sock, POLLIN);
        last if $self->{_stopping};
        $self->_process_notifications($conn);
    }

    return;
}

async sub _start_listener {
    my ($self) = @_;

    return $self unless $self->{connected} && $self->{conn};
    return $self if $self->{_listener_future} && !$self->{_listener_future}->is_ready;

    my $listener = $self->_listener_loop;
    my $weak_self = $self;
    weaken($weak_self);

    $listener->on_fail(sub {
        my ($err) = @_;
        my $self = $weak_self or return;
        return if $self->{_stopping};

        $self->_log(warn => "PubSub listener stopped: $err");

        # The connection is gone. Say so rather than continuing to report a
        # connection that cannot deliver anything, and hand it back so the
        # pool discards it instead of holding it checked out to nobody.
        $self->{connected} = 0;
        if (my $conn = delete $self->{conn}) {
            $conn->release;
        }

        return unless $self->{reconnect};
        return if $self->{_reconnect_future};

        # Held on the object rather than retained, so disconnect and pool
        # shutdown can stop it.
        my $reconnecting = $self->_reconnect_loop;
        $self->{_reconnect_future} = $reconnecting;

        # Cleared here, once, on however this ends -- success, failure or
        # cancellation -- rather than at each exit inside the loop. An
        # exception the loop doesn't catch would otherwise leave a ready,
        # failed future sitting in this slot, and "return if
        # $self->{_reconnect_future}" above would then refuse to start a new
        # supervisor for every listener death after it. Same pattern connect
        # uses for _connecting.
        my $weak = $self;
        weaken($weak);
        $reconnecting->on_ready(sub {
            my $live = $weak or return;
            delete $live->{_reconnect_future};
        });
    });

    $self->{_listener_future} = $listener;

    return $self;
}

# Re-establish a listener that failed, replaying its subscriptions. Runs until
# it succeeds, or until something cancels it.
async sub _reconnect_loop {
    my ($self) = @_;

    my $attempt = 0;

    while (!$self->{_stopping}) {
        $attempt++;

        my $delay = _backoff_delay(
            $attempt,
            $self->{reconnect_min_interval},
            $self->{reconnect_max_interval},
        );

        await Future::IO->sleep($delay);

        last if $self->{_stopping};

        my $ok = eval {
            unless ($self->{connected} && $self->{conn}) {
                my $pool = $self->{pool}
                    or die "pool is gone\n";

                $self->{conn}      = await $pool->connection;
                $self->{connected} = 1;
            }

            # An ordinary connect/listen call may already have re-established
            # the connection while this loop was backing off -- the branch
            # above finds it and skips taking a second one of our own, which
            # would otherwise leave the winner's connection checked out to
            # nobody. Either way, replay every registered channel: that path
            # only replays the channel it was called for, so anything
            # subscribed before it would stay silently orphaned without this.
            #
            # Issued through _run_control_query, the same idiom listen() and
            # unlisten() use, rather than querying the connection directly:
            # a listener may already be running here (the race case above),
            # and its guard stops and restarts the listener safely around
            # each query, including under cancellation. Whatever this loop
            # hits along the way -- acquiring, replaying, starting the
            # listener -- funnels into the one failure handling below, so a
            # connection dying again mid-replay is retried like any other
            # failed attempt instead of escaping uncaught and leaving nothing
            # running to notice.
            for my $channel (sort keys %{ $self->{channels} }) {
                await $self->_run_control_query("LISTEN $channel");
            }

            await $self->_start_listener;
            1;
        };
        my $err = $@;

        if ($ok) {
            # Success is reported through on_reconnect, not through _log. With
            # no on_log configured _log falls back to warn, and a recovery that
            # worked should not print to STDERR.
            if (my $cb = $self->{on_reconnect}) {
                eval { $cb->($self) };
                $self->_log(warn => "on_reconnect callback failed: $@") if $@;
            }

            return $self;
        }

        # Hand back anything acquired before the failure, so a half-built
        # attempt does not keep a connection checked out.
        $self->{connected} = 0;
        if (my $conn = delete $self->{conn}) {
            $conn->release;
        }

        # A pool that has shut down is never going to give us a connection.
        # Checked on the pool's own state rather than matched against $err's
        # text, because PostgreSQL raises its own "the database system is
        # shutting down" on a restart, which a message match would also
        # catch and give up on permanently for a condition that will clear
        # on its own. Shutdown fails a queued waiter before it cancels this
        # loop, so a supervisor suspended in the connection request above
        # really does learn about it by exception, not by cancellation.
        if ($self->{pool} && $self->{pool}{_shutting_down}) {
            $self->_log(warn => "PubSub giving up on reconnect: $err");
            return $self;
        }

        $self->_log(warn => "PubSub reconnect attempt $attempt failed: $err");
    }

    return $self;
}

async sub _stop_listener {
    my ($self) = @_;

    my $listener = delete $self->{_listener_future} or return;

    $self->{_stopping} = 1;
    $listener->cancel unless $listener->is_ready;

    eval { await $listener };

    return;
}

async sub _run_control_query {
    my ($self, $sql, @bind) = @_;

    await $self->_stop_listener if $self->{_listener_future};

    # Stopping the listener set _stopping, and the listener loop refuses to
    # run while it is set. A guard puts it back and restarts the listener
    # however this ends: on success, on a failed statement, and on a caller
    # cancelling while the statement is in flight, which stops this sub
    # where it stands and runs nothing after the await.
    my $listener = Async::DBD::Pg::PubSub::_ListenerGuard->new($self);

    my $result = eval { await $self->{conn}->query($sql, @bind) };
    my $err = $@;

    $listener->restore;

    die $err if $err;

    return $result;
}

async sub disconnect {
    my ($self) = @_;

    # Stop trying to come back before tearing down; otherwise a reconnect in
    # flight would re-establish the listener behind us.
    $self->{_stopping} = 1;
    if (my $reconnecting = delete $self->{_reconnect_future}) {
        $reconnecting->cancel unless $reconnecting->is_ready;
    }

    # A connect still in flight would otherwise finish after we return and
    # leave a connection checked out to an object that has been torn down.
    # Awaiters cannot cancel it -- see _AwaiterGuard -- so teardown must.
    if (my $connecting = delete $self->{_connecting}) {
        $connecting->cancel unless $connecting->is_ready;
    }

    unless ($self->{connected} || $self->{conn}) {
        $self->{channels}  = {};
        $self->{_stopping} = 0;
        return $self;
    }

    await $self->_stop_listener if $self->{_listener_future};

    if (my $conn = delete $self->{conn}) {
        eval { await $conn->query('UNLISTEN *') };
        $conn->release;
    }

    $self->{channels} = {};
    $self->{connected} = 0;
    $self->{_stopping} = 0;

    return $self;
}

sub _pool_shutdown {
    my ($self) = @_;

    $self->{_stopping} = 1;

    if (my $reconnecting = delete $self->{_reconnect_future}) {
        $reconnecting->cancel unless $reconnecting->is_ready;
    }

    if (my $connecting = delete $self->{_connecting}) {
        $connecting->cancel unless $connecting->is_ready;
    }

    if (my $listener = delete $self->{_listener_future}) {
        $listener->cancel unless $listener->is_ready;
    }

    # Hand the connection back rather than just forgetting it. The pool holds
    # its own reference in the active list, so dropping this one leaves the
    # connection checked out to nobody and a drain waiting for it forever.
    if (my $conn = delete $self->{conn}) {
        $conn->release;
    }

    $self->{channels} = {};
    $self->{connected} = 0;
}

sub DESTROY {
    my ($self) = @_;

    return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
    $self->_pool_shutdown;
}

package Async::DBD::Pg::PubSub::_ListenerGuard;

# Clears the stopping flag and starts the listener again. Restoring from a
# destructor as well as explicitly covers a caller cancelling the control
# query, which would otherwise leave the flag set and the listener stopped,
# so notifications would stop arriving with nothing to say why.

use strict;
use warnings;
use Scalar::Util qw(weaken);

sub new {
    my ($class, $pubsub) = @_;

    my $self = bless { pubsub => $pubsub }, $class;
    weaken($self->{pubsub});

    return $self;
}

sub restore {
    my ($self) = @_;

    my $pubsub = delete $self->{pubsub} or return;

    $pubsub->{_stopping} = 0;
    return unless $pubsub->{connected};

    # Starting the listener only builds the loop's future and stores it on
    # the object; it awaits nothing itself, so it completes at once and is
    # safe to call from a destructor. The loop it starts is held as
    # _listener_future, so there is nothing here to retain, only a failure
    # worth reporting rather than dropping.
    my $started = $pubsub->_start_listener;

    $started->on_fail(sub {
        my ($err) = @_;
        $pubsub->_log(warn => "Could not restart listener: $err");
    });
}

sub DESTROY { shift->restore }

# Counts the callers waiting on one shared connect attempt. Every awaiter holds
# one of these, including the caller that started the attempt.
#
# A caller that gives up must not cancel the attempt out from under the others,
# so awaiters wait on a without_cancel view instead of the attempt itself. That
# alone would leave an attempt running for callers who have all gone away, and
# a connection checked out to nobody -- so the last guard to go cancels it.
#
# The count is dropped in a destructor rather than after the await: a cancelled
# sub never resumes, so anything written after the await would be skipped in
# exactly the case this exists for.
#
# Each guard remembers its own attempt and checks it against {_connecting}
# before touching either key. {_connecting} normally names the one attempt
# every live guard was built for, but nothing enforces that this guard's
# attempt is still the current one -- if it were destroyed after a second
# attempt had already taken the slot, it would otherwise decrement and
# possibly cancel a stranger's attempt using its own guard's leftover count.
package Async::DBD::Pg::PubSub::_AwaiterGuard;

use strict;
use warnings;
use Scalar::Util qw(refaddr weaken);

sub new {
    my ($class, $pubsub, $attempt) = @_;

    $pubsub->{_connecting_waiters}++;

    my $self = bless { pubsub => $pubsub, attempt => $attempt }, $class;
    weaken($self->{pubsub});

    return $self;
}

sub DESTROY {
    my ($self) = @_;

    my $pubsub = $self->{pubsub} or return;
    return unless $pubsub->{_connecting};
    return unless refaddr($pubsub->{_connecting}) == refaddr($self->{attempt});
    return if --$pubsub->{_connecting_waiters} > 0;

    my $attempt = delete $pubsub->{_connecting};
    delete $pubsub->{_connecting_waiters};
    $attempt->cancel unless $attempt->is_ready;
}

package Async::DBD::Pg::PubSub;

1;

__END__

=head1 NAME

Async::DBD::Pg::PubSub - LISTEN/NOTIFY support for Async::DBD::Pg

=head1 SYNOPSIS

    my $pubsub = $pg->pubsub;

    await $pubsub->listen(my_channel => sub {
        my ($channel, $payload, $pid) = @_;
        ...
    });

    await $pubsub->notify(my_channel => 'hello');
    await $pubsub->disconnect;

=head1 DESCRIPTION

This module provides loop-agnostic PostgreSQL pub/sub support built on top of
L<DBD::Pg>'s C<LISTEN>, C<UNLISTEN>, and C<pg_notifies> support, with socket
readiness handled through L<Future::IO>.

Listening occupies one connection from the pool for as long as any channel is
subscribed, because a session that is listening cannot be handed to anyone
else. Size the pool with that in mind. L</notify> does not need the listener
and takes a connection only for as long as the statement runs.

Channel names are validated as plain identifiers. They cannot be bound as
parameters, so anything else is refused rather than quoted.

=head1 METHODS

=head2 listen

    await $pubsub->listen($channel, sub {
        my ($channel, $payload, $pid) = @_;
        ...
    });

Registers a callback for notifications on C<$channel>, connecting the listener
if this is the first subscription. C<LISTEN> is only issued the first time a
channel is subscribed, so registering several callbacks for one channel costs
one round trip; each is called in turn for every notification.

The callback receives the channel name, the payload sent with the
notification, and the process id of the backend that sent it. A payload is an
empty string when the sender supplied none.

Dies if the channel name is not a plain identifier, or if no callback is
given.

=head2 unlisten

    await $pubsub->unlisten($channel);
    await $pubsub->unlisten($channel, $callback);

Removes one callback, or every callback for the channel when none is given.
C<UNLISTEN> is only issued once the last callback for that channel has gone.
Unsubscribing from a channel with no subscriptions does nothing.

=head2 unlisten_all

    await $pubsub->unlisten_all;

Drops every subscription and issues C<UNLISTEN *>. The listener connection is
kept; use L</disconnect> to give it back.

=head2 notify

    await $pubsub->notify($channel, $payload);

Sends a notification with C<pg_notify>. This borrows a connection from the
pool for the statement and releases it again, so it neither needs nor disturbs
the listener, and can be used from a pub/sub object that is not listening to
anything.

Notifications are delivered when the sending transaction commits. Sent inside
a transaction that later rolls back, they are never delivered.

Dies if the channel name is not a plain identifier.

=head2 connect

    await $pubsub->connect;

Checks out the listener connection and starts the listener. Called for you by
L</listen>; useful when you want to establish the connection ahead of the
first subscription. Callers arriving together share one attempt, and calling
it while already connected does nothing.

=head2 disconnect

    await $pubsub->disconnect;

Issues C<UNLISTEN *>, forgets every subscription and returns the listener
connection to the pool.

=head2 is_connected

True while the listener connection is held.

=head2 subscribed_channels

Number of channels with at least one callback registered.

=head2 pool

The pool this object belongs to.

=head2 conn

The connection the listener is using, or C<undef> when it is not connected.

=cut

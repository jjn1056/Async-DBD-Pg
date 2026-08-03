package Async::DBD::Pg::PubSub;

use strict;
use warnings;

use Future::AsyncAwait;
use Future::IO qw(POLLIN);
use Scalar::Util qw(refaddr weaken);

use Async::DBD::Pg::Error;
use Async::DBD::Pg::Util qw(pending_future);

sub new {
    my ($class, %args) = @_;

    my $pool = $args{pool};

    my $self = bless {
        pool             => $pool,
        conn             => undef,
        channels         => {},
        phase            => 'disconnected',
        _listener_future => undef,

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
sub is_connected        { shift->{phase} eq 'live' }
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

    return $self if $self->{phase} eq 'live' && $self->{conn} && $self->{conn}->dbh;

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
    $self->{phase} = 'live';

    await $self->_start_listener;

    return $self;
}

async sub listen {
    my ($self, $channel, $callback) = @_;

    die "Invalid channel name: $channel"
        unless $self->_validate_channel($channel);
    die "listen requires a callback"
        unless ref $callback eq 'CODE';

    await $self->connect unless $self->{phase} eq 'live';

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

    # Pause exactly while something holds this connection. Reading the slot
    # rather than a flag someone sets means there is nothing to leave behind:
    # a paused listener resumes because the holder released, not because a
    # second code path remembered to clear a boolean.
    while ($self->{phase} eq 'live' && !$self->{_control_query}) {
        await Future::IO->poll($sock, POLLIN);
        last unless $self->{phase} eq 'live' && !$self->{_control_query};
        $self->_process_notifications($conn);
    }

    return;
}

async sub _start_listener {
    my ($self) = @_;

    return $self unless $self->{phase} eq 'live' && $self->{conn};
    return $self if $self->{_listener_future} && !$self->{_listener_future}->is_ready;

    my $listener = $self->_listener_loop;
    my $weak_self = $self;
    weaken($weak_self);

    $listener->on_fail(sub {
        my ($err) = @_;
        my $self = $weak_self or return;
        return if $self->{phase} ne 'live';

        $self->_log(warn => "PubSub listener stopped: $err");

        # The connection is gone. Say so rather than continuing to report a
        # connection that cannot deliver anything, and hand it back so the
        # pool discards it instead of holding it checked out to nobody.
        $self->{phase} = 'disconnected';
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

    while ($self->{phase} ne 'closing') {
        $attempt++;

        my $delay = _backoff_delay(
            $attempt,
            $self->{reconnect_min_interval},
            $self->{reconnect_max_interval},
        );

        await Future::IO->sleep($delay);

        last if $self->{phase} eq 'closing';

        my $ok = eval {
            # Through connect(), not a checkout of our own. An ordinary
            # listen() may be connecting right now, and deciding separately
            # whether a connection is needed is what produced two of them:
            # the check and the checkout are separate moments, and this sub
            # suspends between them, so both paths could see "not connected"
            # and act on it. connect() owns the one attempt and shares it,
            # so whichever of us asks second waits for the first instead of
            # starting another.
            await $self->connect;

            # An ordinary connect/listen call may already have re-established
            # the connection while this loop was backing off -- connect()
            # above finds that attempt and shares it rather than starting a
            # second one, so both paths end up on the same connection.
            # Either way, replay every registered channel: that path only
            # replays the channel it was called for, so anything subscribed
            # before it would stay silently orphaned without this.
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
        $self->{phase} = 'disconnected';
        if (my $conn = delete $self->{conn}) {
            $conn->release;
        }

        # A pool that has shut down is never going to give us a connection, and
        # neither is one that is gone entirely. Checked on the pool's own state
        # rather than matched against $err's text, because PostgreSQL raises
        # its own "the database system is shutting down" on a restart, which a
        # message match would also catch and give up on permanently for a
        # condition that will clear on its own. Shutdown fails a queued waiter
        # before it cancels this loop, so a supervisor suspended in the
        # connection request above really does learn about it by exception, not
        # by cancellation.
        if (!$self->{pool} || $self->{pool}{_shutting_down}) {
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

    $listener->cancel unless $listener->is_ready;

    eval { await $listener };

    return;
}

async sub _run_control_query {
    my ($self, $sql, @bind) = @_;

    # Only one control query at a time on this connection: DBD::Pg cannot run
    # two async queries on one handle, and listen() and the reconnect loop's
    # replay can both arrive here the moment a shared connect resolves. Loop
    # rather than check once -- everyone waiting on the same predecessor wakes
    # together, so a single check would let them all through behind it.
    #
    # Not Future::Mutex, which ships with the already-required Future: its
    # first entrant is built from Future->done, the same plain Future class
    # pending_future exists to avoid, so a mutex built from it would
    # reintroduce ->get croaking for a caller queued behind real async work.
    while (my $pending = $self->{_control_query}) {
        await $pending->without_cancel;
    }

    # Checked here, immediately on exiting the loop and before claiming
    # anything: cancelling the slot's current holder to tear it down (see
    # disconnect()/_pool_shutdown() below) wakes a parked waiter
    # synchronously, inside that same cancellation call -- before teardown
    # has gone on to delete {conn}. Without this check, the woken waiter
    # would find {conn} still looking valid, issue its own query on it, and
    # then have teardown release that same connection out from under it a
    # moment later -- corrupting it for whoever the pool hands it to next.
    die Async::DBD::Pg::Error::Connection->new(
        message => 'PubSub is disconnecting',
    ) if $self->{phase} eq 'closing';

    # Claimed with a fresh future rather than the query's own future: the
    # query does not exist yet, since _stop_listener below awaits before one
    # is issued. Reading the loop's exit and claiming this are not separated
    # by an await, so no second caller can slip in between.
    #
    # pending_future rather than a bare Future->new: a second caller waiting
    # on the loop above is otherwise handed back a listen()/unlisten() future
    # whose top-level ->get can never block, only croak once it isn't already
    # ready -- see Async::DBD::Pg::Util for why.
    my $done = pending_future();
    $self->{_control_query} = $done;
    my $query_guard = Async::DBD::Pg::PubSub::_ControlQueryGuard->new($self, $done);

    await $self->_stop_listener if $self->{_listener_future};

    # Held outside the eval so it can be asked about after: a cancelled
    # future reaches its awaiter as "Future=HASH(0x...) was cancelled" -- an
    # address and no explanation, same as connect() guards against for its
    # own shared attempt below.
    my $query;
    my $result = eval {
        # Re-read here rather than trusted from before the awaits above: a
        # waiter can be parked behind the mutex for its predecessor's whole
        # query, and the listener's on_fail can delete {conn} while it
        # waits. Dying with a real error here beats dereferencing undef a
        # line further down.
        my $conn = $self->{conn}
            or die Async::DBD::Pg::Error::Connection->new(
                message => 'PubSub connection is gone',
            );

        # Published where teardown can reach it: disconnect() and
        # _pool_shutdown cancel this before releasing {conn}, the same way
        # they already cancel {_connecting} and {_reconnect_future}.
        # Cancelling propagates through query()'s own await into
        # _execute_async's frame, running _StatementGuard::DESTROY there --
        # server-side cancel and a finished handle -- before the connection
        # goes back to the pool. Without this, teardown has no way to know a
        # query is even in flight: the slot above is never released, and
        # every later control query parks in the while loop forever.
        $query = $conn->query($sql, @bind);
        $self->{_control_query_inflight} = $query;
        await $query;
    };
    my $err = $@;

    $query_guard->release;

    # $query->is_cancelled here can only mean teardown cancelled it: a
    # caller giving up on its own listen()/unlisten() tears this frame down
    # at whatever await it is suspended on rather than letting it resume,
    # so a caller-cancelled query never reaches this line at all.
    die Async::DBD::Pg::Error::Connection->new(
        message => 'PubSub is disconnecting',
    ) if $err && $query && $query->is_cancelled;
    die $err if $err;

    return $result;
}

async sub disconnect {
    my ($self) = @_;

    # Stop trying to come back before tearing down; otherwise a reconnect in
    # flight would re-establish the listener behind us. Set before the
    # cancellations below rather than after: _run_control_query checks this
    # before ever claiming the slot, and a query cancelled a few lines down
    # can wake a waiter synchronously, inside that same cancellation call.
    $self->{phase} = 'closing';

    if (my $reconnecting = delete $self->{_reconnect_future}) {
        $reconnecting->cancel unless $reconnecting->is_ready;
    }

    # A connect still in flight would otherwise finish after we return and
    # leave a connection checked out to an object that has been torn down.
    # Awaiters cannot cancel it -- see _AwaiterGuard -- so teardown must.
    if (my $connecting = delete $self->{_connecting}) {
        $connecting->cancel unless $connecting->is_ready;
    }

    # A control query in flight holds {_control_query} until its guard
    # releases, and nothing but the query's own completion or cancellation
    # ends that frame. Left running, we release {conn} below with a query
    # still in progress on it, and the slot stays claimed forever -- every
    # later control query parks in _run_control_query's while loop with
    # nothing left to wake it. Cancelling here runs _StatementGuard::DESTROY
    # (Connection.pm), which cancels server-side and finishes the handle
    # before {conn} is touched. Done before the _stop_listener call below
    # rather than after, so that call catches and re-stops a listener the
    # cancelled query's own guard may have just restarted.
    if (my $query = delete $self->{_control_query_inflight}) {
        $query->cancel unless $query->is_ready;
    }

    unless ($self->{phase} eq 'live' || $self->{conn}) {
        $self->{channels} = {};
        $self->{phase}    = 'disconnected';
        return $self;
    }

    await $self->_stop_listener if $self->{_listener_future};

    if (my $conn = delete $self->{conn}) {
        eval { await $conn->query('UNLISTEN *') };
        $conn->release;
    }

    $self->{channels} = {};
    $self->{phase}    = 'disconnected';

    return $self;
}

sub _pool_shutdown {
    my ($self) = @_;

    # Left at 'closing' rather than reset to 'disconnected' afterward. The
    # difference is unreachable through the public API -- every route to a
    # control query goes through listen()/unlisten(), and both gate on
    # {phase} eq 'live' before ever dispatching one, so a fresh call is
    # turned away earlier still, by the pool's own shut-down guard in
    # connection() -- which is why the test that pins this reaches into
    # _run_control_query directly rather than through listen(). 'closing' is
    # chosen because it is the honest answer -- unlike disconnect(), a
    # pool-shut-down pubsub is not going to reconnect, and 'disconnected'
    # would claim otherwise.
    $self->{phase} = 'closing';

    if (my $reconnecting = delete $self->{_reconnect_future}) {
        $reconnecting->cancel unless $reconnecting->is_ready;
    }

    if (my $connecting = delete $self->{_connecting}) {
        $connecting->cancel unless $connecting->is_ready;
    }

    # See the matching block in disconnect() for why this exists and why it
    # runs before the {_listener_future} cancellation below rather than
    # after: cancelling an in-flight control query can synchronously restart
    # the listener through its own guard, and the block below is what
    # catches and cancels that.
    if (my $query = delete $self->{_control_query_inflight}) {
        $query->cancel unless $query->is_ready;
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
}

sub DESTROY {
    my ($self) = @_;

    return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
    $self->_pool_shutdown;
}

# Releases the one-at-a-time slot _run_control_query claims on {_control_query}
# and restarts the listener, in that order: the listener's own run condition
# reads that slot, so restarting it first would start a loop that exits on
# its first check with nothing left to restart it. Released from a destructor
# as well as explicitly, so a caller cancelling mid-query still frees the slot
# and restarts the listener instead of leaving both stuck.
package Async::DBD::Pg::PubSub::_ControlQueryGuard;

use strict;
use warnings;
use Scalar::Util qw(refaddr weaken);

sub new {
    my ($class, $pubsub, $done) = @_;

    my $self = bless { pubsub => $pubsub, done => $done }, $class;
    weaken($self->{pubsub});

    return $self;
}

sub release {
    my ($self) = @_;

    my $done   = delete $self->{done} or return;
    my $pubsub = delete $self->{pubsub};

    # Slot first, listener second. The listener's own run condition reads
    # this slot, so restarting it while the slot is still claimed would start
    # a loop that exits on its first check with nothing left to restart it.
    if ($pubsub && $pubsub->{_control_query}
        && refaddr($pubsub->{_control_query}) == refaddr($done)) {
        delete $pubsub->{_control_query};
    }
    delete $pubsub->{_control_query_inflight} if $pubsub;
    $done->done unless $done->is_ready;

    # $done->done above can, in the same call, run a second control query
    # queued behind this one all the way through reclaiming {_control_query}
    # and sending its own statement on this connection -- a waiter parked in
    # _run_control_query's mutex loop resumes synchronously once the future
    # it is awaiting completes. A non-empty slot here means somebody else is
    # mid-query, so restarting the listener now would poll the same socket
    # that query is still awaiting a result on. Deferred instead: that
    # query's own release() re-checks the same way, and restarts it once it
    # is genuinely the last one out.
    #
    # {phase} eq 'live' also gates a teardown in progress: disconnect() and
    # _pool_shutdown() set {phase} to 'closing' before cancelling an
    # in-flight control query, and that cancellation is what runs this
    # release() -- so a query cancelled by teardown reaches this line with
    # {phase} already 'closing', and this guard will not restart the
    # listener for it. See disconnect()'s second _stop_listener call for the
    # older, coarser safeguard that used to be needed here.
    return unless $pubsub && $pubsub->{phase} eq 'live' && !$pubsub->{_control_query};

    my $started = $pubsub->_start_listener;
    $started->on_fail(sub {
        my ($err) = @_;
        $pubsub->_log(warn => "Could not restart listener: $err");
    });
}

sub DESTROY { shift->release }

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

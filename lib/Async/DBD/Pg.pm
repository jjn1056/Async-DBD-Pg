package Async::DBD::Pg;

use strict;
use warnings;

use Future;
use Future::AsyncAwait;
use Future::IO qw(POLLIN POLLOUT);
use DBI;
use DBD::Pg;

use Async::DBD::Pg::Connection;
use Async::DBD::Pg::Error;
use Async::DBD::Pg::PubSub;
use Async::DBD::Pg::Util qw(parse_dsn pending_future);
use IO::Socket;
use POSIX qw(dup);
use Scalar::Util qw(refaddr weaken);

# $VERSION is stamped into each package at build time by Dist::Zilla, so it
# is absent when running straight from a git checkout.

sub new {
    my ($class, %args) = @_;

    # Required
    my $dsn = delete $args{dsn}
        or die "dsn is required";

    my $self = bless {
        dsn              => $dsn,
        min_connections  => delete $args{min_connections} // 1,
        max_connections  => delete $args{max_connections} // 10,
        idle_timeout     => delete $args{idle_timeout}    // 300,
        queue_timeout    => delete $args{queue_timeout}   // 30,
        connect_timeout  => delete $args{connect_timeout} // 30,
        statement_timeout => delete $args{statement_timeout},
        max_queries      => delete $args{max_queries},

        # Per-connection prepared-statement cache. Off by default: it holds
        # server-side statements open, and behind a transaction-pooling
        # pgbouncer it is actively slower than not caching.
        statement_cache_size => delete $args{statement_cache_size} // 0,

        # Callbacks
        on_connect => delete $args{on_connect},
        on_release => delete $args{on_release},
        on_log     => delete $args{on_log},
        on_query   => delete $args{on_query},

        # Pub/sub reconnect. Set on the pool because that is what an
        # application constructs; pubsub takes no arguments.
        reconnect              => delete $args{reconnect}              // 0,
        reconnect_min_interval => delete $args{reconnect_min_interval} // 0.5,
        reconnect_max_interval => delete $args{reconnect_max_interval} // 30,
        on_reconnect           => delete $args{on_reconnect},

        # A connection that died while idle is replaced and the caller's
        # statement run again, rather than the caller being handed a failure
        # the pool caused.
        heal_dead_connections => delete $args{heal_dead_connections} // 1,

        # Pool state
        idle    => [],
        active  => [],
        waiting => [],

        # Connections whose handshake is in progress. They are in neither the
        # idle nor the active list yet, so without counting them separately
        # concurrent callers all see room and all create one.
        _connecting => 0,

        # Monotonic, never reused. A refaddr would be: Perl reuses an address
        # after collection, so two connections could report the same one over
        # a pool's life and any attribution built on it would merge them.
        _next_connection_id => 1,
        pid     => $$,

        # Stats
        stats => {
            created          => 0,
            released         => 0,
            discarded        => 0,
            connect_failures => 0,
            timeouts         => 0,
        },

        # Parsed DSN
        _parsed_dsn => parse_dsn($dsn),
    }, $class;

    # Ensure minimum connections (fire and forget)
    $self->_ensure_min_connections;

    return $self;
}

# Accessors
sub min_connections { shift->{min_connections} }
sub max_connections { shift->{max_connections} }
sub idle_count      { scalar @{shift->{idle}} }
sub active_count    { scalar @{shift->{active}} }
# Counts callers still genuinely waiting, not entries still in the array. A
# caller that cancelled -- its own deadline, an enclosing wait_any, a request
# handler going away -- leaves a settled future behind until the queue_timeout
# timer or the next release sweeps it, and reporting those as waiting inflated
# the gauge exactly when the pool was saturated and someone was reading it.
#
# Filtered here rather than spliced on cancellation: splicing is O(n) per
# cancel, so cancelling a large queue became O(n^2) -- measured at 22 seconds
# of blocked event loop for 20,000 waiters, which is a worse failure than the
# wrong number it corrected.
sub waiting_count   { scalar grep { !$_->{future}->is_ready } @{shift->{waiting}} }
sub total_count     { my $s = shift; scalar(@{$s->{idle}}) + scalar(@{$s->{active}}) }
sub stats           { shift->{stats} }
sub safe_dsn        { Async::DBD::Pg::Util::safe_dsn(shift->{dsn}) }

# The version of the server this pool is connected to, in PostgreSQL's integer
# form. Read from any live connection, since a pool addresses one database.
sub server_version {
    my ($self) = @_;

    for my $conn (@{ $self->{idle} }, @{ $self->{active} }) {
        my $v = $conn->server_version;
        return $v if defined $v;
    }

    return undef;
}

sub pubsub {
    my ($self) = @_;
    $self->_check_fork;
    return $self->{_pubsub} //= Async::DBD::Pg::PubSub->new(pool => $self);
}

async sub listen {
    my ($self, @args) = @_;
    return await $self->pubsub->listen(@args);
}

async sub unlisten {
    my ($self, @args) = @_;
    return await $self->pubsub->unlisten(@args);
}

async sub unlisten_all {
    my ($self) = @_;
    return await $self->pubsub->unlisten_all;
}

async sub notify {
    my ($self, @args) = @_;
    return await $self->pubsub->notify(@args);
}

# Check out, run, release -- including when the work fails or the caller
# cancels mid-flight. A guard rather than a release after the await: a
# cancelled async sub never resumes, so anything written after the await would
# not run, which is exactly how a checkout gets stranded. See
# Async::DBD::Pg::PubSub::_CheckoutGuard, which exists for the same reason.
async sub with_connection {
    my ($self, $code, @args) = @_;

    my $conn  = await $self->connection;
    my $guard = Async::DBD::Pg::_ReleaseGuard->new($conn);

    return await $code->($conn, @args);
}

async sub query {
    my ($self, @args) = @_;

    my $conn  = await $self->connection;
    my $guard = Async::DBD::Pg::_ReleaseGuard->new($conn);

    return await $conn->query(@args);
}

# Settable after construction as well, so an application can attach tracing
# to a pool it was handed rather than one it built.
sub on_query {
    my ($self, $callback) = @_;

    $self->{on_query} = $callback if @_ > 1;

    return $self->{on_query};
}

async sub query_row {
    my ($self, @args) = @_;

    my $conn  = await $self->connection;
    my $guard = Async::DBD::Pg::_ReleaseGuard->new($conn);

    return await $conn->query_row(@args);
}

async sub query_value {
    my ($self, @args) = @_;

    my $conn  = await $self->connection;
    my $guard = Async::DBD::Pg::_ReleaseGuard->new($conn);

    return await $conn->query_value(@args);
}

async sub query_list {
    my ($self, @args) = @_;

    my $conn  = await $self->connection;
    my $guard = Async::DBD::Pg::_ReleaseGuard->new($conn);

    return await $conn->query_list(@args);
}

async sub transaction {
    my ($self, @rest) = @_;

    my $conn  = await $self->connection;
    my $guard = Async::DBD::Pg::_ReleaseGuard->new($conn);

    return await $conn->transaction(@rest);
}

# Close the pool. Idle connections go at once, connections still checked out
# are waited for so their owners are not cut off mid-query, and anyone queued
# is told rather than left waiting for a connection that is not coming.
#
# The shape follows node-postgres, whose end() waits for checked out clients
# and then closes the clients and the pool timers, and asyncpg, which pairs a
# graceful close() with an immediate terminate(). asyncpg's own documentation
# recommends imposing a timeout on close, so that is offered here directly
# rather than left to the caller.
async sub shutdown {
    my ($self, %opts) = @_;

    return $self if $self->{_shut_down};

    $self->{_shutting_down} = 1;
    $self->_cancel_idle_reap;

    my $shutting_down = sub {
        Async::DBD::Pg::Error::PoolExhausted->new(
            message   => 'Connection pool is shutting down',
            pool_size => $self->{max_connections},
        );
    };

    for my $waiter (splice @{$self->{waiting}}) {
        next if $waiter->{future}->is_ready;
        $waiter->{future}->fail($shutting_down->());
    }

    # The listener holds a connection for as long as it is subscribed, so it
    # has to give it back before the pool can drain.
    $self->_shutdown_pubsub;

    $_->_close_dbh for splice @{$self->{idle}};

    if (!$opts{force} && $self->active_count) {
        # pending_future rather than a bare Future->new, for the same reason
        # the queue branch of connection() uses it: this is what the caller's
        # future ends up awaiting, and a bare Future gives back one whose
        # top-level ->get can never block, only croak once it isn't already
        # ready. That made `$pg->shutdown->get` work only when the pool had
        # nothing to wait for -- which is precisely when it is not needed.
        my $drained = $self->{_drained} = pending_future();

        if (my $timeout = $opts{timeout}) {
            my $timer = Future::IO->sleep($timeout);
            await Future->wait_any($drained, $timer);
            $timer->cancel unless $timer->is_ready;
        }
        else {
            await $drained;
        }
    }

    # Whatever is still checked out is closed, whether it came back or not.
    $_->_close_dbh for splice @{$self->{active}};

    # Stop anything the pool started that nobody is waiting on.
    for my $f (values %{ delete $self->{_background} || {} }) {
        $f->cancel unless $f->is_ready;
    }

    delete $self->{_drained};
    $self->{_shut_down} = 1;

    return $self;
}

sub is_shut_down { shift->{_shut_down} ? 1 : 0 }

# Keep a handle on work the pool started that nobody is waiting for, so
# shutdown can stop it rather than leaving it to run against a closed pool.
# Conduit collects its background futures in a Future::Selector for the same
# reason; a selector wants a run loop of its own, which suits a server but not
# a library living inside someone else's loop, so this keeps just the part
# that matters.
sub _run_in_background {
    my ($self, $f) = @_;

    my $key = refaddr $f;
    $self->{_background}{$key} = $f;

    my $pool = $self;
    weaken($pool);

    $f->on_ready(sub {
        my $live = $pool or return;
        delete $live->{_background}{$key};
    });

    # No retain: the collection above is what keeps this future alive, and it
    # is what lets shutdown cancel it. Retaining as well would only mean
    # nothing could ever stop it.

    return $f;
}

# Signal a drain once nothing is checked out any more.
sub _check_drained {
    my ($self) = @_;

    my $drained = $self->{_drained} or return;
    return if $self->active_count;

    $drained->done unless $drained->is_ready;
}

sub is_healthy {
    my ($self) = @_;

    return 0 if $self->{_shutting_down};

    # True when a caller would be handed a connection straight away: one is
    # sitting idle, or there is room to create another. A pool whose
    # connections are all busy at max_connections reports false, because the
    # next caller has to queue.
    return 1 if $self->idle_count;
    return $self->total_count < $self->{max_connections} ? 1 : 0;
}

# Close connections that have been idle longer than idle_timeout, never
# taking the pool below min_connections. Busy connections count towards that
# floor, since they are still part of the pool.
# Connections the pool has committed to: those it holds plus those still
# connecting. total_count reports only the ones that have arrived, which is
# what callers asking for pool statistics want, but every decision about
# whether there is room has to include the ones on their way.
sub _committed_count {
    my ($self) = @_;
    return $self->total_count + $self->{_connecting};
}

sub _reap_idle_connections {
    my ($self) = @_;

    my $timeout = $self->{idle_timeout} or return;

    my $now = time();
    my (@keep, @expired);

    for my $conn (@{$self->{idle}}) {
        my $idle_for = $now - ($conn->last_used // $now);
        push @{ $idle_for >= $timeout ? \@expired : \@keep }, $conn;
    }

    return unless @expired;

    my $shortfall = $self->{min_connections} - (@keep + $self->active_count);
    while ($shortfall > 0 && @expired) {
        push @keep, shift @expired;
        $shortfall--;
    }

    @{$self->{idle}} = @keep;
    $self->_discard_connection($_) for @expired;
}

# Number of idle connections that could be reaped, ignoring their age.
sub _reapable_count {
    my ($self) = @_;

    my $reapable = $self->total_count - $self->{min_connections};
    $reapable = $self->idle_count if $reapable > $self->idle_count;

    return $reapable > 0 ? $reapable : 0;
}

# Reaping is driven by a timer that exists only while there is something it
# could close, so a pool sitting at min_connections does not hold the event
# loop open.
sub _schedule_idle_reap {
    my ($self) = @_;

    return unless $self->{idle_timeout};
    return if $self->{_reap_timer};
    return unless $self->_reapable_count;

    my $pool = $self;
    weaken($pool);

    my $timer = Future::IO->sleep($self->{idle_timeout});
    $self->{_reap_timer} = $timer;

    $timer->on_done(sub {
        my $live = $pool or return;
        delete $live->{_reap_timer};
        $live->_reap_idle_connections;
        $live->_schedule_idle_reap;
    });

    return;
}

sub _cancel_idle_reap {
    my ($self) = @_;

    my $timer = delete $self->{_reap_timer} or return;
    $timer->cancel unless $timer->is_ready;
}

sub _shutdown_pubsub {
    my ($self) = @_;
    my $pubsub = delete $self->{_pubsub} or return;
    $pubsub->_pool_shutdown;
}

sub _close_all_connections {
    my ($self) = @_;

    $self->_cancel_idle_reap;
    $self->_shutdown_pubsub;

    my @conns = (@{$self->{idle}}, @{$self->{active}});
    @{$self->{idle}} = ();
    @{$self->{active}} = ();

    for my $conn (@conns) {
        next unless $conn;
        $conn->{released} = 1;
        $conn->_close_dbh;
    }
}

# Get a connection from the pool
async sub connection {
    my ($self) = @_;

    die Async::DBD::Pg::Error::PoolExhausted->new(
        message   => 'Connection pool has been shut down',
        pool_size => $self->{max_connections},
    ) if $self->{_shutting_down};

    $self->_check_fork;

    # 1. Try to get an idle connection
    if (my $conn = shift @{$self->{idle}}) {
        push @{$self->{active}}, $conn;
        $conn->{last_used} = time();
        $conn->{released} = 0;

        # It has been sitting unused and its server may have gone away since.
        $conn->{_check_liveness} = 1;

        return $conn;
    }

    # 2. Create new connection if under limit
    if ($self->_committed_count < $self->{max_connections}) {
        # Counted as in progress for as long as the handshake runs. This has
        # to be a guard rather than a decrement afterwards: a caller can
        # cancel while this sub is suspended at the await below, which tears
        # the sub down without running another line of it. Losing the
        # decrement that way would make the pool believe a connection was
        # arriving forever, and once that happened max_connections times
        # nothing could ever be created again.
        my $in_progress = Async::DBD::Pg::_ConnectingGuard->new($self);

        my $conn = await $self->_create_connection;

        push @{$self->{active}}, $conn;
        return $conn;
    }

    # 3. Queue and wait
    #
    # pending_future rather than a bare Future->new: a caller that has to
    # queue here is otherwise handed back a future whose top-level ->get can
    # never block, only croak once it isn't already ready -- see
    # Async::DBD::Pg::Util for why.
    my $future = pending_future();
    my $waiting = {
        future    => $future,
        queued_at => time(),
    };
    push @{$self->{waiting}}, $waiting;

    # Set up timeout
    my $timeout_future;
    if (my $timeout = $self->{queue_timeout}) {
        $timeout_future = Future::IO->sleep($timeout);
        $timeout_future->on_done(sub {
            @{$self->{waiting}} = grep { $_ != $waiting } @{$self->{waiting}};
            $self->{stats}{timeouts}++;
            $future->fail(
                Async::DBD::Pg::Error::PoolExhausted->new(
                    message   => "Connection pool exhausted (waited ${timeout}s)",
                    pool_size => $self->{max_connections},
                )
            ) unless $future->is_ready;
        });
    }

    my $conn = await $future;
    $timeout_future->cancel if $timeout_future && !$timeout_future->is_ready;
    return $conn;
}

# Create a new connection. pg_async_connect needs DBD::Pg 3.19.0 and this
# distribution requires 3.20.0, so the handshake is always asynchronous.
async sub _create_connection {
    my ($self) = @_;

    my $parsed = $self->{_parsed_dsn};

    my %attrs = (
        AutoCommit        => 1,
        # Off for the connect itself: an async connect returns a handle whose
        # handshake is still in flight, and errors are collected by
        # _complete_async_connect instead. Restored below once it finishes.
        RaiseError        => 0,
        PrintError        => 0,
        # A PostgreSQL NOTICE is delivered to DBI as a warning, and Connection
        # routes it through the pool's on_log by wrapping the calls that can
        # raise one in a $SIG{__WARN__} handler. That only works if DBI still
        # calls warn() for it: PrintWarn => 0 drops the notice text entirely
        # (errstr goes undef, there's nothing left to route), so this is set
        # explicitly rather than left to default, which depends on the
        # caller's own $^W and is not something to depend on here.
        PrintWarn         => 1,
        pg_enable_utf8    => 1,
        pg_server_prepare => 1,
    );

    $attrs{pg_async_connect} = 1;

    my $dbh = eval {
        DBI->connect(
            $parsed->{dbi_dsn},
            $parsed->{user},
            $parsed->{password},
            \%attrs,
        );
    };

    if ($@ || !$dbh) {
        my $err = $@ || DBI->errstr || 'Unknown connection error';
        $self->{stats}{connect_failures}++;
        die Async::DBD::Pg::Error::Connection->new(
            message => "Connection failed: $err",
            dsn     => $self->safe_dsn,
        );
    }

    await $self->_complete_async_connect($dbh);
    $dbh->{RaiseError} = 1;

    # Promote to a named server-side prepared statement on the first execute
    # rather than the second. This is a handle attribute, not a per-statement
    # one, and the statement cache does not work without it: DBD::Pg's default
    # of 2 promotes on a handle's second execute, but a handle the cache has
    # not kept is gone before then, so every execute would be a first one and
    # nothing would ever be promoted.
    #
    # It is also what makes a cached handle safe to reuse. Only a named
    # statement has a server-side cached plan, and only a cached plan makes
    # PostgreSQL raise 0A000 when a schema change alters the result shape.
    # Without that error the reused handle fetches the new shape through a row
    # buffer sized for the old one, which segfaults DBD::Pg 3.20.2.
    $dbh->{pg_switch_prepared} = 1 if $self->{statement_cache_size};

    # Set statement timeout if configured
    if (my $timeout = $self->{statement_timeout}) {
        $dbh->do("SET statement_timeout = '${timeout}s'");
    }

    my $conn = Async::DBD::Pg::Connection->new(
        dbh         => $dbh,
        pool        => $self,
        id          => $self->{_next_connection_id}++,
        created_at  => time(),
        query_count => 0,
        statement_cache_size => $self->{statement_cache_size},
    );

    # Run on_connect callback
    if (my $on_connect = $self->{on_connect}) {
        eval { await $on_connect->($conn) };
        if (my $on_connect_err = $@) {
            # Captured before _close_dbh runs: it disconnects through its own
            # eval, which clears $@ on success, so dying with $@ directly
            # here would report a bare "Died at ..." instead of the actual
            # on_connect failure.
            $self->_log(warn => "on_connect failed: $on_connect_err");
            $conn->_close_dbh;
            $self->{stats}{connect_failures}++;
            die $on_connect_err;
        }
    }

    $self->{stats}{created}++;
    return $conn;
}

# Give a connection a working handle in place of a dead one. The replacement
# is built by the ordinary connect path, so async connect, on_connect and
# statement_timeout all apply and there is no second copy of connect logic to
# drift. The Connection object never leaves the active list, so no pool counts
# move.
#
# This does not take a _ConnectingGuard: that guard exists so a caller waiting
# in connection() sees room, not room-minus-one, while a connect is in flight.
# Taking one here would count the replacement while the dead Connection is
# still on the active list, pushing _committed_count to max_connections + 1
# and blocking an unrelated caller for the duration of the heal -- worse than
# transiently over-admitting the pool by one on what is already a rare path.
async sub _replace_dbh {
    my ($self, $conn) = @_;

    my $fresh = await $self->_create_connection;

    # Take the handle and neutralise the wrapper it arrived in: it was never
    # added to any pool list, and its destructor would otherwise release a
    # connection the pool is not tracking.
    my $dbh = delete $fresh->{dbh};
    $fresh->{released} = 1;
    $fresh->{pool}     = undef;

    $conn->_close_dbh;
    $self->{stats}{discarded}++;

    $conn->{dbh} = $dbh;

    # _get_socket memoises its dup()'d poll socket on the Connection, keyed by
    # raw fd number. On the ordinary heal path that number is already free
    # before this runs, not merely available for reuse on some future edit:
    # _heal_if_dead's ping has already made libpq close the dead socket
    # (pg_socket reads -1 by the time _replace_dbh is entered), so the
    # replacement built by _create_connection above commonly lands on the
    # exact same fd. Without these two deletes, _get_socket's cache-hit check
    # only compares that number, sees no change, and hands _wait_for_result a
    # dup of the socket that was already closed -- which reports readable at
    # EOF, so the poll loop busy-waits for the life of every query on the
    # connection instead of waiting once. Measured: 11 Future::IO->poll calls
    # with these deletes, ~50,000 without, for one query. One full core,
    # silently; on a listener loop, forever.
    delete $conn->{_cached_sock};
    delete $conn->{_cached_fd};

    # The statement cache is emptied by _close_dbh above, which owns that
    # invariant: prepared statements belong to the backend that made them.

    return $conn;
}

# Complete async connection handshake using Future::IO
async sub _complete_async_connect {
    my ($self, $dbh) = @_;

    my $timeout = $self->{connect_timeout};

    # Get initial status
    my $status = $dbh->pg_continue_connect;

    if ($status == 0) {
        # Already connected
        return;
    }
    elsif ($status == -2) {
        $self->{stats}{connect_failures}++;
        die Async::DBD::Pg::Error::Connection->new(
            message => "Connection failed: " . ($dbh->errstr // 'Unknown error'),
            dsn     => $self->safe_dsn,
        );
    }

    # libpq may close the socket and connect again part way through the
    # handshake, for instance when it offers GSSAPI or SSL encryption and the
    # server declines, and DBD::Pg documents that the socket may have changed
    # after each call to pg_continue_connect. Wrap whichever descriptor is
    # current at each poll: a wrapper built once ends up waiting on the
    # abandoned connection, which never becomes ready.
    #
    # The wrappers stay alive for the whole handshake so a closed descriptor
    # number cannot be reused while an event loop still holds a poll
    # registration against it. They close with @polled, including on the
    # error paths below.
    my @polled;

    my $poll_current_socket = sub {
        my ($events) = @_;

        my $socket_fd = $dbh->{pg_socket};
        die "No PostgreSQL socket" unless defined $socket_fd;

        my $dup_fd = dup($socket_fd);
        die "Cannot dup pg_socket: $!" unless defined $dup_fd;

        my $sock = IO::Socket->new;
        unless ($sock->fdopen($dup_fd, "r+")) {
            POSIX::close($dup_fd);
            die "Cannot fdopen pg_socket: $!";
        }
        push @polled, $sock;

        return Future::IO->poll($sock, $events);
    };

    # Set up timeout
    my $timeout_future;
    if ($timeout) {
        $timeout_future = Future::IO->sleep($timeout);
    }

    # Poll until connected
    while (1) {
        my $wait_future;
        if ($status == 1) {
            # Need to wait for read
            $wait_future = $poll_current_socket->(POLLIN);
        }
        elsif ($status == 2) {
            # Need to wait for write
            $wait_future = $poll_current_socket->(POLLOUT);
        }
        else {
            last;  # Connected or error
        }

        # Wait with optional timeout
        if ($timeout_future && !$timeout_future->is_ready) {
            my $race = Future->wait_any($wait_future, $timeout_future);
            await $race;

            if ($timeout_future->is_ready && !$wait_future->is_ready) {
                $wait_future->cancel;
                $self->{stats}{connect_failures}++;
                die Async::DBD::Pg::Error::Connection->new(
                    message => "Connection timeout after ${timeout}s",
                    dsn     => $self->safe_dsn,
                );
            }
        }
        else {
            await $wait_future;
        }

        # Continue the handshake
        $status = $dbh->pg_continue_connect;

        if ($status == 0) {
            # Connected!
            $timeout_future->cancel if $timeout_future && !$timeout_future->is_ready;
            return;
        }
        elsif ($status == -2) {
            $timeout_future->cancel if $timeout_future && !$timeout_future->is_ready;
            $self->{stats}{connect_failures}++;
            die Async::DBD::Pg::Error::Connection->new(
                message => "Connection failed: " . ($dbh->errstr // 'Unknown error'),
                dsn     => $self->safe_dsn,
            );
        }
    }
}

# Return connection to pool (called by Connection::release)
sub _return_connection {
    my ($self, $conn, %opts) = @_;

    # Callers that cannot afford a blocking round trip, such as DESTROY, ask
    # for the liveness check to be skipped.
    my $validate = exists $opts{validate} ? $opts{validate} : 1;

    # A connection coming back during shutdown is closed rather than kept,
    # and may be the one the drain is waiting for.
    if ($self->{_shutting_down}) {
        @{$self->{active}} = grep { $_ != $conn } @{$self->{active}};
        $conn->_close_dbh;
        $self->{stats}{discarded}++;
        $self->_check_drained;
        return;
    }

    # Remove from active list
    @{$self->{active}} = grep { $_ != $conn } @{$self->{active}};

    # Check if connection is still valid
    if (!$conn->{dbh} || ($validate && !$conn->{dbh}->ping)) {
        $self->_discard_connection($conn);
        return;
    }

    # Check max_queries limit
    if ($self->{max_queries} && $conn->query_count >= $self->{max_queries}) {
        $self->_discard_connection($conn);
        $self->_ensure_min_connections;
        return;
    }

    my $on_release = $self->{on_release};

    # A connection carrying an open transaction must never go back into the
    # pool: the next borrower would inherit its locks, and any cursor
    # declared inside it stays open until that transaction ends. This reset
    # is not conditional on an on_release callback being configured.
    if (!$conn->{in_transaction} && !$on_release) {
        $self->_release_to_idle_or_waiting($conn);
        return;
    }

    my $cleanup = async sub {
        eval {
            if ($conn->{in_transaction}) {
                await $conn->query('ROLLBACK');
                $conn->{in_transaction} = 0;
            }
            await $on_release->($conn) if $on_release;
        };
        if ($@) {
            $self->_log(warn => "connection reset failed: $@");
            $self->_discard_connection($conn);
            return;
        }
        $self->_release_to_idle_or_waiting($conn);
    };
    $self->_run_in_background($cleanup->());
}

sub _release_to_idle_or_waiting {
    my ($self, $conn) = @_;

    # Work started before the pool closed can finish after it. The pool is
    # shut, so the connection is closed rather than put back where nothing
    # would ever close it.
    if ($self->{_shutting_down}) {
        $conn->_close_dbh;
        $self->{stats}{discarded}++;
        $self->_check_drained;
        return;
    }

    # Give the connection to the first caller still waiting for one. A waiter
    # whose future has already settled has timed out or been cancelled, and
    # handing it the connection would park it on the active list with nobody
    # left to release it, shrinking the pool for good.
    while (my $waiting = shift @{$self->{waiting}}) {
        next if $waiting->{future}->is_ready;

        push @{$self->{active}}, $conn;
        $conn->{last_used} = time();
        $conn->{released} = 0;
        $waiting->{future}->done($conn);
        return;
    }

    # Otherwise return to idle pool
    push @{$self->{idle}}, $conn;
    $self->{stats}{released}++;
    $self->_schedule_idle_reap;
}

sub _discard_connection {
    my ($self, $conn) = @_;
    $conn->_close_dbh;

    # Mark it released so that DESTROY, finding the dbh already gone, does
    # not mistake this for an unreleased connection and route it back
    # through _return_connection, which would discard it a second time.
    $conn->{released} = 1;
    $self->{stats}{discarded}++;
}

# Whatever killed one connection has usually killed the rest, so finding a
# dead one is reason to drop the whole idle set rather than let each be
# rediscovered by a later caller. Connections that are checked out are left
# alone: their owners are mid-work, and each repairs itself on its next
# statement.
#
# Unlike the other two discard paths -- max_queries retirement calls
# _ensure_min_connections afterwards, and idle-timeout reaping deliberately
# keeps the floor in the first place -- this one does not try to refill down
# to min_connections. Deliberate: the server the idle set was just found dead
# against may still be down, and reconnecting immediately to it would only
# manufacture more connect failures rather than restore capacity. The pool
# sits below its floor until a caller asks for a connection on demand, up to
# max_connections; that caller pays connect latency, not a failure.
sub _discard_idle_connections {
    my ($self) = @_;

    my @idle = splice @{$self->{idle}};
    $self->_discard_connection($_) for @idle;

    return scalar @idle;
}

sub _ensure_min_connections {
    my ($self) = @_;

    my $needed = $self->{min_connections} - $self->_committed_count;
    return if $needed <= 0;

    for (1 .. $needed) {
        my $f = $self->_create_connection;
        $f->on_done(sub {
            my ($conn) = @_;

            # The pool may have closed while this was connecting.
            if ($self->{_shutting_down}) {
                $conn->_close_dbh;
                return;
            }

            push @{$self->{idle}}, $conn;
        });
        $f->on_fail(sub {
            my ($err) = @_;
            $self->_log(warn => "Failed to create initial connection: $err");
        });
        $self->_run_in_background($f);
    }
}

sub _check_fork {
    my ($self) = @_;
    if ($self->{pid} != $$) {
        # Child processes must not inherit live libpq handles.
        $self->_close_all_connections;
        $self->{pid} = $$;
    }
}

sub _log {
    my ($self, $level, $message) = @_;
    if (my $cb = $self->{on_log}) {
        $cb->($level, $message);
    }
    else {
        warn "Async::DBD::Pg [$level]: $message\n";
    }
}

sub DESTROY {
    my ($self) = @_;
    return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
    $self->_close_all_connections;
}

package Async::DBD::Pg::_ConnectingGuard;

# Holds a slot in the pool's in-progress count for as long as it is alive,
# releasing it however the connect attempt ends: returning, dying, or being
# cancelled while suspended.

use strict;
use warnings;
use Scalar::Util qw(weaken);

sub new {
    my ($class, $pool) = @_;

    $pool->{_connecting}++;

    my $self = bless { pool => $pool }, $class;
    weaken($self->{pool});

    return $self;
}

sub DESTROY {
    my ($self) = @_;

    my $pool = $self->{pool} or return;
    $pool->{_connecting}--;
}

# Releases the connection checked out by query(), transaction() and
# with_connection(), however the call ends -- success, the work dying, or the
# caller cancelling while suspended at the await above it. A cancelled async
# sub never resumes past its current await, so a plain release written after
# it would simply not run, which is exactly how a checkout gets stranded. See
# Async::DBD::Pg::PubSub::_CheckoutGuard (PubSub.pm), which exists for the
# same reason.
#
# Never disarmed: the checkout this guard holds is never published anywhere
# else -- it is handed only to $code or to $conn->query/$conn->transaction,
# both of which return before this guard goes out of scope -- so it always
# wants exactly one release, on every path.
package Async::DBD::Pg::_ReleaseGuard;

use strict;
use warnings;

sub new {
    my ($class, $conn) = @_;

    return bless { conn => $conn }, $class;
}

sub DESTROY {
    my ($self) = @_;

    my $conn = delete $self->{conn} or return;
    $conn->release;
}

package Async::DBD::Pg;

1;

__END__

=head1 NAME

Async::DBD::Pg - Event-loop agnostic async PostgreSQL client

=head1 SYNOPSIS

    use Future::AsyncAwait;
    use Future::IO;
    use Async::DBD::Pg;

    # Required. Without a real implementation loaded, Future::IO drives one
    # filehandle at a time and puts handles into blocking mode, so a pool
    # runs its queries one after another -- with no error and no warning.
    BEGIN { Future::IO->load_best_impl }

    my $pg = Async::DBD::Pg->new(
        dsn             => 'postgresql://user:pass@host/db',
        min_connections => 2,
        max_connections => 10,
    );

    (async sub {
        # The pool checks a connection out and gives it back for each of
        # these, so nothing can be left checked out by accident.
        my $user  = await $pg->query_row('SELECT * FROM users WHERE id = $1', 1);
        my $count = await $pg->query_value('SELECT count(*) FROM users');

        # Statements that must share one connection go in a block, which
        # returns the connection however the block ends -- including on death.
        await $pg->with_connection(async sub {
            my ($conn) = @_;
            await $conn->query('SET LOCAL statement_timeout = 5000');
            await $conn->query('SELECT * FROM big_report');
        });
    })->()->get;

    await $pg->shutdown(timeout => 5);

=head1 DESCRIPTION

B<WARNING: This is extremely beta software.> The API is subject to change
without notice.

Async::DBD::Pg provides an async PostgreSQL client built on top of
L<DBD::Pg> and L<DBI>, with L<Future::IO> used as the event-loop
abstraction layer. Features include:

=over 4

=item * Connection pooling with automatic management

=item * Named and positional placeholders, leaving C<?> free for PostgreSQL's
own operators

=item * Transaction support with savepoints

=item * Cursor-based streaming for large result sets

=item * Query timeout support

=item * LISTEN/NOTIFY pub/sub support

=back

=head2 Why Perl 5.24 Is Required

The floor is set by a dependency rather than by preference, and it cannot be
lowered without giving up correctness.

L<Future::AsyncAwait> implements cancellation propagation only on Perl 5.24
and later. On an older Perl an C<async sub> still stops running when it is
cancelled, but the cancellation is not passed into the future it was waiting
on.

A connection pool is largely a story about work being abandoned: a caller
gives up on a query, a listener is told to stop, an application shuts the pool
down while a connection is still being established. Each of those paths has to
release something: a connection slot, a statement handle, a paused
listener. Each relies on the cancellation reaching the operation actually being
awaited. Without that the resource is never released, and the pool degrades
quietly rather than failing visibly.

This was established by testing, not by reading. The suite passes on Perl 5.24
through 5.40 and fails outright on 5.20 and 5.22, taking the cursor and
transaction tests with it.

Perl 5.18 is excluded twice over: L<DBI> 1.651 and later require Perl 5.20, so
a fresh install cannot resolve a current DBI on it at all.

=head2 Event Loop Independence

This module is intentionally DBD::Pg-backed rather than backend-pluggable.
L<Future::IO> provides the event-loop abstraction layer, making the wrapper
compatible with any event loop that has a Future::IO implementation:

    # UV (libuv)
    use Future::IO::Impl::UV;

    # IO::Async
    use Future::IO::Impl::IOAsync;

    # GLib
    use Future::IO::Impl::Glib;

=head2 Connect Behavior

Queries are asynchronous everywhere this module runs, using DBD::Pg's async
query support combined with L<Future::IO>'s socket readiness detection.

Connection establishment is asynchronous as well, using C<pg_async_connect>,
C<pg_continue_connect>, and L<Future::IO>'s official C<poll> API. Those
entry points arrived in DBD::Pg 3.19.0, which is part of why this
distribution requires 3.20.0. There is no synchronous connect path.

=head2 Advanced DBI Access

The wrapper API is the supported primary interface. For advanced cases,
connection objects still expose the underlying DBI handle via C<dbh>. Direct
handle usage is an escape hatch and is not coordinated with the wrapper's
query scheduling or pool lifecycle.

=head1 METHODS

=head2 new(%args)

    my $pg = Async::DBD::Pg->new(
        dsn              => 'postgresql://user:pass@host/db',
        min_connections  => 1,
        max_connections  => 10,
        idle_timeout     => 300,
        queue_timeout    => 30,
        statement_timeout => 60,
        max_queries      => 10000,
        on_connect       => async sub { ... },
        on_release       => async sub { ... },
    );

=head3 dsn

PostgreSQL connection URI, C<postgresql://user:pass@host:port/dbname>.
Required.

=head3 min_connections

Connections to open when the pool is built and to keep open thereafter.
Defaults to 1. Reaping will not take the pool below this, and connections in
use count towards it.

=head3 max_connections

Most connections the pool will hold. Defaults to 10. Callers arriving when
every connection is busy wait in a queue rather than opening more.

Keep this well below the server's own C<max_connections>. Every instance of
your application draws on the same limit, as do psql sessions, monitoring and
migrations, PostgreSQL reserves a few for superusers, and each pub/sub
listener holds one for as long as it is subscribed.

=head3 idle_timeout

Seconds a connection may sit idle before it is closed and dropped from the
pool. Defaults to 300. Pass 0 to keep idle connections open indefinitely.

C<min_connections> is a floor that reaping respects, so a pool configured to
keep connections will keep them however long they stay idle. Connections
currently in use count towards that floor.

Reaping is driven by a timer that exists only while there are connections old
enough to be worth closing, so a pool resting at C<min_connections> does not
hold the event loop open on its own.

=head3 queue_timeout

Seconds a caller waits for a connection once the pool is at
C<max_connections>, before failing with
L<Async::DBD::Pg::Error/Async::DBD::Pg::Error::PoolExhausted>. Defaults to 30.
Pass 0 to wait indefinitely.

=head3 connect_timeout

Seconds to allow for establishing a connection, after which
L<Async::DBD::Pg::Error/Async::DBD::Pg::Error::Connection> is thrown. Defaults
to 30. Pass 0 to wait indefinitely.

=head3 statement_timeout

Seconds, applied by setting PostgreSQL's own C<statement_timeout> on each new
connection, so it covers every statement rather than a chosen one. The
C<timeout> option to L<Async::DBD::Pg::Connection/query> bounds a single
query.

=head3 max_queries

Statements a connection may run before it is closed and replaced. Unset by
default, meaning connections are kept indefinitely. Useful against slow growth
in a long-lived backend.

=head3 statement_cache_size

Prepared statements each connection keeps for reuse. C<0>, the default,
disables the cache, and nothing below applies.

The cache holds a server-side prepared statement per entry, so what it saves
is B<planning>, not round trips. That makes the workload decide whether it is
worth anything. Measured here against PostgreSQL 16, 300 statements per run:

=over 4

=item * Statements the planner disposes of instantly -- C<SELECT $1::int> and
the like -- gain nothing measurable, at any latency.

=item * A three-table join with an C<ORDER BY> saves around 400 microseconds
per execution, which was 22% end to end over a loopback socket and 5.7% with
2ms of round-trip latency in the way. The absolute saving barely moves with
latency; the percentage shrinks because the round trips grow.

=back

Size it to hold the working set. A cache too small for the statements in
rotation evicts an entry on every query and re-prepares it on the next,
which costs a round trip that not caching at all would never have paid: two
statements sharing a cache of one measured 36% B<slower> than C<0> on the
join workload and 131% slower on the trivial one. Undersized is worse than
absent, so prefer to leave this off rather than guess low.

Only statements carrying placeholders are cached. DBD::Pg gives a
server-side prepared statement to those and to no others, so for the rest an
entry would hold nothing the server knows about. Enabling the cache also
sets C<pg_switch_prepared> to C<1> on every connection it opens, which is
what makes that statement exist from the first execution rather than the
second.

Do not enable this behind a connection pooler in transaction-pooling mode.
Consecutive transactions land on different backends there, and a prepared
statement belongs to the backend that made it. Recovery is automatic -- the
missing statement comes back as SQLSTATE 26000 and the query is retried on a
freshly prepared one -- but paying for that on most queries is slower than
never having cached. Session pooling is unaffected.

=head3 on_connect

    on_connect => async sub {
        my ($conn) = @_;
        await $conn->query("SET application_name = 'my app'");
    },

Called with each newly established connection before it is handed to anyone,
which is where session settings belong: C<search_path>, timezone, or the
DBD::Pg attributes this module does not wrap. A callback that dies discards
the connection and the failure reaches the caller who asked for it.

Also called when L</heal_dead_connections> replaces a dead connection's
handle, since the replacement is built by the same connect path. In that
case the C<$conn> passed in is a donor: only its handle is kept, and moments
later the wrapper itself is left with no handle and no pool. A callback that
retains its C<$conn> beyond returning -- to register it in a table of live
connections, say -- will find that on a heal it was handed one of these
rather than a connection the pool will ever hand to a caller.

=head3 on_release

    on_release => async sub {
        my ($conn) = @_;
        await $conn->query('DISCARD TEMP');
    },

Called as a connection returns to the pool. An open transaction is already
rolled back before this runs, so it is for cleanup of your own. A callback
that dies causes the connection to be discarded rather than reused.

=head3 on_log

    on_log => sub {
        my ($level, $message) = @_;
        ...
    },

Receives the pool's own diagnostics. Without it they go to C<warn>.

Also receives PostgreSQL server notices, at level C<info> -- the C<NOTICE> a
statement such as C<DROP TABLE IF EXISTS> on a table that does not exist, or
an explicit C<RAISE NOTICE>, produces. Without this option those notices
still reach C<warn> the same way the pool's own diagnostics do; what changes
is that they no longer bypass C<on_log> and print straight to file
descriptor 2 regardless of whether a handler is configured.

=head3 on_query

    on_query => sub {
        my ($event) = @_;
        warn "slow: $event->{sql}" if $event->{elapsed} > 1;
    },

Called once per statement, with a hashref describing it:

=over 4

=item * C<sql> -- the statement as sent, after any C<:name> placeholders
were rewritten

=item * C<binds> -- an arrayref of the bind values

=item * C<elapsed> -- how long it took, in fractional seconds

=item * C<rows> -- the number of rows returned, or C<undef> if it failed

=item * C<error> -- the failure, or C<undef> if it succeeded

=item * C<cached> -- true if the statement was reused from the connection's
prepared-statement cache. Always false when L</statement_cache_size> is C<0>,
and always false for a statement without placeholders, which is never cached.
A hit rate well below 1 says the cache is too small for the working set,
which is the case where it costs more than it saves.

=item * C<connection> -- the id of the connection that ran it, so statements
can be attributed to a connection across a pool

=back

Fires on success and on failure alike, so a handler counting statements sees
all of them.

This one hook is slow-query logging, request tracing, metrics collection,
and the test assertion "this code path ran two queries". It is deliberately
one callback rather than an event system; there is nothing to subscribe to
and no event types to learn.

A handler that dies is reported through L</on_log> and otherwise ignored:
observing a query must not be able to fail it, nor mask an error it is
already carrying.

Note that C<binds> holds the values as they were passed. A handler that logs
them unfiltered will log whatever was bound, including a C<bytea> payload.

It can also be set or replaced after construction:

    $pg->on_query(sub { ... });
    $pg->on_query(undef);        # and removed

=head3 reconnect

Re-establish the pub/sub listener when its connection fails, re-subscribing
every channel that was registered. Off by default.

A listener is long lived, so the connection it holds will eventually be lost to
a network fault, a failover or a server restart. Without this, the subscription
is gone and nothing arrives again.

Notifications sent while the listener was down are not recovered.
C<LISTEN>/C<NOTIFY> keeps no history, so there is nothing to replay. What this
gives you is a listener that comes back and tells you it did; if you need to
know what you missed, resynchronise from your own tables when L</on_reconnect>
fires.

=head3 reconnect_min_interval

Seconds to wait before the first reconnect attempt. Defaults to 0.5.

=head3 reconnect_max_interval

Longest the wait between attempts may grow to. Defaults to 30.

The wait doubles from the minimum towards this ceiling and is then jittered, so
many listeners reconnecting to the same server do not arrive together. Attempts
continue indefinitely; each one is reported through L</on_log>.

=head3 on_reconnect

    on_reconnect => sub {
        my ($pubsub) = @_;
        ...
    },

Called after the listener has been re-established and every channel
re-subscribed. Read it as "you may have missed notifications", and resynchronise
if that matters to you.

=head3 heal_dead_connections

Replace a pooled connection that turns out to be dead before running the
caller's statement on it, instead of failing. On by default; set to 0 to have
the original error propagate untouched.

A connection can die while sitting idle in the pool, most often because the
server restarted or an administrator ended the session. The caller who is
handed it next has done nothing wrong, so the pool repairs itself rather than
reporting a fault of its own making.

The check runs once, before the first statement on a connection that came
from the idle list; a connection the pool just built cannot be stale, so
freshly created connections skip it. It costs nothing on the common path: a
healthy idle connection has nothing waiting to be read, so a non-blocking
check of the socket is enough to tell it apart from one whose server has
gone, which is readable because the peer's close is already sitting there. A
connection that looks wrong this way is confirmed dead with a ping before
being condemned, since a channel notification delivered to a pooled
connection would look the same and is not a fault. Only a connection
confirmed dead is replaced, and only before its statement is ever sent, so
nothing is retried and no statement can run twice. A statement inside a
transaction is never healed either: the transaction died with the connection,
and running the statement on a replacement would silently execute it outside
the transaction the caller asked for.

Finding a dead connection also discards the pool's other idle connections,
on the reasoning that whatever killed one has usually killed the rest. This
shows up as extra C<on_log> output and as jumps in the C<discarded> and
C<created> statistics. Connections that are currently checked out are left
alone.

Replacing a connection is reported through L</on_log>, so a database that is
flapping is visible rather than silently absorbed.

=head2 connection

    my $conn = await $pg->connection;

Get a connection from the pool. Returns a L<Async::DBD::Pg::Connection>.

=head2 query

    my $result = await $pg->query($sql);
    my $result = await $pg->query($sql, @bind);

Checks out a connection, runs one statement on it, and returns it -- whether
the statement succeeds, fails, or the caller cancels while it is in flight.
Arguments are passed straight through to
L<Async::DBD::Pg::Connection/query>, so the same placeholder forms, typed
binds and C<timeout> option all apply.

For several statements that need to share one connection, or a transaction,
see L</with_connection> and L</transaction>.

=head2 query_row

    my $row = await $pg->query_row($sql, @bind);

As L</query>, but returns the first row as a hashref rather than a result, or
C<undef> when nothing matched. Warns when more than one row matched.

See L<Async::DBD::Pg::Connection/query_row>, including what happens when the
query's column names repeat.

=head2 query_value

    my $value = await $pg->query_value($sql, @bind);

As L</query>, but returns the first column of the first row, or C<undef> when
nothing matched. Warns when more than one row matched.

See L<Async::DBD::Pg::Connection/query_value>.

=head2 query_list

    my ($id, $name) = await $pg->query_list($sql, @bind);

As L</query>, but returns the first row as a list of values in column order,
or an empty list when nothing matched. Warns when more than one row matched.

See L<Async::DBD::Pg::Connection/query_list>, including what scalar context
gives.

=head2 with_connection

    my $result = await $pg->with_connection(async sub {
        my ($conn, @args) = @_;
        await $conn->query(...);
        return await $conn->query(...);
    }, @args);

Checks out a connection, runs C<$code> with it, and returns it -- whether
C<$code> returns, dies, or the caller cancels while it is running. Whatever
C<$code> returns is returned. Arguments after C<$code> are forwarded to it as
C<< $code->($conn, @args) >>, letting a caller pass values in rather than
close over them.

Use this for a scope that needs several statements on the same connection --
a single statement can use L</query> instead, and does not need a callback at
all.

=head2 transaction

    my $result = await $pg->transaction($code, @args);
    my $result = await $pg->transaction({ isolation => 'serializable' }, $code, @args);

Checks out a connection and runs C<$code> inside a transaction on it,
returning the connection whether the transaction commits, rolls back, or the
caller cancels while it is in flight. Arguments are passed straight through to
L<Async::DBD::Pg::Connection/transaction>, so the leading-options form, the
argument forwarding, and savepoint nesting all apply.

=head2 idle_count, active_count, waiting_count, total_count

Pool statistics methods.

=head2 shutdown

    await $pg->shutdown;
    await $pg->shutdown(timeout => 30);
    await $pg->shutdown(force => 1);

Closes the pool. Connections sitting idle are closed at once, anyone queued
for a connection is failed with
L<Async::DBD::Pg::Error/Async::DBD::Pg::Error::PoolExhausted> rather than left
waiting for one that is not coming, the idle reaper is stopped, and the
pub/sub listener gives back the connection it was holding.

Connections still checked out are waited for, so their owners are not cut off
part way through a query. Once they are released they are closed rather than
returned to the pool.

Asking for a connection after this fails. Calling it more than once is
harmless.

=over 4

=item timeout

Seconds to wait for connections still in use before closing them anyway.
Without it the wait is indefinite, which is only safe if every connection is
certain to be released.

=item force

Close everything immediately, without waiting for connections in use. Their
owners will find the connection closed underneath them, so this is for
shutting down in a hurry rather than in an orderly way.

=back

Nothing obliges you to call this. A pool that simply goes out of scope closes
its connections too. It matters when the timing has to be yours: draining
before a deploy, releasing the listener connection deterministically, or
letting a process exit promptly rather than waiting on an idle timer.

=head2 is_shut_down

True once L</shutdown> has completed.

=head2 is_healthy

    $pg->is_healthy or warn "pool is saturated";

True when a caller would be handed a connection straight away: one is sitting
idle, or the pool is below C<max_connections> and can create another.

Note what this does I<not> mean. A pool whose connections are all busy at
C<max_connections> is working normally, but reports false, because the next
caller has to queue. Read it as available capacity rather than as the health
of the database. Wiring it directly to a load balancer's health check will
take a busy service out of rotation.

=head2 stats

Returns hashref of cumulative statistics (created, released, discarded, etc).

=head2 server_version

    if ($pg->server_version >= 150000) { ... }

The version of the server this pool is connected to, in PostgreSQL's own
integer form -- C<160014> for 16.0.14. A number rather than a string because
every use is a comparison, typically to gate a feature such as C<MERGE>.

Returns undef if the pool has no connection yet.

=head2 safe_dsn

The pool's DSN with the password replaced by C<***>, for logging.

=head1 PUB/SUB METHODS

=head2 pubsub

    my $pubsub = $pg->pubsub;

The pool's L<Async::DBD::Pg::PubSub>, created on first use. The same object is
returned every time, so subscriptions made through the pool and through this
object are the same set.

=head2 listen

    await $pg->listen($channel, sub { ... });

Subscribes to a channel. See L<Async::DBD::Pg::PubSub/listen>.

=head2 unlisten

    await $pg->unlisten($channel);

Unsubscribes. See L<Async::DBD::Pg::PubSub/unlisten>.

=head2 unlisten_all

    await $pg->unlisten_all;

Drops every subscription. See L<Async::DBD::Pg::PubSub/unlisten_all>.

=head2 notify

    await $pg->notify($channel, $payload);

Sends a notification. See L<Async::DBD::Pg::PubSub/notify>.

Each is shorthand for the same method on L</pubsub>, for applications that
never need the pub/sub object itself.

Listening holds one connection from the pool for as long as any channel is
subscribed, so allow for it in C<max_connections>.

=head1 SEE ALSO

L<Future::IO>, L<Future::AsyncAwait>, L<Async::DBD::Pg::Connection>, L<DBD::Pg>

=head1 AUTHOR

John Napiorkowski E<lt>jjn1056@yahoo.comE<gt>

=head1 LICENSE

Copyright (c) 2026 John Napiorkowski.

This library is free software; you may redistribute it and/or modify it under
the terms of the Artistic License 2.0. See the LICENSE file included with this
distribution for the full text.

=cut

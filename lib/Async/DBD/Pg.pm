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
use Async::DBD::Pg::Util qw(parse_dsn);
use IO::Socket;
use POSIX qw(dup);
use Scalar::Util qw(refaddr weaken);

# $VERSION is stamped into each package at build time by Dist::Zilla, so it
# is absent when running straight from a git checkout.

sub _version_gte {
    my ($got, $want) = @_;

    my @got = split /\./, ($got // 0);
    my @want = split /\./, ($want // 0);
    my $len = @got > @want ? scalar @got : scalar @want;

    for my $i (0 .. $len - 1) {
        my $g = $got[$i] // 0;
        my $w = $want[$i] // 0;
        return 1 if $g > $w;
        return 0 if $g < $w;
    }

    return 1;
}

# Check if we can do async connect
sub _supports_async_connect {
    my ($self) = @_;
    return $self->{_async_connect_supported} //= do {
        # Need DBD::Pg >= 3.19.0 for pg_async_connect
        my $v = $DBD::Pg::VERSION // 0;
        _version_gte($v, '3.19.0') ? 1 : 0;
    };
}

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

        # Callbacks
        on_connect => delete $args{on_connect},
        on_release => delete $args{on_release},
        on_log     => delete $args{on_log},

        # Pub/sub reconnect. Set on the pool because that is what an
        # application constructs; pubsub takes no arguments.
        reconnect              => delete $args{reconnect}              // 0,
        reconnect_min_interval => delete $args{reconnect_min_interval} // 0.5,
        reconnect_max_interval => delete $args{reconnect_max_interval} // 30,
        on_reconnect           => delete $args{on_reconnect},

        # Pool state
        idle    => [],
        active  => [],
        waiting => [],

        # Connections whose handshake is in progress. They are in neither the
        # idle nor the active list yet, so without counting them separately
        # concurrent callers all see room and all create one.
        _connecting => 0,
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
sub waiting_count   { scalar @{shift->{waiting}} }
sub total_count     { my $s = shift; scalar(@{$s->{idle}}) + scalar(@{$s->{active}}) }
sub stats           { shift->{stats} }
sub safe_dsn        { Async::DBD::Pg::Util::safe_dsn(shift->{dsn}) }

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
        my $drained = $self->{_drained} = Future->new;

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
    my $future = Future->new;
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

# Create a new connection (async if supported, blocking otherwise)
async sub _create_connection {
    my ($self) = @_;

    my $parsed = $self->{_parsed_dsn};
    my $use_async = $self->_supports_async_connect;

    my %attrs = (
        AutoCommit        => 1,
        RaiseError        => $use_async ? 0 : 1,
        PrintError        => 0,
        pg_enable_utf8    => 1,
        pg_server_prepare => 1,
    );

    # Use async connect if available
    $attrs{pg_async_connect} = 1 if $use_async;

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

    # Complete async handshake if using async connect
    if ($use_async) {
        await $self->_complete_async_connect($dbh);
        $dbh->{RaiseError} = 1;
    }

    # Set statement timeout if configured
    if (my $timeout = $self->{statement_timeout}) {
        $dbh->do("SET statement_timeout = '${timeout}s'");
    }

    my $conn = Async::DBD::Pg::Connection->new(
        dbh         => $dbh,
        pool        => $self,
        created_at  => time(),
        query_count => 0,
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
    $self->{stats}{discarded}++;
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

package Async::DBD::Pg;

1;

__END__

=head1 NAME

Async::DBD::Pg - Event-loop agnostic async PostgreSQL client

=head1 SYNOPSIS

    use Future::AsyncAwait;
    use Async::DBD::Pg;

    my $pg = Async::DBD::Pg->new(
        dsn             => 'postgresql://user:pass@host/db',
        min_connections => 2,
        max_connections => 10,
    );

    (async sub {
        my $conn = await $pg->connection;
        my $result = await $conn->query(
            'SELECT * FROM users WHERE id = :id', { id => 1 }
        );
        print $result->first->{name}, "\n";
        $conn->release;
    })->()->get;

=head1 DESCRIPTION

B<WARNING: This is extremely beta software.> The API is subject to change
without notice.

Async::DBD::Pg provides an async PostgreSQL client built on top of
L<DBD::Pg> and L<DBI>, with L<Future::IO> used as the event-loop
abstraction layer. Features include:

=over 4

=item * Connection pooling with automatic management

=item * Named and positional placeholders

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
release something — a connection slot, a statement handle, a paused listener —
and each relies on the cancellation reaching the operation actually being
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

Connection establishment is capability-dependent:

=over 4

=item *

With DBD::Pg 3.19.0+, connect is performed asynchronously using
C<pg_async_connect>, C<pg_continue_connect>, and L<Future::IO>'s official
C<poll> API.

=item *

Otherwise, the module falls back to ordinary synchronous C<DBI-E<gt>connect>
and still provides asynchronous query execution once connected.

=back

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

=head3 on_connect

    on_connect => async sub {
        my ($conn) = @_;
        await $conn->query("SET application_name = 'my app'");
    },

Called with each newly established connection before it is handed to anyone,
which is where session settings belong: C<search_path>, timezone, or the
DBD::Pg attributes this module does not wrap. A callback that dies discards
the connection and the failure reaches the caller who asked for it.

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

=head2 connection

    my $conn = await $pg->connection;

Get a connection from the pool. Returns a L<Async::DBD::Pg::Connection>.

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

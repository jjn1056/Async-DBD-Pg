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
use Scalar::Util qw(weaken);

our $VERSION = '0.001001';

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

sub is_healthy {
    my ($self) = @_;

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
        $self->{_connecting}++;

        my $conn = eval { await $self->_create_connection };
        my $err = $@;

        $self->{_connecting}--;
        die $err if $err;

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
        if ($@) {
            $self->_log(warn => "on_connect failed: $@");
            $conn->_close_dbh;
            $self->{stats}{connect_failures}++;
            die $@;
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
    my ($self, $conn) = @_;

    # Remove from active list
    @{$self->{active}} = grep { $_ != $conn } @{$self->{active}};

    # Check if connection is still valid
    if (!$conn->{dbh} || !$conn->{dbh}->ping) {
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
    $cleanup->()->retain;
}

sub _release_to_idle_or_waiting {
    my ($self, $conn) = @_;

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

    # Create connections in parallel (fire and forget)
    for (1 .. $needed) {
        my $f = $self->_create_connection;
        $f->on_done(sub {
            my ($conn) = @_;
            push @{$self->{idle}}, $conn;
        });
        $f->on_fail(sub {
            my ($err) = @_;
            $self->_log(warn => "Failed to create initial connection: $err");
        });
        $f->retain;
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

=head3 idle_timeout

Seconds a connection may sit idle before it is closed and dropped from the
pool. Defaults to 300. Pass 0 to keep idle connections open indefinitely.

C<min_connections> is a floor that reaping respects, so a pool configured to
keep connections will keep them however long they stay idle. Connections
currently in use count towards that floor.

Reaping is driven by a timer that exists only while there are connections old
enough to be worth closing, so a pool resting at C<min_connections> does not
hold the event loop open on its own.

=head2 connection

    my $conn = await $pg->connection;

Get a connection from the pool. Returns a L<Async::DBD::Pg::Connection>.

=head2 idle_count, active_count, waiting_count, total_count

Pool statistics methods.

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

=head1 SEE ALSO

L<Future::IO>, L<Future::AsyncAwait>, L<Async::DBD::Pg::Connection>, L<DBD::Pg>

=head1 AUTHOR

John Napiorkowski E<lt>jjn1056@yahoo.comE<gt>

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

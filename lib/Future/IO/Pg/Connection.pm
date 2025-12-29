package Future::IO::Pg::Connection;

use strict;
use warnings;

use Future;
use Future::AsyncAwait;
use Future::IO;
use IO::Socket;
use Socket qw(MSG_PEEK);
use DBD::Pg qw(:async);
use POSIX qw(dup);

use Future::IO::Pg::Cursor;
use Future::IO::Pg::Error;
use Future::IO::Pg::Results;
use Future::IO::Pg::Util qw(convert_placeholders);

sub new {
    my ($class, %args) = @_;
    return bless {
        dbh             => $args{dbh},
        pool            => $args{pool},
        created_at      => $args{created_at} // time(),
        query_count     => $args{query_count} // 0,
        last_used       => time(),
        released        => 0,
        in_transaction  => 0,
        _savepoint_depth => 0,
    }, $class;
}

# Accessors
sub dbh            { shift->{dbh} }
sub pool           { shift->{pool} }
sub last_used      { shift->{last_used} }
sub query_count    { shift->{query_count} }
sub created_at     { shift->{created_at} }
sub in_transaction { shift->{in_transaction} }
sub is_released    { shift->{released} }

# Execute a query asynchronously
async sub query {
    my ($self, $sql, @args) = @_;

    my ($bind, $opts) = $self->_parse_query_args(@args);

    if (ref $bind eq 'HASH') {
        ($sql, $bind) = convert_placeholders($sql, $bind);
    }

    $self->{query_count}++;
    $self->{last_used} = time();

    my $result;
    if (my $timeout = $opts->{timeout}) {
        $result = await $self->_query_with_timeout($sql, $bind, $timeout);
    }
    else {
        $result = await $self->_execute_async($sql, $bind);
    }

    return $result;
}

sub _parse_query_args {
    my ($self, @args) = @_;

    my $opts = {};
    my $bind = [];

    if (@args && ref $args[-1] eq 'HASH') {
        my $last = $args[-1];
        if (exists $last->{timeout}) {
            $opts = pop @args;
        }
    }

    if (@args == 1 && ref $args[0] eq 'HASH') {
        $bind = $args[0];
    }
    elsif (@args) {
        $bind = \@args;
    }

    return ($bind, $opts);
}

# Execute async query with timeout
async sub _query_with_timeout {
    my ($self, $sql, $bind, $timeout) = @_;

    my $query_future = $self->_execute_async($sql, $bind);
    my $timer = Future::IO->sleep($timeout);

    my $winner = await Future->wait_any($query_future, $timer);

    if ($winner == $timer) {
        $self->cancel;
        eval { await $query_future };

        die Future::IO::Pg::Error::Timeout->new(
            message => "Query timeout after ${timeout}s",
            timeout => $timeout,
        );
    }

    return $winner->get;
}

# Core async query execution using DBD::Pg async support
async sub _execute_async {
    my ($self, $sql, $bind) = @_;
    $bind //= [];

    my $dbh = $self->{dbh};

    my $sth = eval { $dbh->prepare($sql, { pg_async => PG_ASYNC }) };
    if ($@ || !$sth) {
        $self->_throw_query_error($@ || $dbh->errstr, $sql);
    }

    my $rv = eval {
        if (ref $bind eq 'ARRAY' && @$bind) {
            $sth->execute(@$bind);
        }
        else {
            $sth->execute;
        }
    };

    if ($@ || !defined $rv) {
        $self->_throw_query_error($@ || $sth->errstr || $dbh->errstr, $sql);
    }

    # Wait for async result using Future::IO
    await $self->_wait_for_result($dbh);

    my $result = eval { $dbh->pg_result };
    if ($@ || !$result) {
        $self->_throw_query_error($@ || $dbh->errstr, $sql);
    }

    return Future::IO::Pg::Results->new($sth);
}

# Check if Future::IO impl supports ready_for_read (more efficient)
sub _has_ready_for_read {
    my $impl = $Future::IO::IMPL;
    return $impl && $impl->can('ready_for_read');
}

# Get or create cached socket wrapper for async I/O
sub _get_socket {
    my ($self) = @_;

    my $socket_fd = $self->{dbh}{pg_socket};
    die "No PostgreSQL socket" unless defined $socket_fd;

    # Return cached socket if fd hasn't changed
    if ($self->{_cached_sock} && $self->{_cached_fd} == $socket_fd) {
        return $self->{_cached_sock};
    }

    # dup() the fd to avoid fdopen taking ownership of the original
    my $dup_fd = dup($socket_fd);
    die "Cannot dup pg_socket: $!" unless defined $dup_fd;

    # Wrap the duped fd in an IO::Socket for Future::IO
    my $sock = IO::Socket->new;
    unless ($sock->fdopen($dup_fd, "r+")) {
        POSIX::close($dup_fd);
        die "Cannot fdopen pg_socket: $!";
    }

    # Cache for reuse
    $self->{_cached_sock} = $sock;
    $self->{_cached_fd} = $socket_fd;

    return $sock;
}

# Wait for PostgreSQL socket to be readable using Future::IO
async sub _wait_for_result {
    my ($self, $dbh) = @_;

    my $sock = $self->_get_socket;

    # Use ready_for_read if available (more efficient, no data peek)
    if (_has_ready_for_read()) {
        my $impl = $Future::IO::IMPL;
        while (!$dbh->pg_ready) {
            await $impl->ready_for_read($sock);
        }
    }
    else {
        # Fallback: recv with MSG_PEEK to wait for readability
        while (!$dbh->pg_ready) {
            await Future::IO->recv($sock, 1, MSG_PEEK);
        }
    }
}

# Cancel current query
sub cancel {
    my ($self) = @_;
    eval { $self->{dbh}->pg_cancel };
}

# Execute code within a transaction
async sub transaction {
    my ($self, $code, %opts) = @_;

    my $isolation = $opts{isolation};
    my $savepoint_depth = $self->{_savepoint_depth} // 0;

    if ($savepoint_depth > 0) {
        my $savepoint = "sp_$savepoint_depth";
        await $self->query("SAVEPOINT $savepoint");

        $self->{_savepoint_depth} = $savepoint_depth + 1;

        my $result = eval { await $code->($self) };
        my $err = $@;

        $self->{_savepoint_depth} = $savepoint_depth;

        if ($err) {
            await $self->query("ROLLBACK TO SAVEPOINT $savepoint");
            die $err;
        }

        await $self->query("RELEASE SAVEPOINT $savepoint");
        return $result;
    }
    else {
        my $begin = 'BEGIN';
        if ($isolation) {
            my $level = uc($isolation);
            $level =~ s/_/ /g;
            $begin .= " ISOLATION LEVEL $level";
        }
        await $self->query($begin);
        $self->{in_transaction} = 1;

        $self->{_savepoint_depth} = 1;

        my $result = eval { await $code->($self) };
        my $err = $@;

        $self->{_savepoint_depth} = 0;

        if ($err) {
            eval { await $self->query('ROLLBACK') };
            $self->{in_transaction} = 0;
            die $err;
        }

        await $self->query('COMMIT');
        $self->{in_transaction} = 0;
        return $result;
    }
}

# Create a streaming cursor for large result sets
async sub cursor {
    my ($self, $sql, @args) = @_;

    my ($bind, $opts) = $self->_parse_cursor_args(@args);

    if (ref $bind eq 'HASH') {
        ($sql, $bind) = convert_placeholders($sql, $bind);
    }

    my $batch_size = delete $opts->{batch_size} // 1000;
    my $cursor_name = delete $opts->{name} // Future::IO::Pg::Cursor::_generate_name();

    my $was_in_transaction = $self->{in_transaction};
    if (!$was_in_transaction) {
        await $self->query('BEGIN');
        $self->{in_transaction} = 1;
    }

    my $declare_sql = "DECLARE $cursor_name CURSOR FOR $sql";

    if (ref $bind eq 'ARRAY' && @$bind) {
        await $self->query($declare_sql, @$bind);
    }
    else {
        await $self->query($declare_sql);
    }

    my $cursor = Future::IO::Pg::Cursor->new(
        name       => $cursor_name,
        batch_size => $batch_size,
        conn       => $self,
        _owns_transaction => !$was_in_transaction,
    );

    return $cursor;
}

sub _parse_cursor_args {
    my ($self, @args) = @_;

    my $opts = {};
    my $bind = [];

    if (@args && ref $args[-1] eq 'HASH') {
        my $last = $args[-1];
        if (exists $last->{batch_size} || exists $last->{name}) {
            $opts = pop @args;
        }
    }

    if (@args == 1 && ref $args[0] eq 'HASH') {
        $bind = $args[0];
    }
    elsif (@args) {
        $bind = \@args;
    }

    return ($bind, $opts);
}

# Release connection back to pool
sub release {
    my ($self) = @_;
    return if $self->{released};
    $self->{released} = 1;

    if (my $pool = $self->{pool}) {
        $pool->_return_connection($self);
    }
}

sub _close_dbh {
    my ($self) = @_;
    if ($self->{dbh}) {
        eval { $self->{dbh}->disconnect };
        $self->{dbh} = undef;
    }
}

sub DESTROY {
    my ($self) = @_;
    return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
    $self->release unless $self->{released};
    $self->_close_dbh;
}

sub _throw_query_error {
    my ($self, $err, $sql) = @_;

    my $dbh = $self->{dbh};
    my $state = eval { $dbh->state } // '';

    die Future::IO::Pg::Error::Query->new(
        message    => $err,
        code       => $state,
        detail     => eval { $dbh->pg_errorlevel } // undef,
        constraint => undef,
        hint       => undef,
        position   => undef,
    );
}

1;

__END__

=head1 NAME

Future::IO::Pg::Connection - Async PostgreSQL connection using Future::IO

=head1 SYNOPSIS

    my $conn = await $pg->connection;

    # Positional placeholders
    my $r = await $conn->query('SELECT * FROM users WHERE id = $1', $id);

    # Named placeholders
    my $r = await $conn->query(
        'SELECT * FROM users WHERE name = :name',
        { name => 'Alice' }
    );

    $conn->release;

=head1 DESCRIPTION

This module provides an async PostgreSQL connection that works with any
Future::IO implementation (IO::Async, libuv, GLib, etc.).

=head1 AUTHOR

John Napiorkowski E<lt>jjn1056@yahoo.comE<gt>

=cut

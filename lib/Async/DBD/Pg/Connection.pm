package Async::DBD::Pg::Connection;

use strict;
use warnings;

use Future;
use Future::AsyncAwait;
use Future::IO qw(POLLIN);
use IO::Socket;
use DBD::Pg qw(:async);
use POSIX qw(dup);
use Scalar::Util qw(weaken);

use Async::DBD::Pg::Cursor;
use Async::DBD::Pg::Error;
use Async::DBD::Pg::Results;
use Async::DBD::Pg::Util qw(convert_placeholders);

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        dbh             => $args{dbh},
        pool            => $args{pool},
        created_at      => $args{created_at} // time(),
        query_count     => $args{query_count} // 0,
        last_used       => time(),
        released        => 0,
        in_transaction  => 0,
        _savepoint_depth => 0,
    }, $class;

    weaken($self->{pool}) if $self->{pool};

    return $self;
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

    # wait_any yields the result of whichever future won rather than the
    # winning future, so the outcome has to be read back from the futures
    # themselves. It also cancels the loser, and a cancelled future reports
    # is_ready, so completion is tested with is_done.
    eval { await Future->wait_any($query_future, $timer); 1 };
    my $failure = $@;

    $timer->cancel unless $timer->is_ready;

    return $query_future->get if $query_future->is_done;

    # The query lost the race. Stop it server side so the backend is not left
    # working on a result nobody is waiting for.
    if (!$query_future->is_failed) {
        $self->cancel;

        die Async::DBD::Pg::Error::Timeout->new(
            message => "Query timeout after ${timeout}s",
            timeout => $timeout,
        );
    }

    die $failure;
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

    # Hold the in-flight handle on the connection. A query that is abandoned
    # part way through, by a timeout for instance, has its async sub torn
    # down along with the lexicals inside it, and DBI warns when a statement
    # handle is collected while still active. Keeping a reference here lets
    # cancel release the handle deliberately.
    $self->{_active_sth} = $sth;

    my $rv = eval {
        if (ref $bind eq 'ARRAY' && @$bind) {
            $sth->execute(@$bind);
        }
        else {
            $sth->execute;
        }
    };

    if ($@ || !defined $rv) {
        my $err = $@ || $sth->errstr || $dbh->errstr;
        $self->_release_active_sth;
        $self->_throw_query_error($err, $sql);
    }

    # Wait for async result using Future::IO
    await $self->_wait_for_result($dbh);

    my $result = eval { $dbh->pg_result };
    if ($@ || !$result) {
        my $err = $@ || $dbh->errstr;
        $self->_release_active_sth;
        $self->_throw_query_error($err, $sql);
    }

    # Results takes over the handle and finishes it.
    delete $self->{_active_sth};

    return Async::DBD::Pg::Results->new($sth);
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

# Wait for PostgreSQL socket to be readable using Future::IO's official poll API
async sub _wait_for_result {
    my ($self, $dbh) = @_;

    my $sock = $self->_get_socket;

    while (!$dbh->pg_ready) {
        await Future::IO->poll($sock, POLLIN);
    }
}

# Release the statement handle of a query that will not be read
sub _release_active_sth {
    my ($self) = @_;

    my $sth = delete $self->{_active_sth} or return;
    eval { $sth->finish };
}

# Cancel current query
sub cancel {
    my ($self) = @_;
    eval { $self->{dbh}->pg_cancel };
    $self->_release_active_sth;
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

    # Both are interpolated into the statements below, so they are checked
    # before any SQL is built rather than after the DECLARE has run.
    my $batch_size = Async::DBD::Pg::Cursor::_validate_batch_size(
        delete $opts->{batch_size} // 1000
    );
    my $cursor_name = Async::DBD::Pg::Cursor::_validate_name(
        delete $opts->{name} // Async::DBD::Pg::Cursor::_generate_name()
    );

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

    my $cursor = Async::DBD::Pg::Cursor->new(
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
    if (!$self->{released} && $self->{pool}) {
        $self->release;
        return;
    }
    $self->_close_dbh;
}

sub _throw_query_error {
    my ($self, $err, $sql) = @_;

    my $dbh = $self->{dbh};
    my $state = eval { $dbh->state } // '';

    die Async::DBD::Pg::Error::Query->new(
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

Async::DBD::Pg::Connection - Async PostgreSQL connection using Future::IO

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

This module provides a DBD::Pg-backed async PostgreSQL connection that works
with any Future::IO implementation (IO::Async, libuv, GLib, etc.).

=head1 ACCESSORS

=head2 dbh

Returns the underlying DBI handle. This is an advanced escape hatch for
DBD::Pg-specific use and is not coordinated with the wrapper's async query
lifecycle.

=head1 AUTHOR

John Napiorkowski E<lt>jjn1056@yahoo.comE<gt>

=cut

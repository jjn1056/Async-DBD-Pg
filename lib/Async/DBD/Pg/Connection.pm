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

    # Once per checkout, and only for a connection that was idle.
    if (delete $self->{_check_liveness}) {
        await $self->_heal_if_dead;
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

# Replace this connection if it died while it was sitting idle. Called before
# the first statement after checkout, never after a failure: a statement on a
# dead connection succeeds at prepare and at execute and only fails at
# pg_result, by which point it may already have run and nothing about it can
# safely be repeated.
async sub _heal_if_dead {
    my ($self) = @_;

    my $pool = $self->{pool} or return 0;

    return 0 unless $pool->{heal_dead_connections};
    return 0 if $pool->{_shutting_down};

    # The transaction died with the connection. Continuing on a replacement
    # would run the caller's statements outside the transaction they asked
    # for, which is worse than the failure.
    return 0 if $self->{in_transaction};

    my $dbh = $self->{dbh} or return 0;

    # Free, and no round trip: a healthy idle connection has nothing waiting
    # to be read, while one whose server has gone is readable because the
    # peer's close is sitting there. DBI's own Active flag stays true on a
    # dead connection and is no help.
    my $fd = $dbh->{pg_socket};
    return 0 unless defined $fd && $fd >= 0;

    my $rin = '';
    vec($rin, $fd, 1) = 1;

    # select's error return is -1 (e.g. on EINTR), which is true in boolean
    # context; checked as a number instead so an interrupted call falls
    # through to the round trip below rather than being read as "readable".
    # Getting this wrong doesn't change the outcome -- a healthy connection's
    # ping still succeeds and the heal is still skipped -- it just costs one
    # avoidable round trip on an already-uncommon path.
    my $ready = select(my $rout = $rin, undef, undef, 0);
    return 0 unless defined $ready && $ready > 0;

    # Readable is suggestive, not conclusive: an asynchronous notification
    # would look the same if an application ran LISTEN on a pooled
    # connection. Confirm before throwing the connection away. This round
    # trip happens only when something already looks wrong.
    return 0 if $dbh->ping;

    $pool->_log(warn => 'replacing a pooled connection that was already dead');

    await $pool->_replace_dbh($self);

    # Whatever killed this one has usually killed the rest.
    my $dropped = $pool->_discard_idle_connections;
    $pool->_log(warn => "discarded $dropped idle connection(s) after finding one dead")
        if $dropped;

    return 1;
}

# Route a PostgreSQL NOTICE (or any other warning DBI's PrintWarn would
# otherwise print straight to fd 2) through the pool's own logging. DBD::Pg
# raises it as an ordinary Perl warning while reading from the socket, and
# measurement is what says where: under pg_async, a statement's own notice
# surfaces during the pg_ready poll in _wait_for_result, not during execute
# or pg_result, because execute only dispatches and returns without waiting.
# All three are wrapped anyway -- it costs nothing on a call that raises
# nothing, and it stops the interception being tied to which phase a notice
# happens to arrive in today. prepare is not wrapped; it never touches the
# network under pg_async.
#
# $SIG{__WARN__} is global, so it is localised strictly around the one
# synchronous call it wraps, never across an await: a local unwinds with its
# frame, and a caller can cancel while a sub is suspended, running nothing
# after that point. That also rules out a guard object living for the whole
# query -- its constructor/DESTROY pair would be a global assignment held
# across every await the query makes, and two connections' queries running
# concurrently would have one's DESTROY clobber the other's still-active
# handler. A local avoids that by construction: its scope is one synchronous
# call, and only one call is ever running at a time in a single-threaded
# event loop. Wrapping the call sites individually with this rather than
# duplicating the handler at each one keeps it in one place.
sub _capture_pg_notices {
    my ($self, $code) = @_;

    my $pool = $self->{pool};

    # No pool to log through. Leaving $SIG{__WARN__} untouched lets the
    # notice behave exactly as it would without this wrapper -- printed, or
    # caught by whatever handler is already in effect -- which is re-raising
    # it rather than swallowing it.
    return $code->() unless $pool;

    # _log's own fallback, when no on_log is configured, is itself a warn()
    # call. It does not re-enter this handler: Perl does not deliver
    # $SIG{__WARN__} recursively to the handler currently running, so a
    # warn() from inside this one uses the true default (print to stderr)
    # on its own, with nothing extra needed here to arrange that. The same
    # non-re-entrance is what lets the passed-through branch below just
    # warn() rather than needing to juggle the handler itself.
    local $SIG{__WARN__} = sub {
        my ($message) = @_;

        # Only a PostgreSQL server message is downgraded to an info-level
        # log line. Anything else raised during one of these calls -- a DBI
        # handle-lifecycle warning, say -- is a real problem, not chatter,
        # and is passed through as an ordinary warning rather than relabeled
        # and mixed in with NOTICE text.
        unless ($message =~ /^(?:NOTICE|WARNING|INFO|LOG|DEBUG):/) {
            warn $message;
            return;
        }

        $message =~ s/\n\z//;
        $pool->_log(info => $message);
    };

    return $code->();
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

    # Hold the in-flight handle on the connection. A query abandoned part way
    # through has its async sub torn down along with the lexicals inside it,
    # and DBI warns when a statement handle is collected while still active.
    #
    # A guard rather than a release at the end, because a caller cancelling
    # the query stops this sub where it is suspended and nothing after the
    # await runs.
    my $statement = Async::DBD::Pg::Connection::_StatementGuard->new($self, $sth);

    my $rv = eval {
        $self->_capture_pg_notices(sub {
            if (ref $bind eq 'ARRAY' && @$bind) {
                $sth->execute(@$bind);
            }
            else {
                $sth->execute;
            }
        });
    };

    if ($@ || !defined $rv) {
        my $err = $@ || $sth->errstr || $dbh->errstr;
        $statement->release;
        $self->_throw_query_error($err, $sql);
    }

    # Wait for async result using Future::IO
    await $self->_wait_for_result($dbh);

    my $result = eval { $self->_capture_pg_notices(sub { $dbh->pg_result }) };
    if ($@ || !$result) {
        my $err = $@ || $dbh->errstr;
        $statement->release;
        $self->_throw_query_error($err, $sql);
    }

    # Results takes over the handle and finishes it.
    $statement->hand_over;

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

    # A statement's own NOTICE is delivered here, while pg_ready reads the
    # socket -- see _capture_pg_notices. The wrap is per iteration, around
    # only the synchronous pg_ready call, never across the await below.
    while (!$self->_capture_pg_notices(sub { $dbh->pg_ready })) {
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
    my ($self, %opts) = @_;
    return if $self->{released};
    $self->{released} = 1;

    if (my $pool = $self->{pool}) {
        $pool->_return_connection($self, %opts);
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
        # Returning to the pool normally checks the connection with a ping,
        # which is a round trip to the server. Destruction can happen while
        # the event loop is being torn down, where a blocking call may stall
        # the reactor or re-enter async code, so the check is skipped here.
        $self->release(validate => 0);
        return;
    }
    $self->_close_dbh;
}

sub _throw_query_error {
    my ($self, $err, $sql) = @_;

    my $dbh = $self->{dbh};

    # pg_error_field describes the most recent error and is reset by the next
    # statement sent on this handle, so every field is collected here before
    # anything else runs. Previously detail was read from pg_errorlevel, which
    # is the verbosity setting rather than any part of the error.
    my %diag;
    for my $field (qw(severity detail hint constraint schema table column context)) {
        $diag{$field} = eval { $dbh->pg_error_field($field) };
    }

    my $position = eval { $dbh->pg_error_field('statement_position') };
    my $state    = eval { $dbh->pg_error_field('state') } || eval { $dbh->state } || '';

    die Async::DBD::Pg::Error::Query->new(
        message    => $err,
        code       => $state,
        detail     => $diag{detail},
        hint       => $diag{hint},
        constraint => $diag{constraint},
        position   => $position,
        severity   => $diag{severity},
        schema     => $diag{schema},
        table      => $diag{table},
        column     => $diag{column},
        context    => $diag{context},
    );
}

package Async::DBD::Pg::Connection::_StatementGuard;

# Keeps the connection's reference to an in-flight statement handle, and
# finishes that handle unless the result was handed to a Results object.
# Releasing from a destructor covers the case the code cannot: a caller
# cancelling the query while it is suspended awaiting the server.

use strict;
use warnings;
use Scalar::Util qw(weaken);

sub new {
    my ($class, $conn, $sth) = @_;

    $conn->{_active_sth} = $sth;

    my $self = bless { conn => $conn }, $class;
    weaken($self->{conn});

    return $self;
}

# The statement is finished with and nobody is going to read it.
sub release {
    my ($self) = @_;

    my $conn = delete $self->{conn} or return;
    $conn->_release_active_sth;
}

# Ownership passes to the caller, who finishes the handle instead.
sub hand_over {
    my ($self) = @_;

    my $conn = delete $self->{conn} or return;
    delete $conn->{_active_sth};
}

sub DESTROY {
    my ($self) = @_;

    return if ${^GLOBAL_PHASE} eq 'DESTRUCT';

    my $conn = $self->{conn} or return;

    # Reaching the destructor with the statement still held means the query
    # was abandoned rather than read. The server is still working on a result
    # nobody wants, and the handle cannot be finished cleanly until it stops,
    # so cancel first and then release.
    $conn->cancel;

    $self->release;
}

package Async::DBD::Pg::Connection;

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

A connection carries out one statement at a time. Running two queries on the
same connection concurrently is not supported; take a second connection from
the pool instead.

=head1 METHODS

=head2 query

    my $r = await $conn->query($sql);
    my $r = await $conn->query($sql, @bind);
    my $r = await $conn->query($sql, \%params);
    my $r = await $conn->query($sql, @bind, { timeout => 5 });

Runs a statement and returns an L<Async::DBD::Pg::Results>.

Placeholders come in two forms. PostgreSQL's own C<$1>, C<$2> take their
values from the remaining positional arguments. Named C<:name> placeholders
take theirs from a hashref, and are rewritten to positional form before the
statement is sent; naming a placeholder with no matching key is an error
rather than something passed through to the server. The two forms cannot be
mixed in one statement.

A trailing hashref containing C<timeout> is read as options rather than as
named parameters:

=over 4

=item timeout

Seconds to allow before giving up. On expiry the query is cancelled on the
server and an L<Async::DBD::Pg::Error/Async::DBD::Pg::Error::Timeout> is
thrown. Without it a query waits as long as the server takes.

=back

Fails with an L<Async::DBD::Pg::Error/Async::DBD::Pg::Error::Query> carrying
the SQLSTATE and the diagnostics the server returned.

=head2 transaction

    my $result = await $conn->transaction(async sub {
        my ($conn) = @_;
        await $conn->query(...);
        return $value;
    });

    await $conn->transaction($code, isolation => 'serializable');

Runs C<$code> inside a transaction, committing when it returns and rolling
back if it dies, then rethrowing. Whatever C<$code> returns is returned.

Nested calls use savepoints: an inner block that dies rolls back to its
savepoint and leaves the outer transaction to continue, so failure can be
handled without discarding work already done.

=over 4

=item isolation

Isolation level for the outermost transaction, such as C<read_committed>,
C<repeatable_read> or C<serializable>. Underscores become spaces, so
C<repeatable_read> becomes C<REPEATABLE READ>. Ignored for nested blocks,
which join the transaction already running.

=back

=head2 cursor

    my $cursor = await $conn->cursor($sql, @bind, { batch_size => 500 });

Returns an L<Async::DBD::Pg::Cursor> for walking a result set in batches
rather than holding it in memory. Accepts the same placeholder forms as
L</query>.

A transaction is started if one is not already running, since a cursor lives
only as long as its transaction.

=over 4

=item batch_size

Rows fetched per round trip. Defaults to 1000. Must be a positive integer.

=item name

Name for the cursor. Defaults to a generated one. Must be a plain identifier
of at most 63 characters; a cursor name cannot be sent as a bind parameter, so
anything else is refused.

=back

Close the cursor when finished. A cursor left to be garbage collected warns,
and holds its transaction open until the connection is released.

=head2 cancel

    $conn->cancel;

Asks the server to abandon the statement in progress and releases the
statement handle. Used by the C<timeout> option.

=head2 release

    $conn->release;

Returns the connection to the pool. An open transaction is rolled back first,
so no state carries over to whoever takes it next. The connection must not be
used afterwards.

Releasing is not optional: a connection that is never released is never
available to anyone else.

=head1 ACCESSORS

=head2 dbh

Returns the underlying DBI handle. This is an advanced escape hatch for
DBD::Pg-specific use and is not coordinated with the wrapper's async query
lifecycle.

=head2 in_transaction

True while a transaction is open on this connection.

=head2 is_released

True once the connection has gone back to the pool.

=head2 query_count

Number of statements run on this connection, which the pool compares against
C<max_queries>.

=head2 created_at

Epoch time at which the connection was established.

=head2 last_used

Epoch time at which the connection was last used. The pool compares this
against C<idle_timeout> when reaping.

=head2 pool

The pool this connection came from.

=head1 AUTHOR

John Napiorkowski E<lt>jjn1056@yahoo.comE<gt>

=cut

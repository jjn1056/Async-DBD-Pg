package Async::DBD::Pg::Connection;

use strict;
use warnings;

use Carp qw(carp croak);
use Future;
use Future::AsyncAwait;
use Future::IO qw(POLLIN);
use IO::Socket;
use DBD::Pg qw(:async);
use POSIX qw(dup);
use Scalar::Util qw(weaken);
use Time::HiRes ();

use Async::DBD::Pg::Cursor;
use Async::DBD::Pg::Error;
use Async::DBD::Pg::Results;
use Async::DBD::Pg::Util qw(convert_placeholders);

# name => OID for a bind that names its PostgreSQL type, derived from
# DBD::Pg's own :pg_types exports rather than a table maintained here:
# PG_BYTEA becomes 'bytea'. That is by construction exactly the set
# bind_param accepts, which resolving through PostgreSQL is not -- to_regtype
# happily returns the OID of a user-defined enum, and bind_param then refuses
# it with "Cannot bind 1 unknown pg_type 65025".
#
# Such a type does not need a typed bind in any case: it is text on the wire.
# The types that need one -- bytea above all, whose text form truncates at the
# first NUL -- are exactly the ones DBD::Pg knows.
#
# 29 of these are pseudo-types (any, internal, record, trigger, void) that
# bind_param refuses. They are left in rather than filtered by a list that
# would rot against DBD::Pg's next release; nobody binds them.
#
# 'char' follows DBD::Pg's PG_CHAR, the internal single-byte type (18), not
# SQL CHAR(n), which is 'bpchar' (1042).
my %TYPE_OID = do {
    no strict 'refs';
    map  { ( lc(substr $_, 3) => &{"DBD::Pg::$_"}() ) }
    grep { /\APG_./ }
    @{ $DBD::Pg::EXPORT_TAGS{pg_types} || [] };
};

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

        # Statement cache. Keyed on the converted SQL, so the :name and $1
        # spellings of one query share an entry. Lives here rather than
        # anywhere more general because only the connection sees the
        # statement guard's exits, which is what says whether a handle is
        # still fit to reuse.
        statement_cache_size => $args{statement_cache_size} // 0,
        _stmt_cache          => {},
        _stmt_lru            => [],
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
        my ($converted, $named) = convert_placeholders($sql, $bind);

        if (@$named || $converted ne $sql) {
            ($sql, $bind) = ($converted, $named);
        }
        else {
            # No :name placeholders in the statement, so this hashref cannot
            # be a map of named binds -- it is a single positional value,
            # which is how a lone typed parameter arrives. Deciding from the
            # SQL rather than from the hash's keys is what lets a genuine
            # named-bind hash for :type and :value keep working.
            $bind = [$bind];
        }
    }

    # Synchronous: the map is built at load time, so this costs no round trip
    # and needs no await.
    $bind = $self->_resolve_bind_types($bind);

    # Once per checkout, and only for a connection that was idle.
    if (delete $self->{_check_liveness}) {
        await $self->_heal_if_dead;
    }

    $self->{query_count}++;
    $self->{last_used} = time();

    # Monotonic, so a clock adjustment mid-query cannot produce a negative or
    # wildly wrong duration. Captured here rather than reconstructed later,
    # for the same reason the column types are: afterwards it is gone.
    my $started = _now();

    my $result = eval {
        $opts->{timeout}
            ? await $self->_query_with_timeout($sql, $bind, $opts->{timeout})
            : await $self->_execute_async($sql, $bind);
    };
    my $error = $@;

    my $elapsed = _now() - $started;

    if ($error) {
        $self->_report_query($sql, $bind, $elapsed, undef, $error);
        die $error;
    }

    $result->_record_elapsed($elapsed);
    $self->_report_query($sql, $bind, $elapsed, $result->count, undef);

    return $result;
}

# One hook, deliberately: slow-query logging, tracing, metrics and the test
# assertion "this path ran two queries" are all this shape, and none of them
# needs an event system to sit on.
sub _report_query {
    my ($self, $sql, $bind, $elapsed, $rows, $error) = @_;

    my $pool = $self->{pool} or return;
    my $hook = $pool->{on_query} or return;

    # A handler that dies must not turn a working query into a failed one,
    # nor mask the error a failing one is already carrying.
    eval {
        $hook->({
            sql     => $sql,
            binds   => $bind,
            elapsed => $elapsed,
            rows    => $rows,
            error   => $error,
            cached  => $self->{_last_was_cached} ? 1 : 0,
        });
        1;
    } or $pool->_log(warn => "on_query handler failed: $@");

    return;
}

sub _now {
    return Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC())
        if defined &Time::HiRes::CLOCK_MONOTONIC;

    return Time::HiRes::time();
}

# One row, or undef. The pair with query_value below covers the two shapes
# almost every query has: give me the row I identified, give me the value I
# counted. asyncpg spells them fetchrow and fetchval.
async sub query_row {
    my ($self, @args) = @_;

    my $result = await $self->query(@args);

    if (my ($name, $at) = $result->_repeated_column) {
        # query_row takes a bind list and has nowhere to put an option, so
        # the way out is one tier down rather than an argument here.
        croak sprintf(
            "Column '%s' appears %d times at positions %s in query_row; "
          . 'alias the columns, or use query(...)->single (optionally with ->as)',
            $name, scalar @$at, join(', ', @$at),
        );
    }

    _warn_if_several($result, 'query_row');

    return $result->first;
}

# The first column of the first row, or undef. Positional throughout, so a
# repeated column name cannot stop it -- which is what makes it the answer
# query_row's croak sends people to.
async sub query_value {
    my ($self, @args) = @_;

    my $result = await $self->query(@args);

    _warn_if_several($result, 'query_value');

    my $row = $result->row_array(0) or return undef;

    return $row->[0];
}

# One row as a list of values, for the idiom this is named after:
#
#     my ($id, $name) = await $conn->query_list($sql, @bind);
#
# The future completes with the list, so awaiting it in list context yields
# every column. An async sub cannot see its caller's context -- wantarray in
# the body reports whatever the machinery set, not what the call site wants
# -- so unlike Results::first_list this cannot hand back an arrayref instead.
# Awaited in scalar context it yields the first value, the same as
# query_value would.
async sub query_list {
    my ($self, @args) = @_;

    my $result = await $self->query(@args);

    _warn_if_several($result, 'query_list');

    # return evaluates its expression in list context inside an async sub,
    # which is what puts every column into the future rather than just one.
    return $result->first_list;
}

sub _warn_if_several {
    my ($result, $method) = @_;

    my $n = $result->count;

    carp "$method expected one row but $n rows matched" if $n > 1;

    return;
}

# True if any bind names its type rather than giving the numeric OID. Cheap,
# and it runs on every query, so it is a scan of binds already in hand and
# never a second pass over anything.
sub _binds_name_a_type {
    my ($bind) = @_;

    for my $value (@$bind) {
        next unless ref $value eq 'HASH';
        next unless exists $value->{type} && exists $value->{value};
        return 1 if defined $value->{type} && $value->{type} !~ /\A[0-9]+\z/;
    }

    return 0;
}

# Rewrite { type => 'bytea' } to { type => 17 } before the bind loop sees it.
#
# Done here rather than inside that loop because a croak raised in there would
# be caught by the surrounding eval and re-reported as a query error rather
# than as the caller's mistake.
sub _resolve_bind_types {
    my ($self, $bind) = @_;

    return $bind unless _binds_name_a_type($bind);

    my @resolved = @$bind;

    for my $i (0 .. $#resolved) {
        my $value = $resolved[$i];

        next unless ref $value eq 'HASH';
        next unless exists $value->{type} && exists $value->{value};
        next unless defined $value->{type} && $value->{type} !~ /\A[0-9]+\z/;

        my $oid = $TYPE_OID{ lc $value->{type} };

        croak "Unknown PostgreSQL type name '$value->{type}' for bind "
            . 'parameter ' . ($i + 1) . '. Names are DBD::Pg\'s, such as '
            . 'bytea or jsonb; a type DBD::Pg does not know cannot be bound '
            . 'by type at all, so bind it untyped or cast it in SQL'
            unless defined $oid;

        $resolved[$i] = { type => $oid, value => $value->{value} };
    }

    return \@resolved;
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

        # ERROR, FATAL and PANIC mean the connection itself may be gone, not
        # merely something the statement noticed along the way -- logged at
        # warn to match how the rest of this module reports a dead
        # connection (_heal_if_dead's own "replacing a pooled connection
        # that was already dead"), rather than at the same level as routine
        # chatter.
        if ($message =~ /^(?:ERROR|FATAL|PANIC):/) {
            $message =~ s/\n\z//;
            $pool->_log(warn => $message);
            return;
        }

        # The rest of PostgreSQL's severities are routine and downgraded to
        # an info-level log line.
        if ($message =~ /^(?:NOTICE|WARNING|INFO|LOG|DEBUG):/) {
            $message =~ s/\n\z//;
            $pool->_log(info => $message);
            return;
        }

        # Not a PostgreSQL message at all -- a DBI handle-lifecycle warning,
        # say -- is a real problem, not chatter, and is passed through as an
        # ordinary warning instead of being relabeled and mixed in with
        # server message text.
        warn $message;
    };

    return $code->();
}

# Core async query execution using DBD::Pg async support
# Look the statement up, or prepare and remember it. Returns the handle and
# whether it came from the cache, which the on_query event reports.
sub _statement_for {
    my ($self, $sql) = @_;

    my $size = $self->{statement_cache_size};

    return ($self->_prepare_statement($sql), 0) unless $size;

    if (my $sth = $self->{_stmt_cache}{$sql}) {
        # A cached handle that has lost its server-side statement has lost the
        # cached plan whose 0A000 is the only thing standing between a
        # result-shape change and a segfault. Nothing observed today puts a
        # handle in that state, which is exactly why it is checked here rather
        # than assumed: the invariant this cache rests on is cheap to confirm
        # and fatal to get wrong.
        if (length($sth->{pg_prepare_name} // '')) {
            # Most recently used goes to the end.
            @{ $self->{_stmt_lru} } = grep { $_ ne $sql } @{ $self->{_stmt_lru} };
            push @{ $self->{_stmt_lru} }, $sql;

            return ($sth, 1);
        }

        $self->_evict_statement($sql);
    }

    my $sth = $self->_prepare_statement($sql);

    # Only a statement carrying placeholders is ever promoted to a named
    # server-side prepared statement, and only a named statement is safe to
    # reuse -- see the note on pg_switch_prepared where the handle is
    # created. Caching the rest would buy DBI's local re-parse and nothing on
    # the server, at the price of the one crash this cache can cause.
    return ($sth, 0) unless $sth->{NUM_OF_PARAMS};

    $self->{_stmt_cache}{$sql} = $sth;
    push @{ $self->{_stmt_lru} }, $sql;

    # Dropping the reference is what makes DBD::Pg deallocate the server-side
    # statement, so the bound is a server-memory bound as much as a local one.
    while (@{ $self->{_stmt_lru} } > $size) {
        my $oldest = shift @{ $self->{_stmt_lru} };
        delete $self->{_stmt_cache}{$oldest};
    }

    return ($sth, 0);
}

sub _prepare_statement {
    my ($self, $sql) = @_;

    my $dbh = $self->{dbh};

    # dollaronly confines DBD::Pg's own placeholder scan to $1, which is the
    # only form reaching it: positional binds arrive as $1 already, and
    # convert_placeholders has rewritten :name into $1 by now. Left off, that
    # scan reads PostgreSQL's own syntax as placeholders -- jsonb's ?, ?| and
    # ?& operators, and the open array slice arr[:2] -- and the statement dies
    # at execute on a placeholder the caller never wrote.
    my $sth = eval {
        $dbh->prepare($sql, {
            pg_async                  => PG_ASYNC,
            pg_placeholder_dollaronly => 1,
        })
    };

    $self->_throw_query_error($@ || $dbh->errstr, $sql) if $@ || !$sth;

    return $sth;
}

# Forget a cached statement. Called whenever a handle's state stops being
# known to be good: an error, a cancellation, or a server that says the
# prepared statement it names is not there.
sub _evict_statement {
    my ($self, $sql) = @_;

    return unless defined $sql && $self->{statement_cache_size};

    delete $self->{_stmt_cache}{$sql};
    @{ $self->{_stmt_lru} } = grep { $_ ne $sql } @{ $self->{_stmt_lru} };

    return;
}

# The two states a cached statement can fail with that say the cache is
# stale rather than the query wrong.
#
# 0A000 is a schema change under a cached plan; 26000 is the server not
# having the named statement at all, which is what a pooler in
# transaction-pooling mode produces when consecutive transactions land on
# different backends.
#
# Both fail at parse or bind time, before the statement executes, so
# evicting and preparing again cannot double-execute anything. That is the
# whole reason this recovers by itself instead of reaching the caller.
my %CACHE_STALE = map { $_ => 1 } qw(0A000 26000);

async sub _execute_async {
    my ($self, $sql, $bind) = @_;

    my $result = eval { await $self->_execute_once($sql, $bind) };
    my $err = $@;

    return $result unless $err;

    # Once, never in a loop: a second failure with the same state means
    # something other than a stale cache entry.
    die $err unless $self->{statement_cache_size};
    die $err unless ref $err && $CACHE_STALE{ eval { $err->state } // '' };

    $self->_evict_statement($sql);

    return await $self->_execute_once($sql, $bind);
}

async sub _execute_once {
    my ($self, $sql, $bind) = @_;
    $bind //= [];

    my $dbh = $self->{dbh};

    # dollaronly confines DBD::Pg's own placeholder scan to $1, which is the
    # only form reaching it: positional binds arrive as $1 already, and
    # convert_placeholders has rewritten :name into $1 by now. Left off, that
    # scan reads PostgreSQL's own syntax as placeholders -- jsonb's ?, ?| and
    # ?& operators, and the open array slice arr[:2] -- and the statement dies
    # at execute on a placeholder the caller never wrote.
    my ($sth, $cached) = $self->_statement_for($sql);
    $self->{_last_was_cached} = $cached;

    # Hold the in-flight handle on the connection. A query abandoned part way
    # through has its async sub torn down along with the lexicals inside it,
    # and DBI warns when a statement handle is collected while still active.
    #
    # A guard rather than a release at the end, because a caller cancelling
    # the query stops this sub where it is suspended and nothing after the
    # await runs.
    #
    # The guard carries the cache key so its exits can decide the entry's
    # fate: hand_over means Results finished the handle cleanly and it stays;
    # release and destruction both mean the handle's state is unknown, and an
    # unknown handle must not be handed to the next caller.
    my $statement = Async::DBD::Pg::Connection::_StatementGuard->new($self, $sth, $sql);

    my $rv = eval {
        $self->_capture_pg_notices(sub {
            # Bound one at a time rather than handed to execute() as a
            # list, so a value can carry its own PostgreSQL type. Without
            # that, DBD::Pg sends everything as text -- and bytea sent as
            # text is truncated at the first NUL, with the write reporting
            # success. See the typed-bind-parameters design spec.
            for my $i (0 .. $#$bind) {
                my $value = $bind->[$i];
                my $attrs;

                if (ref $value eq 'HASH'
                    && exists $value->{type} && exists $value->{value}) {
                    $attrs = { pg_type => $value->{type} };
                    $value = $value->{value};
                }

                $sth->bind_param($i + 1, $value, $attrs);
            }
            $sth->execute;
        });
    };

    if ($@ || !defined $rv) {
        my $err = $@ || $sth->errstr || $dbh->errstr;
        # release evicts the cached entry, and dropping the last reference to
        # a statement handle sends DEALLOCATE -- a statement on this
        # connection, which is what pg_error_field documents as resetting
        # every diagnostic field. _throw_query_error reads those fields on the
        # next line and still gets them, because the $sth lexical above holds
        # the handle until this frame unwinds. Anything that drops that
        # reference earlier, or moves the capture later, silently empties
        # every diagnostic on Error::Query.
        $statement->release;
        $self->_throw_query_error($err, $sql);
    }

    # Wait for async result using Future::IO
    await $self->_wait_for_result;

    my $result = eval { $self->_capture_pg_notices(sub { $dbh->pg_result }) };
    if ($@ || !$result) {
        my $err = $@ || $dbh->errstr;
        # release evicts the cached entry, and dropping the last reference to
        # a statement handle sends DEALLOCATE -- a statement on this
        # connection, which is what pg_error_field documents as resetting
        # every diagnostic field. _throw_query_error reads those fields on the
        # next line and still gets them, because the $sth lexical above holds
        # the handle until this frame unwinds. Anything that drops that
        # reference earlier, or moves the capture later, silently empties
        # every diagnostic on Error::Query.
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

# True once the in-flight async statement's result is ready to collect.
#
# Wrapped in _capture_pg_notices because a NOTICE emitted by the running
# statement is delivered while pg_ready reads the socket; unwrapped it would
# reach stderr instead of the connection's notice handling.
#
# Never throws. This is called from the pub/sub listener loop as well as from
# a query's own frame, and a DBI exception escaping there would kill the
# listener -- reporting a query's error as a connection failure and taking
# down notification delivery with it. Reporting "ready" on error is
# deliberate: it stops the caller waiting and lets pg_result surface the real
# error to the query's owner, which is the party that cares.
#
# The common case is not an error at all: pg_ready throws "No asynchronous
# query is running" when no statement is outstanding, which callers reach
# after collecting a result rather than before dispatching one.
sub _result_ready {
    my ($self) = @_;

    my $dbh = $self->{dbh} or return 1;

    my $ready = eval { $self->_capture_pg_notices(sub { $dbh->pg_ready }) };
    return 1 if $@;

    return $ready ? 1 : 0;
}

# Wait for PostgreSQL socket to be readable using Future::IO's official poll API
async sub _wait_for_result {
    my ($self) = @_;

    # Somebody else owns this socket -- see Async::DBD::Pg::PubSub, which
    # installs one for the life of its listener loop. Awaiting their future
    # rather than polling is what keeps exactly one reader on the fd: two
    # pollers steal each other's readiness, because pg_ready and pg_notifies
    # both consume the socket into libpq's buffer while poll reports on the
    # socket itself.
    if (my $delegate = $self->{_poll_delegate}) {
        return await $delegate->($self);
    }

    my $sock = $self->_get_socket;

    while (!$self->_result_ready) {
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
# Advisory locks, transaction-scoped. PostgreSQL releases these when the
# transaction ends, whether it commits or rolls back, so nothing here has to
# be undone by hand and a cancelled caller cannot leak one.
#
# The session-scoped form (pg_advisory_lock) is deliberately not offered: it
# outlives the transaction, so a connection carrying one would go back to the
# pool still holding it, and the next caller to check that connection out
# would silently own someone else's mutex.
async sub advisory_lock {
    my ($self, @key) = @_;

    await $self->_advisory('pg_advisory_xact_lock', 'advisory_lock', @key);

    return 1;
}

# Takes the lock if it is free, and says so either way rather than waiting.
async sub try_advisory_lock {
    my ($self, @key) = @_;

    my $got = await $self->_advisory(
        'pg_try_advisory_xact_lock', 'try_advisory_lock', @key,
    );

    return $got ? 1 : 0;
}

async sub _advisory {
    my ($self, $function, $method, @key) = @_;

    # Outside an explicit transaction the lock is released the instant the
    # implicit single-statement one ends, so it would guard nothing. A mutex
    # that silently does not lock is worse than no mutex.
    croak "$method needs a transaction to hold the lock; "
        . 'call it inside transaction(), which is what releases it'
        unless $self->{in_transaction};

    croak "$method takes one 64-bit key or two 32-bit keys"
        unless @key == 1 || @key == 2;

    my $placeholders = join ', ', map { "\$$_" } 1 .. @key;

    my $result = await $self->query(
        "SELECT $function($placeholders) AS locked", @key,
    );

    return $result->first_value;
}

# Run the whole transaction again when the server says it lost a race it
# could win next time. Only 40001 and 40P01 qualify, which is the entire
# point: retrying anything else is a slower failure, and retrying a single
# statement rather than the transaction is the mistake this replaces.
#
# Each attempt is an ordinary transaction, so a failed one has already been
# rolled back before the next BEGIN -- without that, a retry would re-apply
# whatever the first attempt wrote.
async sub _transaction_with_retry {
    my ($self, $retries, $opts, $code, @args) = @_;

    my %inner = %$opts;
    delete $inner{retry};

    my $backoff = $opts->{retry_delay} // 0.05;
    my $attempt = 0;

    while (1) {
        $attempt++;

        my $result = eval { await $self->transaction(\%inner, $code, @args) };
        my $err = $@;

        return $result unless $err;

        die $err if $attempt > $retries;
        die $err unless ref $err && eval { $err->is_retryable };

        # Exponential, so a deadlock between two workers does not have them
        # collide again on the same schedule.
        await Future::IO->sleep($backoff * (2 ** ($attempt - 1)));
    }
}

async sub transaction {
    my ($self, @rest) = @_;

    # Options lead so a reader sees them before the block, and so the trailing
    # slot is free for arguments the caller wants forwarded rather than closed
    # over. A code ref is never a hashref, so the two forms cannot be confused.
    my %opts = ref $rest[0] eq 'HASH' ? %{ shift @rest } : ();
    my ($code, @args) = @rest;

    my $isolation = $opts{isolation};
    my $savepoint_depth = $self->{_savepoint_depth} // 0;

    if (my $retry = $opts{retry}) {
        # Retrying an inner block would re-run a savepoint rather than the
        # transaction, which is the wrong-scope bug this option exists to
        # stop people writing by hand. Refuse rather than quietly do the
        # weaker thing.
        croak 'retry applies to the outermost transaction only; '
            . 'this one is nested inside another'
            if $savepoint_depth > 0;

        return await $self->_transaction_with_retry($retry, \%opts, $code, @args);
    }

    if ($savepoint_depth > 0) {
        my $savepoint = "sp_$savepoint_depth";
        await $self->query("SAVEPOINT $savepoint");

        $self->{_savepoint_depth} = $savepoint_depth + 1;

        my $result = eval { await $code->($self, @args) };
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

        my $result = eval { await $code->($self, @args) };
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
        my ($converted, $named) = convert_placeholders($sql, $bind);

        if (@$named || $converted ne $sql) {
            ($sql, $bind) = ($converted, $named);
        }
        else {
            # No :name placeholders in the statement, so this hashref cannot
            # be a map of named binds -- it is a single positional value,
            # which is how a lone typed parameter arrives. Deciding from the
            # SQL rather than from the hash's keys is what lets a genuine
            # named-bind hash for :type and :value keep working.
            $bind = [$bind];
        }
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

    # Dropped at the one point every checkout passes through. The delegate
    # closes over whoever installed it; a stale one on a pooled connection
    # would park the next borrower's query on a future nobody will ever
    # complete.
    delete $self->{_poll_delegate};

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

    # A prepared statement belongs to the backend that made it, so the cache
    # is derived state of the handle and cannot outlive it. Enforced here
    # rather than at the one call site that currently keeps using the
    # Connection afterwards -- _replace_dbh, which heals a dead connection in
    # place -- because every other caller discards the Connection entirely
    # and only the ordering of a future one would decide whether this matters
    # again. Executing a statement held over from a closed handle fails with
    # "Cannot call execute on a disconnected database handle", a DBI error
    # carrying no SQLSTATE, which the 0A000/26000 recovery does not see.
    %{ $self->{_stmt_cache} } = ();
    @{ $self->{_stmt_lru} }   = ();
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
    my ($class, $conn, $sth, $sql) = @_;

    $conn->{_active_sth} = $sth;

    my $self = bless { conn => $conn, sql => $sql }, $class;
    weaken($self->{conn});

    return $self;
}

# The statement is finished with and nobody is going to read it. This is an
# error path, so the handle's state is unknown and it must not be reused.
sub release {
    my ($self) = @_;

    my $conn = delete $self->{conn} or return;
    $conn->_evict_statement(delete $self->{sql});
    $conn->_release_active_sth;
}

# Ownership passes to the caller, who finishes the handle instead. The only
# exit that leaves the statement fit to reuse, so the only one that keeps it.
sub hand_over {
    my ($self) = @_;

    my $conn = delete $self->{conn} or return;
    delete $self->{sql};
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
    my $r = await $conn->query($sql, { type => PG_BYTEA, value => $bytes });

Runs a statement and returns an L<Async::DBD::Pg::Results>.

Placeholders come in two forms. PostgreSQL's own C<$1>, C<$2> take their
values from the remaining positional arguments. Named C<:name> placeholders
take theirs from a hashref, and are rewritten to positional form before the
statement is sent; naming a placeholder with no matching key is an error
rather than something passed through to the server. The two forms cannot be
mixed in one statement.

There is no third form: B<C<?> is never a placeholder here>. That is
deliberate, and it is what makes PostgreSQL's own syntax usable unescaped:

    # the jsonb existence operators, which need no escaping
    await $conn->query(q{SELECT data ? 'key' FROM docs WHERE id = $1}, $id);
    await $conn->query(q{SELECT data ?| array['a','b'] FROM docs});

    # an array slice with an omitted bound
    await $conn->query('SELECT tags[:2] FROM posts WHERE id = $1', $id);

Coming from DBI, where C<?> is the usual placeholder, a statement written
with C<?> reaches PostgreSQL with the question marks intact and fails as a
syntax error naming the C<?>. Use C<$1> instead. For the same reason a
C<:name> typed by mistake in a statement with no hashref of parameters
reaches the server literally and is reported as a syntax error at the colon.

=head3 Typed bind parameters

A bind value may state its own PostgreSQL type by being a hashref with
C<type> and C<value>:

    use DBD::Pg qw(:pg_types);

    await $conn->query('INSERT INTO files (name, body) VALUES ($1, $2)',
        $name, { type => PG_BYTEA, value => $bytes });

    await $conn->query('INSERT INTO files (name, body) VALUES (:name, :body)',
        { name => $name, body => { type => PG_BYTEA, value => $bytes } });

This is required for C<bytea>, and is not optional in the way it may appear.
Without it the value is sent as text, and PostgreSQL's text form for C<bytea>
is not a Perl string: a value containing a NUL byte is B<truncated at that
byte, and the statement reports success>. Anything with a zero in it -- an
image, a compressed or encrypted payload, a serialized structure -- is lost on
the way in. The same applies to any type whose wire form differs from the
scalar you hold; C<bytea> is simply the case where the loss is silent.

Perl has no distinct binary type to detect, which is why the type has to be
stated rather than inferred. The convention is L<Mojo::Pg>'s, so it should be
familiar if you have used that.

The type may also be given by name, which is what
L<Async::DBD::Pg::Results/types> reports and what an application that has
read C<pg_catalog> already holds:

    await $conn->query('INSERT INTO files (name, body) VALUES ($1, $2)',
        $name, { type => 'bytea', value => $bytes });

The names are DBD::Pg's own, its C<PG_*> constants lowercased with the
prefix dropped, so C<PG_BYTEA> is C<'bytea'>. Resolution happens against a
map built when the module loads and costs no round trip.

That set is exactly what DBD::Pg is able to bind. A type it does not know
-- a user-defined enum, a domain, an extension type -- croaks here, naming
the type. It cannot be bound by type at all: bind it untyped, or cast it in
SQL. This is no loss, because such a type does not need a typed bind; it is
text on the wire. The types that need one, C<bytea> above all, are exactly
the ones DBD::Pg knows.

Two names are worth knowing. C<'char'> is DBD::Pg's C<PG_CHAR>, PostgreSQL's
internal single-byte type -- SQL C<CHAR(n)> is C<'bpchar'>. And the map
includes pseudo-types such as C<'internal'> and C<'trigger'>, which resolve
but which DBD::Pg refuses to bind; nothing sensible binds them.

Numeric types are passed straight through, so C<:pg_types> constants keep
working and cost no lookup.

A value that is a hashref without both keys is not a typed parameter, and
reaches DBD::Pg as a reference, which it refuses.

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

=head2 query_row

    my $row = await $conn->query_row($sql, @bind);

The first row as a hashref, or C<undef> when nothing matched. Takes the same
arguments as L</query>.

    my $user = await $conn->query_row('SELECT * FROM users WHERE id = $1', $id)
        or return;

C<undef> for no match, because that is an ordinary outcome to branch on
rather than an exception to trap. A warning when more than one row matched,
because asking for one and getting several usually means the query is wrong;
the first row is still returned.

Because it builds a hashref, a query whose column names repeat is an error:

    Column 'id' appears 2 times at positions 0, 1 in query_row;
    alias the columns, or use query(...)->single (optionally with ->as)

C<query_row> takes a bind list and so has nowhere to put an option, which is
why the way out is one tier down rather than an argument here. See
L<Async::DBD::Pg::Results/"Repeated column names">.

=head2 query_value

    my $value = await $conn->query_value($sql, @bind);

The first column of the first row, or C<undef> when nothing matched. Takes
the same arguments as L</query>.

    my $total = await $conn->query_value('SELECT count(*) FROM users');

C<undef> for no match, and a warning for more than one row, matching
L</query_row>.

Positional throughout: it never builds a hashref, so unlike L</query_row> it
works on a query whose column names repeat.

=head2 query_list

    my ($id, $name) = await $conn->query_list($sql, @bind);

The first row as a list of values, in column order, for the common case of
wanting a few fields out of one row without naming them twice:

    my ($id, $name, $email)
        = await $conn->query_list('SELECT id, name, email FROM users WHERE id = $1', $id);

An empty list when nothing matched, and a warning when more than one row
matched, matching L</query_row> and L</query_value>.

Positional throughout, so like L</query_value> and unlike L</query_row> it
works on a query whose column names repeat.

Awaited in scalar context it gives the first value rather than an arrayref,
because the future carries the values as a list. This is the one place it
differs from L<Async::DBD::Pg::Results/first_list>, which does return an
arrayref there: an async sub cannot see the context of the code awaiting it.
Use C<< (await $conn->query($sql))->first_list >> if you want the arrayref.

=head2 transaction

    my $result = await $conn->transaction(async sub {
        my ($conn) = @_;
        await $conn->query(...);
        return $value;
    });

    await $conn->transaction($code, @args);
    await $conn->transaction({ isolation => 'serializable' }, $code, @args);

Runs C<$code> inside a transaction, committing when it returns and rolling
back if it dies, then rethrowing. Whatever C<$code> returns is returned.

A leading hashref is read as options, so a reader sees them before the block
rather than having to scroll past it. Any arguments after C<$code> are
forwarded to it as C<< $code->($conn, @args) >>, letting a caller pass values
in rather than close over them. Options moved from a trailing list to a
leading hashref in 0.001001; the old C<< transaction($code, isolation => ...)
>> form is no longer accepted.

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

=head3 Retrying a transaction

    await $conn->transaction({ retry => 3 }, async sub { ... });

Runs the whole block again when it fails with a SQLSTATE whose documented
remedy is to retry: C<40001> (serialization failure) and C<40P01> (deadlock
detected). Nothing else is ever retried, and nothing is retried unless this
option is given.

Each attempt is a complete transaction, so a failed one is rolled back before
the next C<BEGIN> and no work from it survives. The delay between attempts
doubles, starting at 0.05 seconds; C<retry_delay> sets the first one.

The value is the number of B<retries>, so C<< retry => 3 >> means up to four
attempts. When they are exhausted the last failure propagates unchanged.

Two things to know before using it:

=over 4

=item *

B<The block runs more than once, so anything it does outside the database
happens more than once.> Sending mail, charging a card, or writing a file
from inside a retried transaction will do it again on every attempt. Keep
such work outside the block, or after it.

=item *

B<It applies to the outermost transaction only.> A nested C<transaction> is
a savepoint, and retrying one would re-run the savepoint rather than the
transaction -- the wrong-scope mistake this option exists to prevent.
Asking for C<retry> on a nested call is an error.

=back

Whether an error qualifies is L<Async::DBD::Pg::Error/is_retryable>, which
can be asked directly if you would rather handle it yourself.

=head2 advisory_lock

    await $pg->transaction(async sub {
        my ($conn) = @_;
        await $conn->advisory_lock($id);
        ...
    });

    await $conn->advisory_lock($classifier, $id);   # two 32-bit keys

Takes a PostgreSQL advisory lock on an arbitrary number, waiting until it is
free. Locks taken this way are held by the B<transaction> and released when
it ends, whether it commits or rolls back.

Calling it outside a transaction is an error. PostgreSQL would release a
transaction-scoped lock at the end of the implicit single-statement
transaction, which is to say immediately, and a mutex that silently fails to
lock is worse than no mutex.

The key is one 64-bit integer, or two 32-bit ones -- a classifier plus an id
is the usual reason for the second form. The two key spaces are separate and
do not collide.

The session-scoped C<pg_advisory_lock> is deliberately not offered. It
outlives its transaction, so a pooled connection would be returned still
holding it and the next caller to check that connection out would silently
own someone else's lock.

=head2 try_advisory_lock

    if (await $conn->try_advisory_lock($id)) { ... }

As L</advisory_lock>, but returns false immediately rather than waiting when
another session holds the lock. This is what to use for "run this if nobody
else is running it", where waiting would be pointless.

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

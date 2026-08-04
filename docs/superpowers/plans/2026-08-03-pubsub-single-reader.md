# PubSub Single Reader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the listener the sole poller of the pub/sub connection's socket, so the pause around every control query can be deleted rather than defended.

**Architecture:** A connection may nominate a *poll delegate*. When one is installed, `Connection::_wait_for_result` awaits the delegate's future instead of polling; otherwise it polls exactly as today. `PubSub`'s listener installs a delegate for exactly as long as its loop runs, and completes the waiting query when it observes the result is ready. Ordinary pooled connections never install one. Exactly one reader owns any fd at any moment.

**Tech Stack:** Perl 5.42, Future::AsyncAwait, Future::IO (UV and IOAsync), DBD::Pg 3.20.2, Test2::V0.

**Spec:** `docs/superpowers/specs/2026-08-03-pubsub-single-reader-design.md` — read it before Task 1. The Ownership rules table and the four Failure paths are the requirements this plan implements.

## Global Constraints

- Every Perl command must be prefixed: `source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default`. Never use system perl.
- The test database is on port **5433** on this machine, not the documented 5432 — an unrelated container owns 5432. Confirm with `docker ps` rather than assuming. Use `TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test"`.
- Run the suite under **both** implementations: `PERL_FUTURE_IO_IMPL=UV` and `PERL_FUTURE_IO_IMPL=IOAsync`. Integration tests honour it via `BEGIN { Future::IO->load_best_impl; }`.
- **Test output must be pristine.** Zero bytes on stderr. Expected errors must be captured and asserted, never printed.
- TDD is mandatory: write the failing test, run it, confirm it fails *for the stated reason*, then implement. Mutation-verify each task — neuter the change and confirm the new test reds on the property, not on something incidental.
- Never delete or weaken an existing test to make a change pass. Every existing pub/sub test must pass unchanged; several were mutation-verified when written and they are the safety net for this refactor.
- Document every new public method or option in POD in the **same commit**.
- `local` on a hash element across an `await` aborts the process under Future::AsyncAwait (`SAVEt_HELEM`). Any `local` must be inside a synchronous sub that awaits nothing.
- Only one agent holds uncommitted work at a time. Check `git status` before starting.
- Do not run the suite while another agent has work in flight — `kill_backends()` in the suite terminates every backend on the shared database.

## File Structure

- `lib/Async/DBD/Pg/Connection.pm` — gains `_result_ready` (one expression of "is the result ready") and the `{_poll_delegate}` branch in `_wait_for_result`. Clears the delegate in `release`.
- `lib/Async/DBD/Pg/PubSub.pm` — `_listener_loop` becomes the single reader; gains `_ReaderGuard`; loses the pause from `_run_control_query` and `_ControlQueryGuard::release`.
- `t/integration/pubsub.t` — new coverage for the delegate, the failure paths, and the pause removal.
- `t/integration/connection.t` — coverage for `_result_ready` and the delegate branch in isolation from pub/sub.
- `docs/gaps.md` — items 71 and 75 updated once the pause is gone.

---

### Task 1: One expression of "is the result ready"

Pure refactor, no behaviour change. Extracts the readiness check so that the listener can later perform it on a query's behalf without duplicating the notice-capture wrapping, and so an exception cannot escape into whichever frame happens to be calling.

**Files:**
- Modify: `lib/Async/DBD/Pg/Connection.pm` (`_wait_for_result`, around `:345-355`; its one caller at `:299`)
- Test: `t/integration/connection.t`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Async::DBD::Pg::Connection::_result_ready($self)` → `1` or `0`. Synchronous, awaits nothing, never throws. Returns `1` when there is no `dbh` or when `pg_ready` throws, so the caller stops waiting and lets `pg_result` report the real error to the query's owner.

- [ ] **Step 1: Write the failing test**

Add to `t/integration/connection.t`:

Requires `PG_ASYNC` in the test file — `Connection.pm` gets it via `use DBD::Pg qw(:async);`, use the same. `use Async::DBD::Pg;` is also needed; that file does not already import it.

```perl
subtest '_result_ready reports readiness without throwing' => sub {
    my $pg   = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 2);
    my $conn = $pg->connection->get;
    my $dbh  = $conn->dbh;

    # Dispatched directly rather than through query(), which would wait for the
    # result and leave nothing to observe. This is the only state
    # _wait_for_result ever calls _result_ready in: a statement sent, no result
    # back yet. pg_ready returns false here -- it is the idle handle, which
    # nothing in production ever asks, that throws instead.
    my $sth = $dbh->prepare('SELECT pg_sleep(0.4)', { pg_async => PG_ASYNC });
    $sth->execute;

    ok !$conn->_result_ready, 'not ready while the statement is still running';

    Future::IO->sleep(0.8)->get;
    ok $conn->_result_ready, 'ready once the result has arrived';

    # Drained before anything else: leaving the handle active makes DBI warn on
    # disconnect, which would breach the suite's pristine-stderr requirement.
    $dbh->pg_result;
    $sth->finish;

    # With the result collected there is no async query left, so pg_ready
    # throws. _result_ready must absorb that and report ready -- a caller that
    # kept waiting here would spin forever.
    ok $conn->_result_ready, 'absorbs pg_ready throwing when no query is running';

    # Same contract when the handle is gone entirely. Built standalone rather
    # than checked out, so a connection with no dbh is never returned to the
    # pool.
    my $dead = Async::DBD::Pg::Connection->new(dbh => undef);
    ok $dead->_result_ready, 'reports ready when the handle is gone';

    $conn->release;
    $pg->shutdown->get;
};
```

**Measured, not assumed** (DBD::Pg 3.20.2): `pg_ready` on an idle handle **throws** `"No asynchronous query is running"`; mid-query it returns `0`; once the result has arrived it returns `1`. An earlier draft of this test asserted that an idle handle reports "not ready", which cannot happen — that is why the test primes a real statement first.

- [ ] **Step 2: Run it and confirm it fails**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
PERL_FUTURE_IO_IMPL=UV perl -Ilib -It/lib t/integration/connection.t
```

Expected: `Can't locate object method "_result_ready"`.

- [ ] **Step 3: Add `_result_ready`**

In `lib/Async/DBD/Pg/Connection.pm`, immediately above `_wait_for_result`:

```perl
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
```

- [ ] **Step 4: Use it from `_wait_for_result`**

Replace the body of `_wait_for_result` with:

```perl
async sub _wait_for_result {
    my ($self) = @_;

    my $sock = $self->_get_socket;

    while (!$self->_result_ready) {
        await Future::IO->poll($sock, POLLIN);
    }
}
```

The `$dbh` parameter is now unused. Update its one caller at `Connection.pm:299` from `await $self->_wait_for_result($dbh);` to:

```perl
    await $self->_wait_for_result;
```

- [ ] **Step 5: Run the new test and the full suite**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
export TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" && \
for impl in UV IOAsync; do PERL_FUTURE_IO_IMPL=$impl prove -r -l -It/lib t/; done
```

Expected: all pass, zero stderr. This task changes no behaviour, so any failure is a real regression.

- [ ] **Step 6: Mutation-verify**

Copy `lib/` to a scratch directory, make `_result_ready` always return `0`, and run `t/integration/connection.t` with `-I<scratch>` ahead of `-Ilib`. Confirm `$INC` shows the mutated copy loaded. Expected: queries hang (bounded by your timeout) rather than passing. Restore.

- [ ] **Step 7: Commit**

```bash
git add lib/Async/DBD/Pg/Connection.pm t/integration/connection.t
git commit -m "Extract the async result readiness check

One expression of 'is the result ready', wrapped once in the notice
capture and unable to throw. The pub/sub listener will shortly perform
this check on a query's behalf, where an escaping DBI exception would
kill the listener rather than fail the query."
```

---

### Task 2: A connection can nominate a poll delegate

Adds the mechanism with no production user. Ordinary pooled connections are unaffected: they install no delegate and poll exactly as before.

**Files:**
- Modify: `lib/Async/DBD/Pg/Connection.pm` (`_wait_for_result`, `release`)
- Test: `t/integration/connection.t`

**Interfaces:**
- Consumes: `_result_ready` from Task 1.
- Produces: `$conn->{_poll_delegate}` — an optional coderef called as `$delegate->($conn)`, returning a `Future` that completes when the connection's in-flight result is ready. Failing that future fails the query. `Connection::release` deletes it, so a delegate can never reach the next borrower.

- [ ] **Step 1: Write the failing test**

Add to `t/integration/connection.t`:

```perl
subtest 'a poll delegate replaces the connection self-polling' => sub {
    my $pg   = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 2);
    my $conn = $pg->connection->get;

    # Stands in for the pub/sub listener: something else owns the fd and says
    # when the result is ready.
    my ($calls, @timers) = (0);
    $conn->{_poll_delegate} = sub {
        my ($c) = @_;
        $calls++;
        my $waiter = Async::DBD::Pg::Util::pending_future();

        # Driven from a timer rather than the socket, so the query completing
        # proves it waited on the delegate rather than polling for itself.
        # The timer is held in a lexical the subtest owns -- see gaps item 64
        # for why ->retain is not the way to keep a future alive here.
        push @timers, Future::IO->sleep(0.05)->on_done(sub {
            $waiter->done unless $waiter->is_ready;
        });

        return $waiter;
    };

    my $result = $conn->query('SELECT 42 AS answer')->get;
    is $result->first->{answer}, 42, 'the query completed through the delegate';
    is $calls, 1, 'the delegate was consulted exactly once';

    # A failing delegate fails the query rather than hanging it.
    $conn->{_poll_delegate} = sub {
        return Future->fail(Async::DBD::Pg::Error::Connection->new(message => 'reader gone'));
    };
    my $failed = eval { $conn->query('SELECT 1')->get; 1 };
    ok !$failed, 'a failing delegate fails the query';
    like "$@", qr/reader gone/, 'and the delegate error reaches the caller';

    # The delegate must never reach the next borrower.
    $conn->release;
    my $reused = $pg->connection->get;
    ok !$reused->{_poll_delegate}, 'release clears the delegate';
    is $reused->query('SELECT 7 AS n')->get->first->{n}, 7,
        'and the reused connection polls for itself again';

    $reused->release;
    $pg->shutdown->get;
};
```

- [ ] **Step 2: Run it and confirm it fails**

Expected: the first assertion fails or the query hangs, because `_wait_for_result` ignores `{_poll_delegate}` and polls for itself; and `release` does not clear it.

- [ ] **Step 3: Honour the delegate in `_wait_for_result`**

```perl
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
```

- [ ] **Step 4: Clear it on release**

In `Connection::release`, immediately after `$self->{released} = 1;`:

```perl
    # Dropped at the one point every checkout passes through. The delegate
    # closes over whoever installed it; a stale one on a pooled connection
    # would park the next borrower's query on a future nobody will ever
    # complete.
    delete $self->{_poll_delegate};
```

- [ ] **Step 5: Run the new test and the full suite under both implementations**

Expected: all pass, zero stderr.

- [ ] **Step 6: Mutation-verify**

Two mutations, each in a scratch copy with `$INC` confirmed:
1. Remove the `{_poll_delegate}` branch from `_wait_for_result`. Expected: `'the delegate was consulted exactly once'` reds.
2. Remove the `delete` from `release`. Expected: `'release clears the delegate'` reds.

- [ ] **Step 7: Commit**

```bash
git add lib/Async/DBD/Pg/Connection.pm t/integration/connection.t
git commit -m "Let a connection nominate a poll delegate

When one is installed, the query awaits it instead of polling the socket
itself, so a second reader on the fd becomes impossible rather than merely
avoided. Ordinary pooled connections install none and are unaffected;
release drops it so it can never reach the next borrower."
```

---

### Task 3: The listener becomes the sole reader, and the pause goes

The core change. After this task no control query stops the listener.

**Files:**
- Modify: `lib/Async/DBD/Pg/PubSub.pm` (`_listener_loop`, `_run_control_query`, `_ControlQueryGuard::release`; new `_ReaderGuard` package)
- Test: `t/integration/pubsub.t`

**Interfaces:**
- Consumes: `$conn->{_poll_delegate}` and `$conn->_result_ready` from Tasks 1-2.
- Produces: `$pubsub->{_query_waiter}` — the future the in-flight control query is parked on, present only while one is waiting. `Async::DBD::Pg::PubSub::_ReaderGuard` — installs the delegate for exactly the listener loop's lifetime and, on any exit, removes it and fails a pending waiter.

- [ ] **Step 1: Write the failing tests**

Add to `t/integration/pubsub.t`:

```perl
subtest 'a control query completes while the listener keeps running' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 4,
    );
    my $pubsub = $pg->pubsub;

    my @got;
    $pubsub->listen('sole_reader', sub { push @got, $_[1] })->get;

    # The listener is running now. With the pause gone it stays running, and
    # this query's result must be delivered by the listener rather than by the
    # query polling for itself -- which is what the delegate arranges.
    my $before = $pubsub->{_listener_future};
    ok $before && !$before->is_ready, 'the listener is running before the query';

    $pubsub->listen('sole_reader_two', sub { })->get;

    my $after = $pubsub->{_listener_future};
    ok $after && !$after->is_ready, 'the listener is still running after it';
    ok refaddr($before) == refaddr($after),
        'and it is the same listener -- never stopped and restarted';

    # Still functional on both channels.
    my $notifier = $pg->connection->get;
    $notifier->query("SELECT pg_notify('sole_reader', 'a')")->get;
    ok wait_until(sub { @got }, 'notification delivered', 5),
        'notifications still flow after a control query';

    $notifier->release;
    $pubsub->disconnect->get;
    $pg->shutdown->get;
};

subtest 'a control query issued from a notification callback completes' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 4,
    );
    my $pubsub = $pg->pubsub;

    # The callback runs inside _process_notifications, which is inside the
    # listener loop. Its listen() claims the control-query slot synchronously
    # and then waits on the very loop that is running it.
    my $inner;
    $pubsub->listen('cb_origin', sub {
        $inner //= $pubsub->listen('cb_target', sub { });
    })->get;

    my $notifier = $pg->connection->get;
    $notifier->query("SELECT pg_notify('cb_origin', 'go')")->get;

    ok wait_until(sub { $inner && $inner->is_ready }, 'inner listen settled', 8),
        'a control query issued from a callback completes';
    ok $inner->is_done, 'and it succeeded';

    $notifier->release;
    $pubsub->disconnect->get;
    $pg->shutdown->get;
};
```

Add `use Scalar::Util qw(refaddr);` to the test file's preamble if it is not already imported.

- [ ] **Step 2: Run them and confirm they fail**

Expected: `'and it is the same listener -- never stopped and restarted'` fails, because `_run_control_query` currently stops the listener and `_ControlQueryGuard::release` starts a new one. The callback test may hang until its bound rather than fail cleanly; that is acceptable as a red, but note which.

- [ ] **Step 3: Add `_ReaderGuard`**

At the end of `PubSub.pm`, beside the other guard packages:

```perl
package Async::DBD::Pg::PubSub::_ReaderGuard;

use strict;
use warnings;

use Scalar::Util qw(refaddr weaken);
use Async::DBD::Pg::Util qw(pending_future);

# Installs the connection's poll delegate for exactly as long as the listener
# loop runs, and takes it away however that loop ends -- return, exception or
# cancellation. That equivalence is the whole design: while the delegate is
# present the listener owns the fd and a query waits on it; while it is absent
# the query polls for itself. There is never a moment with two readers, and
# never one with none.
sub new {
    my ($class, $pubsub, $conn) = @_;

    my $self = bless { conn => $conn, pubsub => $pubsub }, $class;
    weaken($self->{pubsub});

    my $weak_pubsub = $pubsub;
    weaken($weak_pubsub);

    $conn->{_poll_delegate} = sub {
        my $live = $weak_pubsub
            or return Future->fail(Async::DBD::Pg::Error::Connection->new(
                message => 'PubSub is gone',
            ));

        my $waiter = pending_future();
        $live->{_query_waiter} = $waiter;

        # Cleared however this settles -- done, failed, or the caller
        # cancelling -- so the loop never holds a future nobody is waiting on
        # and never completes a query that has already given up.
        $waiter->on_ready(sub {
            my $p = $weak_pubsub                  or return;
            my $held = $p->{_query_waiter}        or return;
            delete $p->{_query_waiter}
                if refaddr($held) == refaddr($waiter);
        });

        return $waiter;
    };

    return $self;
}

sub DESTROY {
    my ($self) = @_;

    my $conn = delete $self->{conn} or return;
    delete $conn->{_poll_delegate};

    my $pubsub = $self->{pubsub} or return;
    my $waiter = delete $pubsub->{_query_waiter} or return;
    return if $waiter->is_ready;

    # The listener is what would have completed this. Failing it is the only
    # alternative to leaving the query parked forever on a future with nobody
    # left to finish it.
    $waiter->fail(Async::DBD::Pg::Error::Connection->new(
        message => 'PubSub listener stopped while a query was waiting',
    ));
}
```

- [ ] **Step 4: Make the listener the sole reader**

Replace `_listener_loop`'s body:

```perl
async sub _listener_loop {
    my ($self) = @_;

    my $conn = $self->{conn} or return;
    my $sock = $conn->_get_socket;

    # From here until this loop ends, this is the only thing polling this
    # socket: a query on this connection waits on us instead. See _ReaderGuard.
    my $reader = Async::DBD::Pg::PubSub::_ReaderGuard->new($self, $conn);

    while ($self->{phase} eq 'live') {
        # Drained before anything else, and before parking below. A control
        # query's own result and a notification arrive in the same read, and
        # whichever call consumes the socket buffers both -- so waiting on the
        # socket first would strand notifications until unrelated traffic made
        # it readable again.
        $self->_process_notifications($conn);

        # Checked after those callbacks and before parking: a callback can
        # issue a control query synchronously, and its result may be ready
        # already. Deleted before completing, so a query issued by the resumed
        # caller does not see a stale waiter.
        my $waiter = $self->{_query_waiter};
        if ($waiter && $conn->_result_ready) {
            delete $self->{_query_waiter};
            $waiter->done unless $waiter->is_ready;

            # Start the iteration over rather than parking. ->done above
            # resumes the waiting query synchronously, all the way through its
            # own pg_result, which consumes whatever is on the socket --
            # trailing notifications included -- into libpq's buffer without
            # draining them. Parking here would wait on an OS readability
            # event that has already happened. Going back to the top drains
            # that buffer first, and re-tests the loop condition, which the
            # resumed query may have invalidated by tearing the listener down.
            next;
        }

        await Future::IO->poll($sock, POLLIN);
    }

    return;
}
```

- [ ] **Step 5: Remove the pause from `_run_control_query`**

Delete this line and the comment block immediately above it that explains stopping the listener:

```perl
    await $self->_stop_listener if $self->{_listener_future};
```

Leave everything else in that sub unchanged — in particular the `{_control_query}` mutex and its guard, which serialize control queries and are a different mechanism that happened to share the field.

- [ ] **Step 6: Remove the restart from `_ControlQueryGuard::release`**

Delete from `release` everything from the comment beginning `# $done->done above can, in the same call, run a second control query` through the end of the sub, and replace with:

```perl
    return;
```

The slot deletion and `$done->done` above it stay. `_start_listener` is no longer called from this class.

- [ ] **Step 7: Run the new tests, then the full suite under both implementations**

Expected: the two new subtests pass, and every existing pub/sub subtest still passes. Zero stderr.

- [ ] **Step 8: Re-run the experiments**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
export TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" && \
for impl in UV IOAsync; do
  PERL_FUTURE_IO_IMPL=$impl ROUNDS=4 perl -Ilib \
    /private/tmp/claude-598291738/-Users-jnapiorkowski-Desktop-Async-DBD-Pg/1974a188-6fbd-428b-ad46-8ca6da0e6087/scratchpad/frag-experiment.pl
done
```

Expected: `160/160 received, 160 distinct, 0 duplicated`, `VERDICT: clean`, both implementations. If the scratchpad is gone, reconstruct it from gaps item 75, which describes what it does.

- [ ] **Step 9: Mutation-verify**

Two mutations, each in a scratch copy with `$INC` confirmed.

1. Remove the waiter-completion block from the loop (the whole `if ($waiter && $conn->_result_ready)` stanza). Expected: control queries hang, and `'a control query completes while the listener keeps running'` reds on its bound rather than on setup.

2. Remove only the `next`, letting control fall through to the poll. Expected: the fragmentation experiment stalls — a growing backlog that never drains without unrelated traffic. **The suite will not catch this one**; it was found by the experiment in Step 8 while the full suite passed 189/189 clean on both implementations. That asymmetry is the point of the mutation: it records that this line is load-bearing for a property no test asserts directly.

- [ ] **Step 10: Commit**

```bash
git add lib/Async/DBD/Pg/PubSub.pm t/integration/pubsub.t
git commit -m "Make the listener the pub/sub connection's sole reader

A control query no longer stops the listener. Instead the listener owns
the socket for its whole life and completes the query when it sees the
result is ready, so there is never a second poller to collide with rather
than a pause arranged to avoid one.

The {_control_query} mutex stays: DBD::Pg still cannot run two async
operations on one handle, and serializing is a different job from pausing
that happened to share the field."
```

---

### Task 4: The failure paths

Task 3 makes the happy path work. This task proves the three ways it can go wrong are handled, and fixes whatever is not.

**Files:**
- Modify: `lib/Async/DBD/Pg/PubSub.pm` (only if a test exposes a gap)
- Test: `t/integration/pubsub.t`

**Interfaces:**
- Consumes: `_ReaderGuard` and `{_query_waiter}` from Task 3.
- Produces: no new interfaces.

- [ ] **Step 1: Write the failing tests**

```perl
subtest 'a control query that fails reaches its caller, and the listener lives' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 4,
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('err_probe', sub { })->get;

    my $listener = $pubsub->{_listener_future};

    # Fails on its own merits, not because the connection is broken. The error
    # belongs to this caller; the listener must not be collateral damage.
    my ($ok, $err);
    my $captured = capture_stderr(sub {
        $ok  = eval { $pubsub->_run_control_query('SELECT 1/0')->get; 1 };
        $err = $@;
    });
    ok !$ok, 'the failing control query fails';
    like "$err", qr/division by zero/i, 'the caller gets the real error';
    is $captured, '', 'and nothing leaked to stderr on the way';

    ok !$listener->is_ready, 'the listener survived the query error';
    ok refaddr($pubsub->{_listener_future}) == refaddr($listener),
        'and was not restarted behind our back';

    # Still working afterwards.
    $pubsub->listen('err_probe_two', sub { })->get;
    ok $pubsub->is_connected, 'further control queries still work';

    $pubsub->disconnect->get;
    $pg->shutdown->get;
};

subtest 'cancelling a control query leaves no stale waiter' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 4,
    );
    my $pubsub = $pg->pubsub;
    $pubsub->listen('cancel_probe', sub { })->get;

    my $slow = $pubsub->_run_control_query('SELECT pg_sleep(2)');
    ok wait_until(sub { $pubsub->{_query_waiter} }, 'query parked on the delegate', 3),
        'the query is waiting on the listener';

    $slow->cancel;

    ok wait_until(sub { !$pubsub->{_query_waiter} }, 'waiter cleared', 3),
        'cancelling clears the waiter rather than leaving it for the loop';

    # The connection is still usable: the next control query completes.
    $pubsub->listen('cancel_probe_two', sub { })->get;
    ok $pubsub->is_connected, 'the next control query completes';

    $pubsub->disconnect->get;
    $pg->shutdown->get;
};

subtest 'a listener that stops fails a query still waiting on it' => sub {
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 4,
        on_log          => sub { push @logged, $_[1] },
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('orphan_probe', sub { })->get;

    my $slow = $pubsub->_run_control_query('SELECT pg_sleep(5)');
    ok wait_until(sub { $pubsub->{_query_waiter} }, 'query parked', 3),
        'the query is waiting on the listener';

    # NOT disconnect(): teardown cancels an in-flight control query itself, so
    # the query would settle by cancellation and the guard would never be the
    # thing that finished it -- a test that passes without exercising what it
    # names. Killing the backend takes the listener down underneath a query
    # that is parked on the delegate, which is the only path by which the
    # guard is what settles it, and is also the realistic case: a dropped
    # connection.
    my $captured = capture_stderr(sub {
        kill_backends();

        ok wait_until(sub { $slow->is_ready }, 'orphaned query settled', 8),
            'the waiting query is failed rather than left parked forever';
    });
    is $captured, '', 'the termination notice does not reach fd 2';
    ok scalar(grep { /terminating connection due to administrator command/ } @logged),
        'the termination notice reaches on_log instead';

    ok !$slow->is_done, 'and it did not falsely report success';
    ok !$slow->is_cancelled,
        'it was failed by the listener stopping, not cancelled by teardown';

    $pubsub->disconnect->get;
    $pg->shutdown->get;
};
```

- [ ] **Step 2: Run them and record which fail**

Some may already pass from Task 3's guard. Record which, and why, in the task report — a test that passes first time here is evidence about the guard, not a reason to skip the test. Any that fail enter Step 3.

- [ ] **Step 3: Fix only what the tests expose**

Do not speculatively change code that no failing test demands. If all three pass unchanged, that is the correct outcome and this task is coverage only — say so plainly in the report rather than inventing a change to justify the task.

- [ ] **Step 4: Run the full suite under both implementations**

- [ ] **Step 5: Mutation-verify the guard**

In a scratch copy with `$INC` confirmed, make `_ReaderGuard::DESTROY` return before failing the waiter. Expected: `'the waiting query is failed rather than left parked forever'` reds on its bound.

This mutation is the reason that subtest kills the backend rather than calling `disconnect`. Teardown cancels an in-flight control query on its own, so against `disconnect` the query settles either way and the mutation survives — a green test proving nothing. If the mutation does *not* red, do not adjust the mutation to suit the test: the test is not reaching the guard, and that is the finding to report.

Confirm the other two subtests still pass, so the mutation is isolated to the path it targets.

- [ ] **Step 6: Commit**

```bash
git add lib/Async/DBD/Pg/PubSub.pm t/integration/pubsub.t
git commit -m "Cover the single-reader failure paths

A query error must reach its caller with the listener intact rather than
presenting as a connection failure; a cancelled query must leave no future
for the loop to complete; and a listener that stops must fail whoever was
waiting on it rather than leaving them parked forever."
```

---

### Task 5: Delete what the pause needed, and update the record

**Files:**
- Modify: `lib/Async/DBD/Pg/PubSub.pm` (comments and POD)
- Modify: `docs/gaps.md` (items 71 and 75)
- Test: no new tests; the suite must stay green

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Find comments that describe the pause**

```bash
grep -n "pause\|_stop_listener\|paused\|stand down" lib/Async/DBD/Pg/PubSub.pm
```

Every comment that explains why the listener stops for a control query, or why the slot and the listener must be handed back in a particular order, now describes machinery that no longer exists. Rewrite each to describe what the code does now, or delete it. A comment that survives describing a removed mechanism is the exact failure this codebase has hit repeatedly — see gaps item 75's history.

`_stop_listener` itself stays: teardown and reconnect still use it. Confirm with `grep -n '_stop_listener' lib/` that its remaining callers are only those.

- [ ] **Step 2: Update the POD**

`listen`, `unlisten` and `notify` describe behaviour that has not changed, so verify rather than assume. If any POD says or implies that notification delivery pauses during a subscription change, correct it: delivery is now continuous for as long as the connection is up.

- [ ] **Step 3: Update `docs/gaps.md`**

Item 71 currently ends by saying collapsing to a single reader "remains the only way to remove the pause, and it is a real refactor". Replace that closing with what was done, the commits, and the fact that the pause is gone. Mark it FIXED.

Item 75 records the drain-first fix. Add a line noting the loop that ordering now lives in is the single-reader loop, and that the ordering survived the refactor because it is Mojo::Pg's invariant too.

- [ ] **Step 4: Run the full suite under both implementations, and the latency probe**

Expected: suite green, zero stderr. Latency during a real `LISTEN` no worse than the 1.7 ms recorded before the refactor — and likely better, since a subscription change no longer tears the listener down and builds it again.

- [ ] **Step 5: Commit**

```bash
git add lib/Async/DBD/Pg/PubSub.pm docs/gaps.md
git commit -m "Remove the pause's last traces and update the record

Comments describing a stop/restart that no longer happens, and gaps items
71 and 75 which recorded the single-reader refactor as the open follow-up."
```

---

## Done when

- The suite passes under `PERL_FUTURE_IO_IMPL=UV` and `=IOAsync` with zero bytes on stderr, and `pg_stat_activity` shows no leaked backends before or after.
- `grep -n '_stop_listener' lib/Async/DBD/Pg/PubSub.pm` shows callers only in teardown and reconnect — none in `_run_control_query` or `_ControlQueryGuard`.
- The fragmentation experiment reports `160/160` and `VERDICT: clean` on both implementations.
- Every task's mutation check reded on the property it targets, not on something incidental.

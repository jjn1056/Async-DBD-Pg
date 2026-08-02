# One shared connect attempt for pub/sub: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Async::DBD::Pg::PubSub` take exactly one connection when a
reconnect races an explicit `listen()`, and stop losing notifications when it
does.

**Architecture:** Every path that needs a listener connection goes through
`connect()`, which owns the single attempt. Awaiters wait on a
`without_cancel` view so no one caller can destroy work the others depend on,
and a count of live awaiters cancels the attempt when the last one leaves. The
listener loop hands its own connection to the notification reader rather than
letting the reader re-read shared state.

**Tech Stack:** Perl, Future, Future::AsyncAwait, Future::IO, DBD::Pg,
Test2::V0.

## Global Constraints

- Design document: `docs/superpowers/specs/2026-08-02-pubsub-reconnect-race-design.md`.
- Run all Perl via perlbrew: `source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default`.
- PostgreSQL for integration tests is on port 5433:
  `TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test"`.
- The suite must pass under both `PERL_FUTURE_IO_IMPL=UV` and `IOAsync`.
- Test output must be pristine. Check stderr by redirecting the streams to
  separate files and reading the stderr file. Never use a grep filter, and
  never one excluding lines that begin with whitespace: that mistake hid a real
  error from this project for a whole session.
- A full-suite run currently produces a **zero byte** stderr file. It must
  still do so when you are done.
- **One run proves nothing in this suite.** Real failure rates sit near 3%
  solo and 20% under load. Run a single file 30+ times and the full suite 8+
  times, and report counts, not one result.
- **Nothing else may touch the test database while you measure.** The suite's
  `kill_backends` helper terminates backends on the shared database, so a
  second run or a stray script poisons the result. Check `pg_stat_activity`
  and `pgrep -f 'scratchpad.*\.pl|prove'` before trusting any number, and
  clean up your own processes when you finish.
- Never `->retain`. A future must be owned by something that can cancel it.
- Anything that must be undone cannot be undone by code after an `await`: a
  caller may cancel while the sub is suspended and nothing after that point
  runs. Use a guard object's destructor or a callback on the future.
- `local` on a `%SIG` element held across an `await` **aborts the process**:
  `Future::AsyncAwait panic: TODO: Unsure how to handle savestack entry of
  SAVEt_HELEM=52`, exit 134.
- A nested `->get` inside an already-running `async sub`, on a future built
  from several awaits, crashes under `Future::IO::Impl::IOAsync`
  ("is already done and cannot be ->done"). Use `await`.
- `pg_terminate_backend` sends SIGTERM and returns **before** the backend
  exits. Any test that kills a backend must wait for it to be gone, never
  sleep.
- Module POD in `lib/Async/DBD/Pg.pm` is plain ASCII with no `=encoding` line.
  Do not introduce non-ASCII characters into it.
- Any new public option or documented behaviour needs POD in the same commit.
- `prove -l` prepends the project's real `lib/` ahead of any `-I`. To prove a
  test fails against a scratch copy of a module, do not use `-l`, and verify
  `%INC` from inside the process.

---

## File Structure

- `lib/Async/DBD/Pg/PubSub.pm` — all production changes. `connect()` gains
  awaiter-safe sharing, `_reconnect_loop` loses its own checkout,
  `_process_notifications` takes its connection as a parameter,
  `disconnect`/`_pool_shutdown` cancel an in-flight attempt. A small
  `_AwaiterGuard` package is added at the end of the file, beside the existing
  `_ListenerGuard`.
- `t/integration/pubsub.t` — all tests. It already has `wait_until`,
  `kill_backends`, `capture_stderr`, and `skip_without_postgres`.

---

### Task 1: The listener loop hands its connection to the notification reader

`_listener_loop` reads `$self->{conn}` once and polls that socket forever.
`_process_notifications` re-reads `$self->{conn}` on every wakeup. If `{conn}`
is ever reassigned, the loop polls one connection and asks a different one for
notifications, and the notification is silently dropped. This is what turns the
race in Task 4 into message loss rather than just a leak, and it is worth
fixing on its own.

**Files:**
- Modify: `lib/Async/DBD/Pg/PubSub.pm:210-214` and `:252`
- Test: `t/integration/pubsub.t`

**Interfaces:**
- Produces: `_process_notifications($self, $conn)` — the connection is now a
  required parameter. Its only caller is `_listener_loop`.

- [ ] **Step 1: Write the failing test**

Add to `t/integration/pubsub.t`, before `done_testing`:

```perl
subtest 'the listener keeps reading the connection it is polling' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 4,
    );
    my $pubsub = $pg->pubsub;

    my @got;
    $pubsub->listen('stale_conn_test', sub { push @got, $_[1] })->get;

    # Simulate what a reconnect does: replace the tracked connection while a
    # listener loop is already running against the original one. The loop
    # polls the original socket, so it must also read notifications from the
    # original connection, not from whatever {conn} happens to hold now.
    my $original = $pubsub->conn;
    my $usurper  = $pg->connection->get;
    $pubsub->{conn} = $usurper;

    $pubsub->notify('stale_conn_test', 'delivered')->get;
    wait_until(sub { @got }, 'notification arrived', 3);

    is \@got, ['delivered'],
        'a notification on the polled connection is still delivered';

    $pubsub->{conn} = $original;
    $usurper->release;
    $pubsub->disconnect->get;
};
```

- [ ] **Step 2: Run it and watch it fail for the right reason**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
  TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
  prove -l -It/lib t/integration/pubsub.t
```

Expected: FAIL on `'a notification on the polled connection is still
delivered'` — `@got` is empty, because `_process_notifications` asked
`$usurper` for a notification that arrived on `$original`.

If it PASSES, stop and report: the premise is wrong and the rest of this task
does not apply.

- [ ] **Step 3: Take the connection as a parameter**

In `lib/Async/DBD/Pg/PubSub.pm`, change the head of `_process_notifications`
from:

```perl
sub _process_notifications {
    my ($self) = @_;

    my $conn = $self->{conn} or return 0;
    my $dbh = $conn->dbh or return 0;
```

to:

```perl
# The connection is passed in rather than read from $self. The listener loop
# polls one specific socket for its whole life, so it must read notifications
# from that same connection: if {conn} is replaced underneath it, re-reading
# here would poll one connection and ask a different one what arrived, and the
# notification would be dropped with no error and no log line.
sub _process_notifications {
    my ($self, $conn) = @_;

    $conn or return 0;
    my $dbh = $conn->dbh or return 0;
```

- [ ] **Step 4: Pass it from the listener loop**

At `lib/Async/DBD/Pg/PubSub.pm:252`, change:

```perl
        $self->_process_notifications;
```

to:

```perl
        $self->_process_notifications($conn);
```

- [ ] **Step 5: Run the test and the whole file**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
  TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
  prove -l -It/lib t/integration/pubsub.t
```

Expected: PASS, all subtests.

- [ ] **Step 6: Commit**

```bash
git add lib/Async/DBD/Pg/PubSub.pm t/integration/pubsub.t
git commit -m "Read notifications from the connection the listener polls"
```

---

### Task 2: One caller giving up must not fail the others

Two async subs awaiting the same future are coupled: cancelling either cancels
the future, and the other completes as *failed*. `connect()` has exactly that
shape, so a second caller giving up makes the first fail with
`Future=HASH(0x...) was cancelled` at line 114 — measured, on the real library.

The fix is a `without_cancel` view per awaiter, plus a count so the *last*
awaiter leaving still cancels the attempt. The count matters: without it,
abandoning a lone connect would stop releasing the pool checkout, which is
currently clean and must stay that way.

**Files:**
- Modify: `lib/Async/DBD/Pg/PubSub.pm:84-117` (`connect`), and add
  `_AwaiterGuard` at the end of the file beside `_ListenerGuard`
- Test: `t/integration/pubsub.t`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `$self->{_connecting}` (the shared attempt, unchanged name) and
  `$self->{_connecting_waiters}` (integer count of live awaiters). Task 3
  cancels `{_connecting}`; Task 4 becomes another awaiter through `connect()`.

- [ ] **Step 1: Write the two failing tests**

Add to `t/integration/pubsub.t`:

```perl
subtest 'a caller giving up does not fail another caller' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 3,
    );
    my $pubsub = $pg->pubsub;

    # Both arrive before either finishes, so they share one attempt. The
    # second gives up. The first never did, and must not be punished for it.
    my $first  = $pubsub->connect;
    my $second = $pubsub->connect;
    $second->cancel;

    my $err;
    my $ok = eval { $first->get; 1 };
    $err = $@ unless $ok;

    ok $ok, 'the caller that waited still connected'
        or diag "first caller failed with: $err";
    ok $pubsub->is_connected, 'and the object is connected';

    $pubsub->disconnect->get;
};

subtest 'abandoning the only connect releases everything' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 3,
    );
    my $pubsub = $pg->pubsub;

    # The last awaiter leaving must cancel the attempt, or the connection is
    # checked out for a caller that no longer exists.
    my $abandoned = $pubsub->connect;
    $abandoned->cancel;

    ok wait_until(sub { $pg->active_count == 0 }, 'checkout released', 3),
        'no connection is left checked out';
    ok !$pubsub->is_connected, 'and the object is not left connected';

    $pubsub->disconnect->get;
};
```

- [ ] **Step 2: Run them and watch the first fail**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
  TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
  prove -l -It/lib t/integration/pubsub.t
```

Expected: `'the caller that waited still connected'` FAILS, with a diag
containing `was cancelled`. `'abandoning the only connect releases everything'`
should PASS already — it is the property being preserved, not one being added,
and it must still pass after Step 3.

- [ ] **Step 3: Add the awaiter guard**

At the end of `lib/Async/DBD/Pg/PubSub.pm`, after the existing
`_ListenerGuard` package and before the final `1;`:

```perl
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
package Async::DBD::Pg::PubSub::_AwaiterGuard;

use strict;
use warnings;
use Scalar::Util qw(weaken);

sub new {
    my ($class, $pubsub) = @_;

    $pubsub->{_connecting_waiters}++;

    my $self = bless { pubsub => $pubsub }, $class;
    weaken($self->{pubsub});

    return $self;
}

sub DESTROY {
    my ($self) = @_;

    my $pubsub = $self->{pubsub} or return;
    return unless $pubsub->{_connecting};
    return if --$pubsub->{_connecting_waiters} > 0;

    my $attempt = delete $pubsub->{_connecting};
    delete $pubsub->{_connecting_waiters};
    $attempt->cancel unless $attempt->is_ready;
}

1;
```

- [ ] **Step 4: Rewrite connect() to share safely**

Replace the body of `connect` (`lib/Async/DBD/Pg/PubSub.pm:84-117`) with:

```perl
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
    my $guard = Async::DBD::Pg::PubSub::_AwaiterGuard->new($self);

    await $attempt->without_cancel;

    return $self;
}
```

- [ ] **Step 5: Run the file**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
  TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
  prove -l -It/lib t/integration/pubsub.t
```

Expected: PASS, including both new subtests and the pre-existing
`'giving up on connect leaves pub/sub usable'` and `'cancelling a listen leaves
the listener running'`.

- [ ] **Step 6: Prove the new guard is load-bearing**

Copy `lib/` to a scratch directory, remove the `$attempt->cancel unless
$attempt->is_ready;` line from `_AwaiterGuard::DESTROY` in the copy, and run
the file against it. Do **not** use `-l`, and print `$INC{'Async/DBD/Pg/PubSub.pm'}`
from inside the process to confirm you are running the mutant.

Expected: `'abandoning the only connect releases everything'` goes RED. If it
stays green, the guard is not doing the work the test claims and you should
report that rather than proceeding.

- [ ] **Step 7: Commit**

```bash
git add lib/Async/DBD/Pg/PubSub.pm t/integration/pubsub.t
git commit -m "Stop one caller's cancellation failing the others' connect"
```

---

### Task 3: Teardown cancels an attempt that is still running

Once awaiters cannot cancel the shared attempt, `disconnect()` and
`_pool_shutdown` are the only things that can. Both already cancel the
reconnect supervisor and release `{conn}`; neither touches `{_connecting}`, so
a connect in flight would run to completion after teardown and leave a
connection checked out.

**Files:**
- Modify: `lib/Async/DBD/Pg/PubSub.pm:440-468` (`disconnect`) and `:470-492`
  (`_pool_shutdown`)
- Test: `t/integration/pubsub.t`

**Interfaces:**
- Consumes: `$self->{_connecting}` from Task 2.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'disconnecting during a connect does not leave it running' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 3,
    );
    my $pubsub = $pg->pubsub;

    # Start a connect and tear down before it can finish. Nothing may be left
    # checked out to an object that has been disconnected.
    my $connecting = $pubsub->connect;
    $pubsub->disconnect->get;

    ok wait_until(sub { $pg->active_count == 0 }, 'checkout released', 3),
        'no connection is left checked out after disconnect';
    ok !$pubsub->is_connected, 'and the object is not connected';

    # The caller is still waiting on that connect. A cancelled future surfaces
    # as "Future=HASH(0x...) was cancelled", which tells them nothing about
    # what happened or whether it was their fault.
    ok $connecting->is_ready, 'the waiting caller was told';
    like $connecting->failure, qr/PubSub connect was cancelled/,
        'and told something that explains it';

    $connecting->cancel unless $connecting->is_ready;
};
```

- [ ] **Step 2: Run it and watch it fail**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
  TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
  prove -l -It/lib t/integration/pubsub.t
```

Expected: FAIL on `'no connection is left checked out after disconnect'` —
the attempt completed after `disconnect()` returned and took a connection.

- [ ] **Step 3: Cancel the attempt in disconnect()**

In `disconnect`, immediately after the existing reconnect-future cancellation
(`lib/Async/DBD/Pg/PubSub.pm:446-448`), add:

```perl
    # A connect still in flight would otherwise finish after we return and
    # leave a connection checked out to an object that has been torn down.
    # Awaiters cannot cancel it -- see _AwaiterGuard -- so teardown must.
    if (my $connecting = delete $self->{_connecting}) {
        $connecting->cancel unless $connecting->is_ready;
    }
```

- [ ] **Step 4: Cancel it in _pool_shutdown too**

In `_pool_shutdown`, immediately after the existing reconnect-future
cancellation (`lib/Async/DBD/Pg/PubSub.pm:475-477`), add the identical block:

```perl
    if (my $connecting = delete $self->{_connecting}) {
        $connecting->cancel unless $connecting->is_ready;
    }
```

- [ ] **Step 5: Say what happened instead of leaking the future's address**

In `connect`, replace the bare await added in Task 2:

```perl
    await $attempt->without_cancel;

    return $self;
```

with:

```perl
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
```

- [ ] **Step 6: Run the file**

Same command as Step 2. Expected: PASS, all subtests, including
`'and told something that explains it'`.

- [ ] **Step 7: Commit**

```bash
git add lib/Async/DBD/Pg/PubSub.pm t/integration/pubsub.t
git commit -m "Cancel an in-flight connect when pub/sub is torn down"
```

---

### Task 4: The reconnect supervisor stops taking its own connection

This is the defect the branch exists for. `_reconnect_loop` checks
`unless ($self->{connected} && $self->{conn})` and then awaits its own
checkout. The check and the checkout are two moments with a suspension between
them, so an explicit `listen()` connecting at the same time produces two
connections. The loser is orphaned permanently: `disconnect()` only releases
whatever is in `{conn}`.

Delete the branch rather than guarding it. `connect()` is now the one place
that decides a connection is needed, and it is safe to share.

**Files:**
- Modify: `lib/Async/DBD/Pg/PubSub.pm:331-338`
- Test: `t/integration/pubsub.t`

**Interfaces:**
- Consumes: `connect()` from Task 2, `_process_notifications($self, $conn)`
  from Task 1.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'a reconnect racing a listen takes only one connection' => sub {
    my @got_before;
    my $pg = Async::DBD::Pg->new(
        dsn                    => test_dsn(),
        min_connections        => 0,
        max_connections        => 5,
        reconnect              => 1,
        reconnect_min_interval => 0.1,
        reconnect_max_interval => 0.1,
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('race_before', sub { push @got_before, $_[1] })->get;

    # Delay exactly one pool checkout, so the listen() below is still in
    # flight when the supervisor wakes from its backoff. Real contention does
    # this for free but not reliably; forcing it makes the test deterministic.
    # The delay lives here rather than in the pool: production code does not
    # carry test scaffolding.
    my $orig      = Async::DBD::Pg->can('connection');
    my $delay_one = 1;
    no warnings 'redefine';
    local *Async::DBD::Pg::connection = sub {
        my ($pool) = @_;
        return $pool->$orig unless $delay_one;
        $delay_one = 0;
        return (async sub {
            await Future::IO->sleep(0.3);
            return await $pool->$orig;
        })->();
    };

    kill_backends($dsn);

    # The supervisor is now backing off; this listen races it.
    $pubsub->listen('race_during', sub { })->get;

    ok wait_until(sub { $pubsub->is_connected }, 'reconnected', 5),
        'pub/sub came back';

    # A channel subscribed before the race must still deliver afterwards. If
    # two connections were taken, the listener loop polls one socket while
    # _process_notifications reads the other, and this notification is dropped
    # silently -- no error, no log line, and the subscription still reports
    # itself as active.
    $pubsub->notify('race_before', 'still here')->get;
    ok wait_until(sub { @got_before }, 'notification arrived', 5),
        'a channel subscribed before the race still delivers';

    $pubsub->disconnect->get;

    is $pg->active_count, 0,
        'no connection was orphaned by the race';
};
```

- [ ] **Step 2: Run it and watch it fail**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
  TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
  prove -l -It/lib t/integration/pubsub.t
```

Expected: FAIL on `'no connection was orphaned by the race'` with
`active_count` of 1, because two connections were taken and only one is in
`{conn}` for `disconnect()` to release. `'a channel subscribed before the race
still delivers'` may also fail, for the reason in its comment.

Note the construction: `reconnect` and its intervals are **pool** options, and
`$pg->pubsub` takes no arguments. `t/integration/pubsub.t:396-410` is the
existing example.

- [ ] **Step 3: Delete the supervisor's own checkout**

In `_reconnect_loop`, replace this (`lib/Async/DBD/Pg/PubSub.pm:331-338`):

```perl
        my $ok = eval {
            unless ($self->{connected} && $self->{conn}) {
                my $pool = $self->{pool}
                    or die "pool is gone\n";

                $self->{conn}      = await $pool->connection;
                $self->{connected} = 1;
            }
```

with:

```perl
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
```

- [ ] **Step 4: Run the file**

Same command as Step 2. Expected: PASS, all subtests.

- [ ] **Step 5: Prove the fix is what makes it pass**

Copy `lib/` to a scratch directory, restore the deleted `unless` block in the
copy, and run the file against it without `-l`, confirming `%INC` from inside
the process.

Expected: `'no connection was orphaned by the race'` goes RED. A concurrency
test that has never been seen red is not evidence. If it stays green, the test
is not reproducing the race and you should report that rather than proceeding.

- [ ] **Step 6: Run the file 30 times**

```bash
for i in $(seq 1 30); do
  source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
    PERL_FUTURE_IO_IMPL=$([ $((i % 2)) -eq 0 ] && echo IOAsync || echo UV) \
    TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
    prove -l -It/lib t/integration/pubsub.t > /tmp/pb-$i.out 2>&1
done
grep -L '^Result: PASS' /tmp/pb-*.out | wc -l
```

Expected: `0` files without a PASS. Report the count. Confirm nothing else was
touching the database.

- [ ] **Step 7: Commit**

```bash
git add lib/Async/DBD/Pg/PubSub.pm t/integration/pubsub.t
git commit -m "Reconnect through the shared connect attempt, not a second one"
```

---

### Task 5: The supervisor stops when there is no pool

The loop already gives up when the pool is shutting down, and decides that on
the pool's own state rather than on the error text — deliberately, because
PostgreSQL raises its own "the database system is shutting down" during a
restart, which a text match would treat as permanent when it will clear on its
own. That reasoning stays.

It does not cover a *missing* pool: `$self->{pool} && $self->{pool}{_shutting_down}`
is false when there is no pool at all, so the loop logs and retries forever.
After Task 4 the supervisor calls `connect()`, which dies with
`"No pool configured"` in exactly that case, making this its only unbounded
failure mode.

**Files:**
- Modify: `lib/Async/DBD/Pg/PubSub.pm:394-397`
- Test: `t/integration/pubsub.t`

**Interfaces:**
- Consumes: `connect()`'s `"No pool configured"` failure from Task 2.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'the reconnect supervisor gives up when the pool is gone' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn                    => test_dsn(),
        min_connections        => 0,
        max_connections        => 3,
        reconnect              => 1,
        reconnect_min_interval => 0.05,
        reconnect_max_interval => 0.05,
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('no_pool_test', sub { })->get;

    my $reconnecting;

    # Once the pool is gone, _log has nowhere to send anything and falls back
    # to warn -- so the "giving up" message lands on file descriptor 2 rather
    # than on_log, and must be captured and asserted rather than allowed to
    # escape. That is also the point of the subtest: the supervisor cannot
    # ever succeed without a pool, so it must stop rather than log forever.
    my $captured = capture_stderr(sub {
        delete $pubsub->{pool};
        kill_backends($dsn);

        wait_until(
            sub {
                $reconnecting ||= $pubsub->{_reconnect_future};
                $reconnecting && $reconnecting->is_ready;
            },
            'supervisor finished', 5,
        );
    });

    ok $reconnecting && $reconnecting->is_ready,
        'the supervisor stopped instead of retrying forever';

    my @gave_up = ($captured =~ /giving up on reconnect/g);
    is scalar @gave_up, 1, 'it said so once, on the way out';

    # Put the pool back so teardown can release the connection it still holds.
    $pubsub->{pool} = $pg;
    $pubsub->disconnect->get;
};
```

Note the construction: `reconnect` and its intervals are **pool** options, and
`$pg->pubsub` takes no arguments. `_log` delegates to the pool's `on_log` when
there is a pool, and warns to file descriptor 2 when there is not — which is
why this subtest captures rather than collecting from `on_log`.

- [ ] **Step 2: Run it and watch it fail**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
  TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
  prove -l -It/lib t/integration/pubsub.t
```

Expected: FAIL — the supervisor future never becomes ready within 5s, and
`@logged` fills with repeated attempt failures.

- [ ] **Step 3: Give up when there is no pool**

Replace `lib/Async/DBD/Pg/PubSub.pm:394-397`:

```perl
        if ($self->{pool} && $self->{pool}{_shutting_down}) {
            $self->_log(warn => "PubSub giving up on reconnect: $err");
            return $self;
        }
```

with:

```perl
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
```

- [ ] **Step 4: Run the file**

Same command as Step 2. Expected: PASS, all subtests.

- [ ] **Step 5: Full verification**

Run the whole suite 8 times, alternating implementations, with streams
redirected to separate files:

```bash
for i in $(seq 1 8); do
  impl=$([ $((i % 2)) -eq 0 ] && echo IOAsync || echo UV)
  source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
    PERL_FUTURE_IO_IMPL=$impl TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
    prove -r -l -It/lib t/ > /tmp/fs-$i.out 2> /tmp/fs-$i.err
  echo "run $i: $(tail -1 /tmp/fs-$i.out) stderr $(wc -c < /tmp/fs-$i.err) bytes"
done
```

Expected: 8 PASS, every stderr file 0 bytes. Report every run's result and byte
count, not a summary. Confirm nothing else was touching the database.

- [ ] **Step 6: Update gaps item 65**

In `docs/gaps.md`, change the heading of item 65 from
`### 65. Pub/sub reconnect can orphan a pooled connection` to
`### 65. Pub/sub reconnect can orphan a pooled connection — FIXED`, and add a
closing paragraph in the style of the neighbouring fixed entries describing
what shipped: one shared attempt owned by `connect()`, awaiters on
`without_cancel` views so no caller's cancellation fails another, a count that
cancels the attempt when the last awaiter leaves, and the listener reading
notifications from the connection it polls. Match the surrounding entries'
line width and punctuation.

- [ ] **Step 7: Commit**

```bash
git add lib/Async/DBD/Pg/PubSub.pm t/integration/pubsub.t docs/gaps.md
git commit -m "Stop the reconnect supervisor retrying when there is no pool"
```

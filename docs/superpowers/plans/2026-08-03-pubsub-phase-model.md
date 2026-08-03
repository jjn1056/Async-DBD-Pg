# PubSub phase model: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `Async::DBD::Pg::PubSub`'s lifecycle booleans with a single
phase, derive the listener's pause instead of storing it, and subscribe a
connection fully before publishing it.

**Architecture:** One `{phase}` field with four values replaces `{_stopping}`,
`{_tearing_down}` and `{_listener_paused}`. The listener's pause becomes a read
of `{_control_query}` rather than a flag anyone sets. `_establish` builds and
subscribes a connection in a lexical and publishes it only when complete, so
replay cannot race a caller. Teardown iterates one registry instead of
remembering each mechanism.

**Tech Stack:** Perl, Future, Future::AsyncAwait, Future::IO, DBD::Pg, Test2::V0.

## Global Constraints

- Design document: `docs/superpowers/specs/2026-08-03-pubsub-phase-model-design.md`.
- Run all Perl via perlbrew: `source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default`.
- PostgreSQL for integration tests is on port 5433:
  `TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test"`.
- The suite must pass under both `PERL_FUTURE_IO_IMPL=UV` and `IOAsync`.
- Test output must be pristine. Check stderr by redirecting the streams to
  separate files and reading the stderr file. Never use a grep filter, and never
  one excluding lines that begin with whitespace.
- A full-suite run currently produces a **zero byte** stderr file. It must still
  do so when you are done.
- **This is a refactor. The 34 subtests in `t/integration/pubsub.t` are the
  specification of current behaviour.** Any behavioural subtest that needs
  changing to pass is a signal you have changed behaviour — stop and report
  rather than editing it. Only assertions that read internal state may be
  rewritten, and each rewritten one must be mutation-verified.
- Nothing else may touch the test database while you measure. `kill_backends`
  terminates every backend on it. Check `pg_stat_activity` and `pgrep -f prove`
  first, and clean up anything you start.
- Never `->retain`.
- Anything that must be undone cannot be undone by code after an `await`; use a
  guard destructor or a callback on the future.
- `pg_terminate_backend` sends SIGTERM and returns **before** the backend exits.
  A test that kills a backend must wait for it to be gone, never sleep.
- Perl floor is 5.24. No `state` variables unless the file already enables it.
- Comments explain what and why, never what changed or when.
- `prove -l` prepends the real `lib/` ahead of any `-I`. For a mutation check do
  not use `-l`, and print `$INC{'Async/DBD/Pg/PubSub.pm'}` from inside the
  process to confirm the mutant loaded.
- Mutations to functions on this file's hot paths cascade into unrelated
  subtests and produce `wait_until` timeout noise. Run mutations against an
  **isolated scenario** under a bounded `timeout`.

---

## File Structure

- `lib/Async/DBD/Pg/PubSub.pm` — all production changes.
- `t/integration/pubsub.t` — behavioural tests; a handful of internal-state
  assertions get translated.
- `t/unit/pubsub.t` — constructs objects by setting internals directly; gains a
  phase-aware helper.

---

### Task 1: One guard per control query

`_run_control_query` builds two guards: `_ControlQueryGuard` (frees the slot)
and, nine lines later, `_ListenerGuard` (restarts the listener). Perl destroys
lexicals in reverse declaration order, so the listener is restarted **before**
the slot is freed. That is harmless today because the two communicate through a
flag the restart does not consult — and fatal in Task 3, where the restarted
listener would find the slot still held, exit, and never be restarted.

Merging them makes the order a property of the code. This task is a prerequisite
for Task 3 and changes no behaviour on its own.

**Files:**
- Modify: `lib/Async/DBD/Pg/PubSub.pm` — `_run_control_query`, the
  `_ControlQueryGuard` package, delete the `_ListenerGuard` package
- Test: `t/integration/pubsub.t`

**Interfaces:**
- Produces: `_ControlQueryGuard->new($pubsub, $done)` now also restarts the
  listener on release. `_ListenerGuard` no longer exists.

- [ ] **Step 1: Write the failing test**

Add to `t/integration/pubsub.t` before `done_testing`:

```perl
subtest 'the slot is free before the listener is restarted' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 3,
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('order_seed', sub { })->get;

    # Whatever restarts the listener must see a free slot. Two guards
    # destroyed in reverse declaration order restart it while the slot is
    # still claimed, which Task 3's derived pause turns into a listener that
    # exits immediately and is never started again.
    my $slot_at_restart = 'unset';
    no warnings 'redefine';
    my $orig = Async::DBD::Pg::PubSub->can('_start_listener');
    local *Async::DBD::Pg::PubSub::_start_listener = sub {
        my ($ps) = @_;
        $slot_at_restart = $ps->{_control_query} ? 'HELD' : 'free';
        return $ps->$orig;
    };

    $pubsub->listen('order_probe', sub { })->get;

    is $slot_at_restart, 'free',
        'the control-query slot was released before the listener restarted';

    $pubsub->disconnect->get;
};
```

- [ ] **Step 2: Run it and watch it fail**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
  TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
  prove -l -It/lib t/integration/pubsub.t
```

Expected: FAIL with `HELD` — the listener restarts while the slot is claimed.

- [ ] **Step 3: Fold the restart into `_ControlQueryGuard::release`**

In the `_ControlQueryGuard` package, replace `release` with:

```perl
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

    return unless $pubsub && $pubsub->{connected};

    my $started = $pubsub->_start_listener;
    $started->on_fail(sub {
        my ($err) = @_;
        $pubsub->_log(warn => "Could not restart listener: $err");
    });
}
```

- [ ] **Step 4: Delete `_ListenerGuard` and its construction**

Remove the entire `package Async::DBD::Pg::PubSub::_ListenerGuard;` block, and
in `_run_control_query` remove the line
`my $listener = Async::DBD::Pg::PubSub::_ListenerGuard->new($self);` together
with the comment above it describing what that guard did.

- [ ] **Step 5: Run the file**

Same command as Step 2. Expected: PASS, all subtests including the new one.

- [ ] **Step 6: Commit**

```bash
git add lib/Async/DBD/Pg/PubSub.pm t/integration/pubsub.t
git commit -m "Free the control-query slot before restarting the listener"
```

---

### Task 2: One phase replaces two flags

`{_stopping}` and `{_tearing_down}` both mean teardown, and can disagree —
`_establish` resets the first and never touches the second. Replace both with a
single `{phase}`.

**Files:**
- Modify: `lib/Async/DBD/Pg/PubSub.pm` — `new`, `_establish`, `_listener_loop`,
  `_start_listener`'s `on_fail`, `_reconnect_loop`, `_run_control_query`,
  `disconnect`, `_pool_shutdown`
- Test: `t/integration/pubsub.t`, `t/unit/pubsub.t`

**Interfaces:**
- Consumes: the merged guard from Task 1.
- Produces: `$self->{phase}` with values `disconnected`, `connecting`, `live`,
  `closing`. `is_connected` returns `$self->{phase} eq 'live'`.
  `_pubsub_in_phase($pg, $phase)` test helper in `t/unit/pubsub.t`.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'phase reports the lifecycle, and teardown cannot disagree with itself' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 3,
    );
    my $pubsub = $pg->pubsub;

    is $pubsub->{phase}, 'disconnected', 'starts disconnected';

    $pubsub->listen('phase_probe', sub { })->get;
    is $pubsub->{phase}, 'live', 'live once connected';
    ok $pubsub->is_connected, 'and is_connected agrees';

    $pubsub->disconnect->get;
    is $pubsub->{phase}, 'disconnected', 'disconnected after teardown';
    ok !$pubsub->is_connected, 'and is_connected agrees';
};
```

- [ ] **Step 2: Run it and watch it fail**

Expected: FAIL on `'starts disconnected'` — `{phase}` does not exist.

- [ ] **Step 3: Replace the flags**

In `new`, replace the `_stopping`/`_tearing_down`/`_listener_paused`
initialisers with `phase => 'disconnected',` (keep `_listener_paused` for now;
Task 3 removes it).

Then translate every site, mechanically:

| was | becomes |
| --- | --- |
| `$self->{_stopping} = 1` (in `disconnect`, `_pool_shutdown`) | `$self->{phase} = 'closing'` |
| `$self->{_tearing_down} = 1` | *(delete the line — `closing` covers it)* |
| `$self->{_stopping} = 0; $self->{_tearing_down} = 0;` (disconnect's exits) | `$self->{phase} = 'disconnected'` |
| `$self->{_stopping} = 0` (in `_establish`) | `$self->{phase} = 'live'` |
| `if ($self->{_tearing_down})` (in `_run_control_query`) | `if ($self->{phase} eq 'closing')` |
| `return if $self->{_stopping}` (listener `on_fail`) | `return if $self->{phase} ne 'live'` |
| `while (!$self->{_stopping})` (in `_reconnect_loop`) | `while ($self->{phase} ne 'closing')` |
| `last if $self->{_stopping}` (in `_reconnect_loop`) | `last if $self->{phase} eq 'closing'` |
| `$self->{_stopping} \|\| $self->{_listener_paused}` (in `_listener_loop`) | `$self->{phase} ne 'live' \|\| $self->{_listener_paused}` |

Change `is_connected` to `sub is_connected { shift->{phase} eq 'live' }`, then
`grep -n 'connected' lib/Async/DBD/Pg/PubSub.pm` and translate **every**
remaining site — reads become `{phase} eq 'live'`, `= 1` becomes
`{phase} = 'live'`, `= 0` becomes `{phase} = 'disconnected'`.

One is easy to miss because it is not spelled `$self->`: the
`return unless $pubsub && $pubsub->{connected};` that Task 1 moved into
`_ControlQueryGuard::release`. Grep rather than working from this list — the
whole point of the phase is that no site keeps its own opinion of the lifecycle.

**One site in that grep must not be translated.** `connect()` has a *lexical*
`my $connected = eval { await $attempt->without_cancel; 1 };` and its
`unless ($connected)` — that is a success flag for the eval, not lifecycle
state, and a blind replace will break the cancellation translation Task 3 of the
previous branch added.

- [ ] **Step 4: Translate the internal-state assertions**

In `t/integration/pubsub.t`, three assertions read `{_stopping}`. Translate each:

```perl
is $pubsub->{_stopping}, 0, 'listener not left in the stopping state';
```
becomes
```perl
isnt $pubsub->{phase}, 'closing', 'listener not left mid-teardown';
```

In `t/unit/pubsub.t`, replace direct `{connected}` assignment with a helper.
Add near the top of that file:

```perl
# Builds a PubSub in a given phase without going through a real connection,
# so unit tests do not have to know which keys represent which lifecycle state.
sub _pubsub_in_phase {
    my ($pg, $phase) = @_;
    my $pubsub = $pg->pubsub;
    $pubsub->{phase} = $phase;
    return $pubsub;
}
```

and route the existing constructions through it.

- [ ] **Step 5: Run both files**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
  TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
  prove -l -It/lib t/integration/pubsub.t t/unit/pubsub.t
```

Expected: PASS, all subtests. **If a behavioural subtest fails, stop and
report** — this task must not change behaviour.

- [ ] **Step 6: Mutation-verify each translated assertion**

For each of the three translated assertions, break the thing it guards in a
scratch copy of `lib/` (loaded with `-I`, not `-l`, `%INC` confirmed) and
confirm it goes red. Isolated scenario, bounded `timeout`. Report which mutation
you used for each.

- [ ] **Step 7: Commit**

```bash
git add lib/Async/DBD/Pg/PubSub.pm t/integration/pubsub.t t/unit/pubsub.t
git commit -m "Replace the teardown booleans with one lifecycle phase"
```

---

### Task 3: The listener's pause becomes derived

`{_listener_paused}` is set by `_stop_listener` and cleared by the guard. That
pairing has already produced one bug — a direct `_stop_listener` call from
`disconnect()` set it with nothing to clear it, so a later reconnect came back
healthy and never delivered again. The listener should pause exactly when
something holds the connection, and `{_control_query}` already means that.

**Files:**
- Modify: `lib/Async/DBD/Pg/PubSub.pm` — `new`, `_listener_loop`,
  `_stop_listener`, `_establish`, `disconnect`, `_ControlQueryGuard::release`
- Test: `t/integration/pubsub.t`

**Interfaces:**
- Consumes: `{phase}` from Task 2, the merged guard from Task 1.
- Produces: `{_listener_paused}` no longer exists.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'a listener paused by a control query resumes without a flag reset' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 3,
    );
    my $pubsub = $pg->pubsub;

    my @got;
    $pubsub->listen('resume_probe', sub { push @got, $_[1] })->get;

    # A control query pauses the listener for its duration. Nothing outside
    # the guard should have to put anything back for delivery to resume.
    $pubsub->listen('resume_other', sub { })->get;

    $pubsub->notify('resume_probe', 'after')->get;
    ok wait_until(sub { @got }, 'notification arrived', 5),
        'delivery resumes after a control query without any flag being reset';

    $pubsub->disconnect->get;
};
```

- [ ] **Step 2: Run it and confirm it passes already**

Expected: PASS. This subtest guards a property that is currently correct; it
must still hold after the change. Do not treat its passing as a problem.

- [ ] **Step 3: Derive the pause**

In `_listener_loop`, replace the loop condition and the in-loop check:

```perl
    # Pause exactly while something holds this connection. Reading the slot
    # rather than a flag someone sets means there is nothing to leave behind:
    # a paused listener resumes because the holder released, not because a
    # second code path remembered to clear a boolean.
    while ($self->{phase} eq 'live' && !$self->{_control_query}) {
        await Future::IO->poll($sock, POLLIN);
        last unless $self->{phase} eq 'live' && !$self->{_control_query};
        $self->_process_notifications($conn);
    }
```

In `_stop_listener`, delete `$self->{_listener_paused} = 1;` and the comment
above it. In `_establish`, delete `delete $self->{_listener_paused};` and its
comment. In `disconnect`, delete both `delete $self->{_listener_paused};` lines.
In `new`, delete the `_listener_paused => 0,` initialiser.

- [ ] **Step 4: Run the file**

Expected: PASS, all subtests. Two existing subtests mention
`{_listener_paused}` in comments; update those comments to describe the derived
condition rather than the flag.

- [ ] **Step 5: Mutation-verify the derivation**

In a scratch copy, change the loop condition to ignore the slot
(`while ($self->{phase} eq 'live')`). The listener then polls a connection a
control query is using. Confirm which subtest goes red and report it. If none
does, say so — that would mean the pause is unobserved and needs a test of its
own before this ships.

- [ ] **Step 6: Commit**

```bash
git add lib/Async/DBD/Pg/PubSub.pm t/integration/pubsub.t
git commit -m "Derive the listener's pause from the control-query slot"
```

---

### Task 4: Establish, then publish

`_establish` publishes `{conn}` and only afterwards does `_reconnect_loop`
replay the channels — through `_run_control_query`, on a connection every other
caller can already reach. That is what makes replay race an ordinary `listen()`.
Subscribing before publishing removes the contention rather than serializing it.

**Files:**
- Modify: `lib/Async/DBD/Pg/PubSub.pm` — `_establish`, `_reconnect_loop`
- Test: `t/integration/pubsub.t`

**Interfaces:**
- Consumes: `{phase}` from Task 2.
- Produces: `_establish` subscribes every channel before publishing `{conn}`.
  `_reconnect_loop` no longer replays or starts the listener.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'a connection is fully subscribed before anyone can see it' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 4,
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('publish_a', sub { })->get;
    $pubsub->listen('publish_b', sub { })->get;

    # Whenever {conn} becomes visible, every registered channel must already
    # be subscribed on it. Sampling at publish time is the only moment that
    # distinguishes subscribe-then-publish from publish-then-replay.
    my @channels_at_publish;
    no warnings 'redefine';
    my $orig = Async::DBD::Pg::PubSub->can('_start_listener');
    local *Async::DBD::Pg::PubSub::_start_listener = sub {
        my ($ps) = @_;
        my $dbh = $ps->{conn} && $ps->{conn}->dbh;
        @channels_at_publish = $dbh
            ? @{ $dbh->selectcol_arrayref('SELECT pg_listening_channels()') }
            : ();
        return $ps->$orig;
    };

    $pubsub->disconnect->get;
    $pubsub->connect->get;

    is [sort @channels_at_publish], ['publish_a', 'publish_b'],
        'every channel was subscribed before the connection was published';

    $pubsub->disconnect->get;
};
```

- [ ] **Step 2: Run it and watch it fail**

Expected: FAIL — `@channels_at_publish` is empty, because subscription happens
after publication today.

- [ ] **Step 3: Subscribe before publishing**

Replace `_establish`'s body:

```perl
async sub _establish {
    my ($self, $pool) = @_;

    $self->{phase} = 'connecting';

    # Subscribed here, on a connection still held only in this lexical.
    # Nothing else can reach it, so this needs no serialization and cannot
    # race a caller -- which is what replaying onto a published connection
    # did. Callers see either the previous connection or a complete one.
    my $conn = await $pool->connection;
    await $conn->query("LISTEN " . $conn->dbh->quote_identifier($_))
        for sort keys %{ $self->{channels} };

    $self->{conn}  = $conn;
    $self->{phase} = 'live';

    await $self->_start_listener;

    return $self;
}
```

- [ ] **Step 4: Remove the replay from `_reconnect_loop`**

Delete the replay loop and the `_start_listener` call that follow
`await $self->connect;`, together with the long comment explaining why the
replay went through `_run_control_query`. The eval body becomes
`await $self->connect; 1;`.

- [ ] **Step 5: Run the file**

Expected: PASS, all subtests. In particular
`'a reconnect racing a listen takes only one connection'` and
`'a channel subscribed before the race still delivers'` must still pass — they
are the behaviour this task preserves by a different mechanism.

- [ ] **Step 6: Mutation-verify**

In a scratch copy, move the subscription loop back to after
`$self->{conn} = $conn;`. Confirm the new subtest goes red. Isolated scenario,
bounded `timeout`.

- [ ] **Step 7: Run the file 20 times**

```bash
for i in $(seq 1 20); do
  impl=$([ $((i % 2)) -eq 0 ] && echo IOAsync || echo UV)
  source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
    PERL_FUTURE_IO_IMPL=$impl TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
    prove -l -It/lib t/integration/pubsub.t > /tmp/ph-$i.out 2>&1
done
grep -L '^Result: PASS' /tmp/ph-*.out | wc -l
```

Expected: `0`. Report the count and confirm nothing else touched the database.

- [ ] **Step 8: Commit**

```bash
git add lib/Async/DBD/Pg/PubSub.pm t/integration/pubsub.t
git commit -m "Subscribe a connection fully before publishing it"
```

---

### Task 5: Teardown iterates one registry

Teardown currently cancels four things by name. Forgetting one is how the
Critical on the previous branch happened — `disconnect()` did not know
`{_control_query_inflight}` existed. A registry does not prevent that, but it
makes the common mistake benign: forget to deregister and teardown cancels an
already-ready future, which is a no-op.

**Files:**
- Modify: `lib/Async/DBD/Pg/PubSub.pm` — `new`, `connect`, `_start_listener`,
  the `on_fail` that starts the supervisor, `_run_control_query`, `disconnect`,
  `_pool_shutdown`
- Test: `t/integration/pubsub.t`

**Interfaces:**
- Consumes: `{phase}` from Task 2.
- Produces: `$self->_track($name, $future)` registers a cancellable future in
  `$self->{_inflight}{$name}` and deregisters it on ready.
  `$self->_cancel_inflight` cancels everything registered.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'teardown cancels everything in flight, whatever it is' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 3,
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('registry_seed', sub { })->get;

    # Anything long-lived registers itself, so teardown does not have to know
    # each mechanism by name -- which is how an in-flight control query was
    # missed once already.
    $pubsub->{_inflight}{probe} = my $probe = Future->new;

    $pubsub->disconnect->get;

    ok $probe->is_ready, 'a registered future was cancelled by teardown';
    is scalar keys %{ $pubsub->{_inflight} || {} }, 0,
        'and the registry is empty afterwards';
};
```

- [ ] **Step 2: Run it and watch it fail**

Expected: FAIL on `'a registered future was cancelled by teardown'` — nothing
reads `{_inflight}`.

- [ ] **Step 3: Add the registry**

In `new`, add `_inflight => {},`. Then add these two methods next to `_log`:

```perl
# One place teardown looks. Registering is the mechanism's job; deregistering
# happens on completion, and forgetting to is harmless -- teardown cancelling
# an already-ready future does nothing.
sub _track {
    my ($self, $name, $future) = @_;

    $self->{_inflight}{$name} = $future;

    my $weak = $self;
    weaken($weak);
    $future->on_ready(sub {
        my $live = $weak or return;
        delete $live->{_inflight}{$name};
    });

    return $future;
}

sub _cancel_inflight {
    my ($self) = @_;

    my $inflight = delete $self->{_inflight} or return;
    $self->{_inflight} = {};

    for my $future (values %$inflight) {
        $future->cancel unless $future->is_ready;
    }

    return;
}
```

- [ ] **Step 4: Route the existing mechanisms through it**

In `connect`, after `$self->{_connecting} = $attempt;` add
`$self->_track(connecting => $attempt);`. In `_start_listener`, after
`$self->{_listener_future} = $listener;` add
`$self->_track(listener => $listener);`. Where the supervisor is started, after
`$self->{_reconnect_future} = $reconnecting;` add
`$self->_track(reconnect => $reconnecting);`. In `_run_control_query`, after
`$self->{_control_query_inflight} = $query;` add
`$self->_track(control_query => $query);`.

In `disconnect` and `_pool_shutdown`, replace the four individual
`if (my $f = delete $self->{...}) { $f->cancel unless $f->is_ready }` blocks
with a single `$self->_cancel_inflight;` placed where the first of them was —
before `{conn}` is released, which is the ordering the Critical turned on.

- [ ] **Step 5: Run the file**

Expected: PASS, all subtests. The subtests that assert
`$pubsub->{_reconnect_future}` and `$pubsub->{_control_query}` still hold —
those keys remain; the registry holds a second reference, not a replacement.

- [ ] **Step 6: Mutation-verify**

In a scratch copy, make `_cancel_inflight` a no-op. Confirm the C1 regression
test from the previous branch —
`'disconnecting cancels a control query in flight, not abandons it'` — goes red,
and that the new registry subtest does too. Isolated scenario, bounded
`timeout`, since one of them hangs.

- [ ] **Step 7: Full verification**

Run the whole suite 8 times, alternating implementations, streams to separate
files, and report each run's result and stderr byte count.

- [ ] **Step 8: Commit**

```bash
git add lib/Async/DBD/Pg/PubSub.pm t/integration/pubsub.t
git commit -m "Give teardown one registry instead of four names"
```

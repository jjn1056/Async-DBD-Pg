# One connect attempt, shared by everyone who needs it

Design for gaps item 65: the pub/sub listener can end up with two server
connections, one of which is orphaned permanently and one of which stops
delivering notifications.

## What is broken

Two independent paths decide the listener needs a connection, and neither
checks the other before acting.

`connect()` shares concurrent explicit callers through `{_connecting}`.
`_reconnect_loop`, the background supervisor started when a live listener
dies, has its own separate check:

```perl
unless ($self->{connected} && $self->{conn}) {
    $self->{conn}      = await $pool->connection;
    $self->{connected} = 1;
}
```

That is check-then-act. Evaluating the condition and completing the checkout
are two moments, and the sub suspends between them. If an ordinary `listen()`
is also connecting and has not yet set `{connected}`, the supervisor sees the
same false state and starts a second, independent connect. Whichever
`_establish` finishes last wins by plain assignment, silently discarding the
other.

The existing comment at that branch shows the author knew about this case and
believed the `unless` handled it. It does not. **The fix must remove the
window rather than add another check in front of it.**

### It loses notifications, not just connections

`_listener_loop` reads `$self->{conn}` **once** and polls that socket for the
rest of its life. `_process_notifications`, which the loop calls on every
wakeup, reads `$self->{conn}` **fresh** each time. And `_start_listener`
refuses to start a second loop while one is running.

So the connection that finishes first gets the listener loop bound to its
socket; the one that finishes second overwrites `{conn}` and is refused a loop
of its own. One loop then polls connection A's socket -- so a notification on a
channel `LISTEN`ed there does wake it -- and asks connection B whether anything
is pending. B never has anything. The notification is discarded, with no error,
no log line, and a subscription that still reports itself as active.

For a pub/sub client that is message loss. The orphaned connection is merely
the part that can be proved: `active_count` stays at 1 after `disconnect()`
instead of dropping to 0, because `disconnect()` only releases whatever is
currently in `{conn}`, and the abandoned connection is in no slot the object
tracks.

## What was measured

Three findings, all reproduced before the design was settled. They are recorded
because two of them contradict what the code and its comments assume.

**Cancellation propagates through a shared await, in both directions.** Two
async subs awaiting the same future: cancelling either one cancels the future
itself, and the other completes as *failed*, not cancelled.

**So `connect()` has a second, independent bug, live today.** Two concurrent
callers, the second gives up:

```
first caller: FAILED -- Future::IO::Impl::UV::_Future=HASH(0x...) was cancelled
                        at lib/Async/DBD/Pg/PubSub.pm line 114
```

Line 114 is `await $attempt`. A caller that never gave up fails with an opaque
message because a different caller did.

**Abandoning a lone connect today is clean, and that must be preserved.**
Cancelling the only outstanding `connect()`:

```
before                    active=0 idle=0  connected=no conn=unset
immediately after cancel  active=0 idle=0  connected=no conn=unset
after settling 0.5s       active=0 idle=0  connected=no conn=unset
```

Nothing is checked out, nothing is left connected. Cancellation propagates all
the way down and releases everything. This is correct behaviour and the design
must not regress it.

`Future->without_cancel` protects a shared future from an awaiter's
cancellation, and is available since Future 0.30; this distribution requires
0.49.

## The design

One attempt, owned by the PubSub object, shared by everyone who needs a
connection.

**Every awaiter goes through `connect()`.** The supervisor stops doing its own
checkout: its `unless` branch is deleted, not guarded, and it calls
`connect()` like any other caller. There is then exactly one place in the class
that decides whether a new connection is needed.

This is safe because `connect()`'s check-and-set is already atomic in the
cooperative sense: reading `{_connecting}` and assigning it are separated only
by an async-sub *call*, which returns a future immediately without suspending
the caller. The race exists solely because a second code path bypasses that
slot.

**Awaiters cannot cancel the shared attempt.** Each awaiter awaits
`$attempt->without_cancel` rather than the attempt itself, so a caller giving
up cannot fail the others. This fixes the second bug above.

**The last awaiter to leave cancels the attempt.** A count of live awaiters is
kept alongside `{_connecting}`; when it reaches zero the real attempt is
cancelled. This preserves the clean-abandonment property measured above, which
`without_cancel` alone would regress into an unexpected pool checkout plus a
listener nobody asked for.

The count must decrement when an awaiter is cancelled mid-await, not only when
one completes normally. Anything that must happen on cancellation cannot be
written after an `await` -- a cancelled sub never resumes -- so this belongs in
a guard destructor or an `on_ready` callback, the pattern this class already
uses for clearing `{_connecting}`.

**The listener loop and the notification reader use the same connection.**
`_listener_loop` passes its captured `$conn` into `_process_notifications`
instead of the latter re-reading `{conn}`. Independently of the race, two
functions disagreeing about which connection they are on is a trap for anyone
who reassigns `{conn}` for any reason.

### Error handling

`connect()` becomes load-bearing for two callers with opposite needs: an
explicit caller wants to fail and report, while the supervisor retries in a
loop. Its contract must be stated in its own comment, because a change made for
one caller can otherwise break the other silently.

Specifically, a failure that cannot improve by retrying must not become an
infinite spin. The loop already terminates when the pool is shutting down, and
does so by checking the pool's own state rather than matching the error text --
deliberately, because PostgreSQL raises its own "the database system is
shutting down" during a restart, which a text match would treat as permanent
when it will clear on its own. That reasoning is sound and stays.

A **missing** pool is not covered by it: `$self->{pool} && $self->{pool}{_shutting_down}`
is false when there is no pool at all, so the loop logs and retries forever
against a condition that cannot improve. Once the supervisor routes through
`connect()` -- which dies with `"No pool configured"` in exactly that case --
this becomes the supervisor's only unbounded failure mode. Terminate the loop
when there is no pool, the same way a shut-down pool already terminates it, and
on the same principle: decide on state, not on message text.

When `disconnect()` or pool shutdown cancels the real attempt, awaiters on
protected views fail with `Future=HASH(0x...) was cancelled`. That message
reaches callers, so it is translated into an error that says what happened.

Cancelling the supervisor no longer stops an in-flight checkout, because it now
awaits a protected view. `disconnect()` and `_pool_shutdown` must therefore
cancel `{_connecting}` explicitly as well as the supervisor future.

## Testing

The assertion that matters is that a reconnect racing an explicit `listen()`
produces exactly one connection. Everything else is the space around it.

- Under the forced interleaving, `active_count` returns to 0 after
  `disconnect()`. This is the load-bearing assertion: a delivery timing
  artifact can be argued away, a connection checked out and never returned
  cannot.
- A channel subscribed before the race still delivers after it. This is what
  catches the listener/notification mismatch.
- A caller that gives up while another is connecting does not fail the other.
  This is the `connect()` cancellation bug, and it must fail against the
  current code.
- Abandoning a lone connect still leaves `active_count` at 0 and the object
  disconnected -- the property measured above, which the awaiter count exists
  to preserve.

The race does not reproduce on timing alone; it needs real contention. Force
the interleaving deterministically instead: delay one pool checkout so an
explicit `listen()` is still in flight when the supervisor wakes, with
`reconnect_min_interval` low enough that the supervisor's backoff lands inside
that window. The delay belongs in the test, not in the pool -- production code
does not carry test scaffolding.

Every one of these must be shown to fail against the unfixed code. A test for a
concurrency bug that has never been seen red is not evidence, and this project
has produced nine tests that were green while guarding nothing.

Tests that kill a backend must wait for it to be gone rather than sleeping:
`pg_terminate_backend` sends SIGTERM and returns before the backend exits.

## Out of scope

- **The `Error::Timeout` wrong-class failure** at `t/integration/connection.t:231`,
  where a query under load produced `Error::Query` instead. One occurrence, no
  reproduction, and possibly nothing more than contention. It needs its own
  investigation.
- **Reconnect policy** -- backoff shape, ceilings, whether `reconnect` should
  remain on by default. Unchanged here.
- **Pool-level connect cancellation.** `$pg->connection` produces a
  caller-owned resource and must keep releasing on cancel. Only the pub/sub
  attempt, which is object state rather than a caller's result, changes.

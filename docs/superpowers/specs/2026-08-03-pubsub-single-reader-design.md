# PubSub single-reader design

**Goal:** make the listener the sole poller of the pub/sub connection's socket,
so the pause around every control query can be deleted rather than defended.

## Why

`Future::IO->poll` reports on the **socket**; `pg_ready`, `pg_result` and
`pg_notifies` all consume from the socket into **libpq's internal buffer**.
Two independent pollers on one fd therefore steal each other's readiness: the
first to wake drains the socket, and the second waits forever for a wake that
will never come.

Today two async subs poll the pub/sub connection's fd:

- `Connection::_wait_for_result` — for the in-flight query's result
- `PubSub::_listener_loop` — for notifications

The pause exists solely to guarantee only one of them is ever awake. It works,
and gaps item 71 records the experiment proving it is load-bearing: removing it
without replacing the mechanism deadlocks the first control query under both
`Future::IO::Impl::UV` and `::IOAsync`.

The cost of keeping it is not latency — measured at 1.7 ms during a real
`LISTEN` against a 1.2 ms idle baseline. The cost is mechanism: a stop, a
restart, a slot two code paths must agree about, and the class of bug in gaps
items 67 and 75, both of which were failures to hand the socket back correctly.

Mojo::Pg has no pause because it has no second reader. One `io` watcher on the
socket drains notifications first, then checks whether the in-flight query's
result is ready:

    return $self->_unwatch if !$self->_notifications && !$self->{waiting};
    return if !$self->{waiting} || !do { local $dbh->{RaiseError} = 0; $dbh->pg_ready };
    ...
    my $rv = do { local $dbh->{RaiseError} = 0; $dbh->pg_result };

This design adopts that shape without restructuring `Connection`, which every
pooled query goes through.

## Core idea

A connection may nominate a **poll delegate**. When one is installed,
`_wait_for_result` does not poll — it awaits a future the delegate owns.
Otherwise it polls exactly as today.

    # Connection.pm
    async sub _wait_for_result {
        my ($self, $dbh) = @_;

        return await $self->{_poll_delegate}->($self) if $self->{_poll_delegate};

        my $sock = $self->_get_socket;
        while (!$self->_capture_pg_notices(sub { $dbh->pg_ready })) {
            await Future::IO->poll($sock, POLLIN);
        }
    }

PubSub installs a delegate that hands back a pending future, records it as
`{_query_waiter}`, and lets the listener complete it:

    # PubSub.pm — the whole loop
    while ($self->{phase} eq 'live') {
        $self->_process_notifications($conn);

        if (my $waiter = $self->{_query_waiter}) {
            if ($conn->_result_ready) {
                delete $self->{_query_waiter};
                $waiter->done;
            }
        }

        await Future::IO->poll($sock, POLLIN);
    }

**Invariant: exactly one poller per connection, at all times.** For an ordinary
pooled connection that is the query. For the pub/sub connection it is the
listener, for as long as the listener runs.

## Ownership rules

The delegate's lifetime is **exactly** the listener loop's lifetime. This is
the single rule the whole design rests on, and it is what makes the failure
paths tractable.

| state | fd owner | delegate |
|---|---|---|
| `_establish`, before the listener starts | the `LISTEN` queries themselves | absent |
| listener running | the listener | present |
| listener stopped (teardown, reconnect, failure) | whichever query runs next | absent |
| ordinary pooled connection | the query | never installed |

Consequences that fall out, rather than needing separate mechanism:

- `_establish`'s own `LISTEN` statements self-poll, because the listener has
  not started yet. No bootstrap ordering problem, and no deadlock from a
  delegate with nobody to service it.
- `disconnect`'s `UNLISTEN *` self-polls: `{phase}` is `closing` by then, so
  the loop has exited and taken its delegate with it.
- `notify()` is unaffected — it borrows a *different* pooled connection.

Installation therefore belongs in `_start_listener`, not `_establish`, and
removal belongs on the loop's exit path — every exit path.

## Failure paths

This is the new coupling and the part that needs the most care: a query's
completion now depends on a future owned by something else. Three cases.

**1. The listener stops while a waiter is pending.** Connection dropped,
teardown, cancellation, or the loop failing. The waiter would otherwise hang
forever, which is strictly worse than today's behaviour.

The loop's exit must delete the delegate and fail any pending waiter with
`Async::DBD::Pg::Error::Connection`. It must fire on cancellation too — a
cancelled sub never resumes, so an `eval`'s error path never runs. Use a guard
object whose destructor does both; the codebase already relies on this idiom
for `_CheckoutGuard` and `_ControlQueryGuard`, and for the same reason.

**2. The waiting query is cancelled.** The caller gives up while parked on the
delegate future. `{_query_waiter}` must be cleared, or the listener holds a
stale future and may complete a query nobody is waiting for. Register the
cleanup on the future itself (`on_ready`) so it runs however the future
settles — done, failed or cancelled.

**3. The listener is mid-`_process_notifications` when the query is issued.**
A user callback calling `listen()` claims the control-query slot synchronously
and dispatches. The loop must therefore check the waiter *after* draining
notifications and *before* parking on the socket — which is the order above.
A query dispatched from a callback is checked on the same iteration; if its
result is not ready yet, the loop parks and the server's response wakes it.

## Notice capture

The existing readiness check is wrapped:

    $self->_capture_pg_notices(sub { $dbh->pg_ready })

A PostgreSQL NOTICE emitted by the running statement is delivered while
`pg_ready` reads the socket. The wrap routes it to the connection's notice
handling instead of stderr, which is what keeps test output pristine.

When the listener performs that check on the query's behalf it must preserve
the wrapping, and the notice must be attributed to the **connection**, exactly
as today — not to the pub/sub object and not to a listener log line. The new
accessor exists to keep that wrapping in one place:

    # Connection.pm
    sub _result_ready {
        my ($self) = @_;
        my $dbh = $self->{dbh} or return 0;
        return $self->_capture_pg_notices(sub { $dbh->pg_ready }) ? 1 : 0;
    }

`_wait_for_result`'s own loop should use it too, so there is exactly one
expression of "is the result ready" in the codebase.

## What is deleted

- `_listener_loop`'s two `!$self->{_control_query}` checks, and its `last
  unless` guard — the loop no longer exits for control queries at all
- `await $self->_stop_listener if $self->{_listener_future};` in
  `_run_control_query`
- the listener restart in `_ControlQueryGuard::release`, reducing that class to
  releasing the mutex slot

## What is kept, deliberately

- **The `{_control_query}` mutex.** DBD::Pg still cannot run two async
  operations on one handle, so control queries stay serialized. Only the
  *listener pause* goes; the mutex is a different mechanism that happened to
  share the field.
- **`_stop_listener`.** Still needed by teardown and reconnect. It stops being
  something every control query calls.
- **`_process_notifications` first in the loop.** Gaps item 75. Draining before
  parking is what stops notifications stranding in libpq's buffer, and it is
  also Mojo's order.

## Testing

Every existing pub/sub test must pass unchanged — they are the safety net, and
several were mutation-verified when written.

New coverage, each of which must be shown failing before implementation:

1. A control query completes while the listener is running — the base case that
   deadlocks if the delegate is never completed.
2. Notifications continue to be delivered *while* a control query is in flight.
   Note: PostgreSQL does not send `NOTIFY` to a backend busy running a command
   (measured, gaps item 75), so this asserts delivery is not *blocked* by the
   pause mechanism, not that it arrives mid-statement.
3. The listener dying with a waiter pending fails that query rather than
   hanging it. Bounded assertion, so a regression fails on a time bound rather
   than wedging the suite.
4. Cancelling a control query mid-flight leaves no stale `{_query_waiter}`, and
   the next control query still completes.
5. A user callback issuing `listen()` from inside `_process_notifications`
   completes.
6. An ordinary pooled connection still self-polls — the delegate must never
   leak onto a connection returned to the pool.

The fragmentation experiment (`scratchpad/frag-experiment.pl`) and the latency
probe should both be re-run against the finished branch: 160/160 clean, and
delivery latency no worse than the current 1.7 ms during a real `LISTEN`.

## Risks

- **The coupling is real.** Today a query's completion depends only on itself.
  After this it depends on the listener staying alive. The failure paths above
  are the mitigation, and case 3 is the test that proves it.
- **`_wait_for_result` is on every pooled query's path.** The delegate check is
  one hash lookup on a branch that already exists, and ordinary connections
  never install one — but a mistake here affects all database access, not just
  pub/sub. This is the reason for task-by-task review rather than a single
  commit.
- **DBD::Pg version sensitivity.** The design assumes `pg_ready` reports on
  buffered state rather than requiring fresh socket bytes, which is what makes
  drain-then-check safe. Verified behaviourally against DBD::Pg 3.20.2 by gaps
  item 75's experiment; re-verify if the floor moves.

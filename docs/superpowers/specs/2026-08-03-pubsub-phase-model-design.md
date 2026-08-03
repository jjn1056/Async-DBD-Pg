# One phase, and a connection nobody sees until it works

Design for restructuring `Async::DBD::Pg::PubSub`'s lifecycle state.

## The problem, stated precisely

`PubSub` carries eleven pieces of mutable lifecycle state and three guard
classes. The count is a symptom; the disease is that the object has an implicit
state machine represented as scattered booleans, where every path reads and
writes a subset and nothing owns any of it.

Five bugs on the `pubsub-reconnect-race` branch share one shape — **a boolean
written on one path and read as a signal on another, with no single place
responsible for its lifecycle**:

1. `{_stopping}` meant both "teardown asked me to stop" and "a control query
   paused the listener". The reconnect supervisor read a pause as a shutdown and
   exited permanently, believing it had been told to.
2. Teardown did not know `{_control_query}` existed, so it released the
   connection out from under a suspended query. The frame never ended, the guard
   never fired, and the slot stayed claimed for the life of the object — every
   later `listen()` hung with no error, no log line, no timeout.
3. A caller queued behind the one being torn down was woken synchronously
   *inside* teardown's own cancellation, before `{conn}` was deleted. It issued
   its query on a connection that was then returned to the pool — corrupting it
   for an unrelated third party.
4. `_run_control_query` did not revalidate `{conn}` across its suspension, so a
   woken waiter died on undef rather than reporting a connection error.
5. Splitting `{_stopping}` in two — the fix for (1) — immediately produced
   another of the same kind: `_stop_listener` is called directly by
   `disconnect()`, not only through `_ListenerGuard`, so that call set the new
   flag with nothing to clear it. A later reconnect came back healthy and then
   silently never delivered again.

The fifth appeared while fixing the first, and was caught only because the
implementer checked rather than assumed. That is the argument: not that the
flags are numerous, but that the model admits this bug at all. **A phase
transition is a single assignment and cannot leave the object between states.
None of these five is expressible in that form.**

## What other implementations do

Checked before designing, because a problem this persistent is usually one
somebody else has already refused to have.

| | control queries | concurrent ops | replay on reconnect |
| --- | --- | --- | --- |
| Mojo::Pg | synchronous `$dbh->do` | `croak 'Non-blocking query already in progress'` | inside `db()`, before the connection is visible |
| asyncpg | `await self.fetch('LISTEN ...')` | `InterfaceError: another operation is in progress` | none — `_cleanup()` clears listeners |
| this distribution | async, serialized by a mutex | serialized | onto a live connection |

Two mature clients, one synchronous and one fully async, independently made the
same two choices: **refuse concurrent operations rather than serialize them**,
and **never replay subscriptions onto a connection callers can already reach**.

We do the opposite on both counts, and that is where the complexity came from.

The idea worth taking is not "be synchronous" — that is Mojo's answer to a
different question, and blocking the reactor for a round trip per `LISTEN`
contradicts what this distribution is for. It is that **`db()` returns a
connection that is already fully subscribed.** Re-subscription is not a phase
that races anything; it is part of construction.

Refusing concurrent operations is right for asyncpg, whose callers await
sequentially, and wrong here: `Future->wait_all($ps->listen(a), $ps->listen(b))`
is the natural idiom in a Future-based library, and a passing test asserts it
works. So serialization stays — but it becomes a local concern rather than
something reconnect depends on.

## The design

### One phase

A single `{phase}` field replaces the lifecycle booleans:

| phase | meaning |
| --- | --- |
| `disconnected` | no connection, none being established |
| `connecting` | an establishment is in flight |
| `live` | a fully subscribed connection is published |
| `closing` | teardown in progress |

Transitions are single assignments. `{_tearing_down}` becomes
`phase eq 'closing'`; `{_stopping}` becomes `phase ne 'live'`. Both disappear as
stored state. The public `is_connected` accessor becomes `phase eq 'live'`, so
its contract is unchanged.

### The listener's pause is derived, not stored

`{_listener_paused}` is deleted without replacement. The listener should pause
exactly when something holds the connection handle, and `{_control_query}`
already means that:

```perl
while ($self->{phase} eq 'live' && !$self->{_control_query}) { ... }
```

Nothing to set, nothing to clear, nothing to fall out of sync. Bug (5) — a flag
set on one path with nothing to clear it on another — is not expressible here.

### Establish, then publish

`_establish` builds the connection in a lexical, subscribes every channel to it,
and publishes only when complete:

```perl
my $conn = await $pool->connection;
await $conn->query("LISTEN " . $conn->dbh->quote_identifier($_))
    for sort keys %{ $self->{channels} };

$self->{conn}  = $conn;
$self->{phase} = 'live';
await $self->_start_listener;
```

Two things follow. Replay needs no serialization, because `$conn` is a lexical
no other caller can reach — the contention between the supervisor's replay and
an ordinary `listen()` stops existing rather than being managed. And replay no
longer goes through `_run_control_query`, so the stop-listener/restart-listener
dance per channel disappears: there is no listener yet to stop.

A caller arriving during `connecting` awaits the shared attempt as it does
today, then issues its own `LISTEN` against the published connection.

### Teardown owns one list

Teardown sets `phase = 'closing'`, cancels everything in flight, releases the
connection. To stop teardown having to *remember* each mechanism — which is
exactly how bug (2) happened — long-lived futures register in one `{_inflight}`
registry that teardown iterates.

The limit is worth stating plainly: a registry does not prevent forgetting. It
makes the common mistake benign — forget to deregister on completion and
teardown cancels an already-ready future, a no-op — while leaving the rarer one
(forgetting to register) as capable of reproducing bug (2) as before. It is an
improvement on four ad-hoc `if (my $f = delete ...)` blocks, not a proof.

### What survives deliberately

- **`{_connecting}`, `{_connecting_waiters}`, `_AwaiterGuard`** — concurrent
  `connect()` callers still share one attempt, and the last one to abandon still
  cancels it. Self-contained and covered by mutation-verified tests.
- **`{_control_query}`, `{_control_query_inflight}`, `_ControlQueryGuard`** —
  two concurrent user `listen()` calls still need serializing. Now a local
  concern with no reconnect entanglement.
- **`{_listener_future}`, `{_reconnect_future}`** — futures teardown cancels.

Net: eleven lifecycle keys to about eight, and three ambiguous booleans become
one unambiguous field with a derived listener state.

## Migration

The 34 subtests in `t/integration/pubsub.t` are the specification of current
behaviour and must keep passing unchanged wherever they assert behaviour rather
than internals. The coupling to internals is narrower than the count suggests:

| internal | assertions | disposition |
| --- | --- | --- |
| `{_control_query}` | 4 | survives; unchanged |
| `{_reconnect_future}` | 5 | survives; unchanged |
| `{_stopping}` | 3 | translate to `{phase}` |
| `{connected}` | a few, plus `t/unit/pubsub.t` setting it | becomes derived; public `is_connected` unaffected |

So six to eight assertions need rewriting, not thirty-four tests.

Those six are the risk, because a rewritten assertion can be written to pass.
**Each one is mutation-verified against the new code**: break the thing it
guards, confirm it goes red. This branch produced four tests that were green for
a reason other than the one they claimed, two of them in a single fix round; the
discipline that caught those is the discipline that makes this migration
trustworthy.

`t/unit/pubsub.t` constructs objects by setting internals directly
(`{connected} = 0`, `{_listener_future} = ...`). Rather than scattering
`{phase} = 'live'` through the file, add one test helper that builds a `PubSub`
in a given phase, and route those constructions through it.

## Testing

- Every existing behavioural subtest passes unchanged.
- Each rewritten internal-state assertion is mutation-verified individually.
- One new test per collapsed mechanism, proving the collapse: that a `listen()`
  arriving mid-reconnect is subscribed exactly once; that teardown during an
  establishment leaves nothing checked out; that the listener resumes after a
  control query without any flag being reset by hand.
- The full suite passes under both `PERL_FUTURE_IO_IMPL=UV` and `IOAsync` with a
  zero-byte stderr file.

Mutations to functions on this file's hot paths cascade into unrelated subtests
and produce `wait_until` timeout noise that obscures which assertion
discriminated. Run mutations against an isolated scenario under a bounded
`timeout`.

## Out of scope

- **`Async::DBD::Pg`'s connection pool**, including the queue-and-wait branch's
  missing `on_cancel` and lazily spliced waiters (`docs/gaps.md` item 69). Real,
  independent, and touching it widens the blast radius to every consumer of the
  pool. Its own spec.
- **Making control queries synchronous.** Mojo's answer, rejected above: it
  would delete the mutex outright, at the cost of stalling the reactor for a
  round trip per `LISTEN`.
- **Refusing concurrent operations.** asyncpg's answer, rejected above: wrong for
  a Future-based API where concurrent composition is the idiom.

# Healing a connection that died while idle

Design for gaps item 16: a connection that dies while sitting in the idle pool
is handed to the next caller, who discovers it on their first query.

## Why the item's own framing was rejected

The entry asks for validation on checkout. That was considered and turned down
for three reasons.

**It cannot close the window it aims at.** Validation is racy by construction.
A connection that passes a check can die before the caller's first query, so a
check narrows the exposure without removing it. Anything built on "we verified
it, so it is good" is relying on something that was only ever true a moment
ago.

**It is expensive on the hottest path in the pool.** `DBD::Pg`'s `ping` sends a
real statement to the server; it is a round trip, not a local check. Item 14
removed exactly that round trip from `DESTROY`, which is a far colder path than
checkout.

**The pools worth copying do not do it.** node-postgres does not validate on
acquire, and neither does asyncpg; both rely on failures surfacing and on idle
eviction. HikariCP does validate, but with a bypass window that skips recently
used connections, and it is a synchronous pool where a blocking probe costs
nothing extra.

Three mechanisms already bound the exposure here: the liveness check when a
connection is released, the idle reaper closing anything idle beyond
`idle_timeout`, and `max_queries` retiring long-lived connections.

So rather than trying to prevent a dead connection being handed out, make it
recoverable. The caller never sees it, and the race that validation cannot
close is closed, because the recovery happens at the moment of use rather than
before it.

## What is retried, and what is never retried

The pivot is whether the statement could have reached the server.

`prepare` and `execute` run before anything is dispatched — with `pg_async`,
`execute` is what sends the statement. So:

- A failure at `prepare` or `execute` means nothing was sent. **Retryable.**
- Once `execute` has succeeded the statement is on the wire, and a later
  failure at `pg_result` may mean it ran. **Never retryable**, whatever it
  looks like.

That distinction is the whole safety argument. A retry that could re-run a
statement which already executed would turn a rare inconvenience into
duplicated writes.

A failure at `prepare` or `execute` is not on its own evidence of a dead
connection; a syntax error fails there too. The test is whether the connection
survived: `ping` it. A dead connection fails, a syntax error does not. That is
a round trip, but only on a path that has already failed, and it is the same
check the pool performs on release.

### Three cases that are never retried, even when the send provably failed

- **Inside a transaction.** If the connection died, the transaction died with
  it. Retrying on a healed connection would silently run the statement outside
  the caller's transaction: correctness lost while appearing to help. The error
  propagates instead. This covers open cursors too, since a cursor lives only
  inside its transaction.
- **While the pool is shutting down.** Nothing is healed; the error
  propagates.
- **On the retry itself.** Exactly one attempt. A server that is genuinely
  unreachable surfaces its error rather than being retried in a loop.

## Healing in place

The caller holds a `Connection`. Retrying on a different connection would leave
them holding the dead one, so the connection they already have is what must be
healed.

This is the same technique rejected in the pub/sub reconnect design, and the
distinction is the constraint rather than the technique. There, the supervisor
held no caller-visible handle and could simply take a fresh connection from the
pool. A caller in the middle of `query` cannot.

The objection that mattered — duplicated connect logic and bypassed pool
accounting — is answered by construction:

- The replacement handle is built by the pool through the **existing** connect
  path, so async connect, `on_connect` and `statement_timeout` all apply, and
  there is no second copy of connect logic to drift.
- The `Connection` object never leaves the `active` list, so no pool counts
  move. The dead handle is closed and counted as discarded; its replacement is
  counted as created.

It is reported through `_log`. A pool that silently heals is a pool that hides
a flapping database, and the point of `on_log` is that operators can see this
sort of thing.

## Public interface

On by default. A stale pooled connection failing a caller's first query is a
defect in the pool, not a situation the caller should have to code around, and
the retry only fires where the statement provably never reached the server.

One option on the pool constructor:

| option | default | meaning |
| --- | --- | --- |
| `heal_dead_connections` | `1` | replace a connection that was already dead and retry once |

Set it false to have the original error propagate untouched.

No new methods, and no change to any existing signature. A caller who never
encounters a dead connection cannot tell this exists.

## Testing

The assertion that matters is that the caller never sees the failure: check a
connection out, kill its backend from a separate connection, run a query, and
get a result. Everything else is the negative space around it, and the negative
cases are the ones that would hurt if they were wrong:

- No retry inside a transaction. The error propagates, and the statement does
  not run on a healed connection.
- No retry on a syntax error, where the connection is alive. It fails once,
  reporting the server's own message.
- No retry once `execute` has succeeded, even if the connection dies while the
  result is awaited.
- Exactly one attempt against a server that stays unreachable.
- No healing while the pool is shutting down.
- The pool's counts are unchanged across a heal, and the healed connection
  works for subsequent queries.

Killing a backend makes libpq write a notice straight to file descriptor 2, so
any test that does it captures and asserts that output, as the existing suite
does.

## Out of scope

- Validation on checkout, in any form. Rejected above.
- Retrying a statement that may have reached the server, including read-side
  connection loss. This would need to distinguish statements that are safe to
  repeat, which cannot be inferred reliably from SQL.
- Healing a connection that is inside a transaction, which would require
  replaying the transaction and is a different feature.

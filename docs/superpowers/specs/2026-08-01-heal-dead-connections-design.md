# Healing a connection that died while idle

Design for gaps item 16: a connection that dies while sitting in the idle pool
is handed to the next caller, who discovers it on their first query.

## What the item asked for, and what this does instead

The entry asks for validation on checkout. What it means by that -- and what
was rejected -- is pinging the server every time a connection is handed out.

**A ping on every checkout is expensive on the pool's hottest path.**
`DBD::Pg`'s `ping` sends a real statement; it is a round trip, not a local
check. Item 14 removed exactly that round trip from `DESTROY`, which is a far
colder path than checkout.

**The pools worth copying do not do it.** node-postgres does not validate on
acquire, and neither does asyncpg; both rely on failures surfacing and on idle
eviction. HikariCP does validate, but it is a synchronous pool where a blocking
probe costs nothing extra, and it skips the check for recently used
connections.

Three mechanisms already bound the exposure: the liveness check when a
connection is released, the idle reaper closing anything idle beyond
`idle_timeout`, and `max_queries` retiring long-lived connections.

What this design does is check, but not by asking the server. A connection
taken from the idle list is inspected locally before its first statement is
sent, at no cost, and only a connection that already looks wrong is pinged to
confirm. So the item's instinct was right and its proposed mechanism was the
expensive one; the section below explains how the check became free, and why
it had to happen before dispatch rather than after a failure.

## What other pools do

Checked before settling the defaults, because retrying a statement is not a
common choice and it would be worth knowing if everyone else had rejected it.

| pool | on checkout | on finding a dead connection |
| --- | --- | --- |
| SQLAlchemy | `pool_pre_ping`, off by default | the active request fails; that connection and **every other idle connection** are invalidated |
| HikariCP | validates by default, `isValid()` | evicts and replaces; retrying the statement is an open feature request, not a feature |
| node-postgres | does not validate | does not retry |
| asyncpg | does not validate | does not retry |
| EF Core | not applicable | `EnableRetryOnFailure`, opt in, documented with idempotency warnings |

Two conclusions.

**Nobody retries the statement**, and where retrying exists at all it is opt
in. An earlier version of this design did retry, on the argument that its
boundary was narrower than EF Core's. Testing removed the question: the failure
this feature addresses cannot be distinguished from a statement that already
ran, so there is no safe boundary to retry within, and the design checks before
dispatching instead. The consensus turned out to be right for a reason this
design had not yet found.

**Everyone invalidates more than the connection they found.** SQLAlchemy is
explicit: a disconnect invalidates the whole idle set. This design originally
missed that, and it matters. A server restart kills every pooled connection at
once, so healing them one at a time means the second caller reconnects, and the
third, and so on, when a single sweep would have dealt with all of them. Added
below.

## Detecting the death before anything is sent

The first version of this design was wrong, and testing is what established
it. It assumed a statement on a dead connection fails at `prepare` or
`execute`, so a failure there proved nothing had been sent and could safely be
retried.

That is not what happens. Measured against a backend killed while its
connection sat idle:

```
prepare  : SUCCEEDED
execute  : SUCCEEDED
pg_result: FAILED  FATAL: terminating connection due to administrator command
```

Writing to a socket whose peer has gone lands in the local send buffer and
reports success; nothing notices until something reads. So the failure surfaces
at `pg_result` — precisely the point where a statement may already have run,
and therefore the one point where retrying is never safe. The boundary the
design rested on was real but unreachable for the case the feature exists to
handle.

**So the connection is checked before the statement is dispatched, not after
it fails.** A healthy idle connection has nothing waiting to be read. One whose
server has gone away is readable, because the peer's close is sitting there:

```
while healthy         pg_socket=3  readable=no
after backend killed  pg_socket=3  readable=YES
```

That check is a zero-timeout `select` on a descriptor already to hand. It costs
nothing, needs no round trip, and happens only on the first statement after a
connection is taken from the idle list — a connection just built cannot be
stale, and one already in use has proved itself.

A readable socket is suggestive rather than conclusive: an asynchronous
notification would also make it readable, if an application ran `LISTEN` on a
pooled connection. So the free check gates a `ping`, and only a failed `ping`
condemns the connection. The round trip happens only when something is already
known to be wrong.

This removes retrying from the design entirely. The statement is dispatched
once, onto a connection already known to be good, so the question of whether it
ran can never arise. `DBI` does not help here — `Active` stays true on a dead
connection — which is why the socket is consulted directly.

### What is still never done

- **Healing a connection inside a transaction.** The transaction died with the
  connection, and continuing on a replacement would run the caller's
  statements outside the transaction they asked for. The check is skipped and
  the failure reaches the caller. As the code stands, this guards a case that
  cannot arise rather than one that merely shouldn't: the check is armed only
  by an idle checkout and consumed by the very next `query` call, whatever it
  is. If that call is the `BEGIN` a transaction issues, it runs before
  `in_transaction` is set, so the flag is never true while the check is still
  armed — and a connection already in a transaction is never returned to the
  idle list in the first place, closing the only other route. Confirmed by
  removing the guard in a scratch copy of the module and finding no test's
  behavior changes. It stays, because the reasoning above depends on how
  `_check_liveness` happens to be scoped today, and a later change to arm the
  check more than once per checkout would make this guard load-bearing
  without necessarily updating this note.
- **Healing while the pool is shutting down.** Unlike the transaction case,
  this one is reachable in real use, not just guarded defensively: a
  connection can be checked out from idle (arming the check) while the pool
  is healthy, and then have `shutdown` start while it is still held —
  `shutdown` waits for checked-out connections rather than touching them, so
  the caller's first statement on that same connection can land after
  `_shutting_down` has gone true. The pool's own drain against a live caller
  is exactly this race.
- **Touching the `pg_result` path.** A failure there may mean the statement
  ran. It is reported to the caller exactly as before.

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

## Invalidating the connections we did not touch

Whatever killed the connection we found — a restart, a failover, an
administrator — almost certainly killed the rest of the pool with it. Healing
only the one in hand leaves every other idle connection dead and waiting to be
discovered the same way, one caller at a time.

So on detecting a dead connection, the pool also discards its **idle**
connections. They are closed and counted as discarded, and the pool refills
towards `min_connections` as usual, so the next caller gets a fresh connection
rather than repeating this discovery.

Connections currently checked out are left alone. Their owners are mid-work,
the pool cannot know whether they are usable, and each will heal itself on its
next statement by exactly the path above. Reaching into a connection somebody
else is holding to close it underneath them would be worse than the problem.

This is the part of SQLAlchemy's optimistic handling worth copying: one
disconnect invalidates the idle set rather than being rediscovered N times.

## Public interface

On by default. A stale pooled connection failing a caller's first query is a
defect in the pool, not a situation the caller should have to code around, and
the retry only fires where the statement provably never reached the server.

One option on the pool constructor:

| option | default | meaning |
| --- | --- | --- |
| `heal_dead_connections` | `1` | replace a connection found dead before its first statement is sent |

Set it false to have the original error propagate untouched.

No new methods, and no change to any existing signature. A caller who never
encounters a dead connection cannot tell this exists.

## Testing

The assertion that matters is that the caller never sees the failure: check a
connection out, kill its backend from a separate connection, run a query, and
get a result. Everything else is the negative space around it, and the negative
cases are the ones that would hurt if they were wrong.

Two different things back these negative cases, and mutation testing — not
just reading the code — is what tells them apart:

- **Enforced by a guard, and demonstrated red by mutation.** Only
  `heal_dead_connections` is in this category. Removing its guard in a
  scratch copy of `_heal_if_dead`, loaded ahead of the real module, turns the
  "healing can be turned off" test red and leaves every other test green.
  This one is reachable, and that is what proves it, not the source reading
  as though it should be.
- **Hold structurally, because `_check_liveness` is set only on an idle
  checkout and consumed by the very next `query` call.** No test connection
  that starts a transaction, has its statement already sent, or is checked
  mid-shutdown was ever idle-checked-out first, so none of them ever arm the
  check — `_heal_if_dead` is never called at all, guard or no guard.
  Removing the `in_transaction` or `_shutting_down` guards in the same
  scratch-module exercise leaves every test green, confirming this rather
  than merely asserting it. The three structural cases are not all equally
  structural, though:
  - The transaction case is the strongest: it is provably unreachable as the
    code stands (see "What is still never done" above), not merely untested.
  - The shutting-down case is reachable in real use — a connection checked
    out before `shutdown` is called and used for the first time after it
    isn't — the suite just doesn't currently construct that sequence.
  - The already-sent case has no guard to remove at all, because nothing in
    `_execute_async` calls `_heal_if_dead`. A mutation that reintroduced such
    a call after `pg_result` fails was tried and was not caught — not because
    of protection, but because `pg_socket` is already invalid by the time
    DBD::Pg has finished processing a fatal disconnect. A differently-shaped
    reintroduction of the same mistake is not ruled out by anything visible
    here.

With that distinction in mind, the individual cases:

- No healing inside a transaction. The error propagates, and no statement runs
  on a replacement connection. (Structural, and provably unreachable — see
  above.)
- A syntax error on a live connection is reported as itself. The socket is not
  readable, so the check costs nothing and concludes nothing — that is the
  mechanism when this connection has been idle-checked-out. The test for it
  in the current suite uses a freshly built connection instead, so it does
  not currently exercise that mechanism either; it establishes the same
  observable outcome (a syntax error is reported as itself) without
  exercising `_heal_if_dead` at all.
- A connection that dies while its result is awaited fails to the caller. That
  statement reached the server and may have run, and nothing about it is
  repeated. (Structural, and the weakest of the three — see above.)
- A healthy connection is never pinged. The free check is what decides whether
  the round trip happens at all, and on a healthy pool it never does.
- No healing while the pool is shutting down. (Structural in the current
  suite, but reachable in real use — see above.)
- The pool's counts are unchanged across a heal, and the healed connection
  works for subsequent queries.
- Idle siblings are discarded when a dead connection is found, so a second
  caller after a server restart is served a fresh connection rather than
  discovering another dead one. Connections checked out by other callers are
  left in place.

Killing a backend makes libpq write a notice straight to file descriptor 2, so
any test that does it captures and asserts that output, as the existing suite
does.

Test descriptions state the observable behavior a test establishes, not the
mechanism believed to produce it. Several of the negative-case test names
originally implied a guard was exercised when the connection in question was
never idle-checked-out at all, so the guard was never reached; the descriptions
were corrected once mutation testing surfaced this, rather than left to imply
coverage the tests do not have.

## Out of scope

- Validation on checkout, in any form. Rejected above.
- Retrying a statement that may have reached the server, including read-side
  connection loss. This would need to distinguish statements that are safe to
  repeat, which cannot be inferred reliably from SQL.
- Healing a connection that is inside a transaction, which would require
  replaying the transaction and is a different feature.

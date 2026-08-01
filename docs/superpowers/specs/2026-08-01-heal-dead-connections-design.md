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

There is a second, independent barrier at the same measurement, worth
recording rather than leaving to be rediscovered: once `pg_result` has failed,
`$dbh->{pg_socket}` reads `-1`.

```
pg_socket BEFORE execute  : 3
pg_socket AFTER execute   : 3
pg_result                 : FAILED (as above)
pg_socket AFTER the fatal : -1
ping AFTER the fatal      : FALSE
```

libpq invalidates its own socket once it has finished processing a fatal
disconnect. Any code that tried to heal from inside `_execute_async`'s
`pg_result` failure — not just a retry of the statement, any code at all —
would find `_heal_if_dead`'s own `return 0 unless defined $fd && $fd >= 0`
(the fd check that guards the `select` below it) refusing to proceed, on a
connection whose destruction it did not cause. That line exists to keep
`vec()` off a negative descriptor, not as a deliberate second lock, but it
behaves as one. It is not a substitute for leaving `pg_result` alone — a
different call sequence could reach `_heal_if_dead` before the fd goes
invalid — but it is a real, measured fact about this failure mode and belongs
on the record next to the first one.

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
  is exactly this race, and it is what the "Testing" section's shutdown
  subtest now constructs directly rather than merely asserting the outcome
  of.
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
the check only ever runs before a statement is dispatched, never after one has
been.

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

- **Enforced by a guard, and demonstrated red by mutation.**
  `heal_dead_connections` and `_shutting_down` are both in this category now.
  Removing either guard in a scratch copy of `_heal_if_dead`, loaded ahead of
  the real module, turns its subtest red and leaves every other test green.
  The shutdown case took a second pass to get here: the first version of its
  subtest acquired a freshly built connection, so `_check_liveness` was never
  armed and `_heal_if_dead` was never entered — the guard had zero coverage
  and the mutation left it green like the transaction guard below. Rebuilt to
  release-then-reacquire (arming the check for real) before setting the flag,
  it now dies with the mutant removed and passes without it.
- **Hold structurally, because `_check_liveness` is set only on an idle
  checkout and consumed by the very next `query` call.** Only the transaction
  case remains here. It is not merely untested: it is provably unreachable as
  the code stands (see "What is still never done" above), and mutation
  testing confirms it — removing the `in_transaction` guard leaves every test
  green, because no sequence of real operations can arm the check while a
  transaction is open.
- **The already-sent case has no guard at all**, because nothing in
  `_execute_async` calls `_heal_if_dead`. Its safety is architectural rather
  than conditional, which makes it the hardest of the four to demonstrate by
  mutation — and mutation testing here needs a second look, because the first
  attempt drew the wrong conclusion from a correct measurement. A mutant that
  reintroduced a call to `_heal_if_dead` after `pg_result` fails did not fire:
  `_heal_if_dead`'s own `return 0 unless defined $fd && $fd >= 0` — code in
  this design, not merely a libpq fact — rejects it, because `pg_socket` is
  already `-1` by the time a fatal disconnect has been processed (see the
  measurement above). Read as "this class of mistake can't be caught," that
  conclusion overreaches: the mutant added a retry that provably cannot fire,
  which mutation testing calls an *equivalent mutant* — a known limitation of
  the technique, not evidence of a weak test. The canonical form of this
  mistake is not hypothetical; it is the original, abandoned design: a retry
  gated on `$dbh->ping` failing rather than on the socket probe. Traced
  through the already-sent subtest, that version *is* caught — the retried
  statement runs to completion on the replacement connection, so the error
  the test expects never arrives and the connection object is no longer the
  one the test started with. The subtest kills the mistake it was written
  for.

  What it could not do is observe the property directly. "An error reached
  the caller" and "the connection object is unchanged" are both consequences
  of the statement not running twice, not observations of it — neither would
  notice a repeat that itself failed, or one whose side effect landed before
  its failure did. The subtest now gives the statement a side effect (an
  insert into a table created for the run) and counts it from a separate
  connection afterward: a killed backend aborts the in-flight insert, so zero
  is the honest count, and any re-execution — however it might be written —
  commits and makes it one. That observes the thing the feature is organised
  around instead of inferring it, and is robust against forms of the mistake
  nobody has enumerated yet, which is the point of the change.

With that distinction in mind, the individual cases:

- No healing inside a transaction. The error propagates, and no statement runs
  on a replacement connection. (Structural, and provably unreachable — see
  above.)
- A real SQL error on a live connection is reported as itself (an earlier
  pass at this document and the test it describes both called this a syntax
  error; the test's own query is an undefined-table error, SQLSTATE 42P01,
  which is a different error class, so both were renamed rather than only
  one). The socket is not readable, so the check costs nothing and concludes
  nothing — that is the mechanism when this connection has been
  idle-checked-out. The test for it in the current suite uses a freshly
  built connection instead, so it does not currently exercise that mechanism
  either; it establishes the same observable outcome (a real SQL error is
  reported as itself) without exercising `_heal_if_dead` at all.
- A connection that dies while its result is awaited fails to the caller, and
  the statement that reached the server did not run a second time — observed
  directly via a probe table, not inferred from the error and the handle
  alone. (Architectural rather than guarded, and demonstrated against the
  canonical form of the mistake — see above.)
- A healthy connection is never pinged. The free check is what decides whether
  the round trip happens at all, and on a healthy pool it never does.
- No healing while the pool is shutting down. (Guard-enforced and
  mutation-confirmed — see above.)
- The pool's counts are unchanged across a heal, and the healed connection
  works for subsequent queries.
- Idle siblings are discarded when a dead connection is found, so a second
  caller after a server restart is served a fresh connection rather than
  discovering another dead one. Connections checked out by other callers are
  left in place.

Killing a backend makes the FATAL arrive through DBI's own `PrintWarn`
calling Perl's `warn()`, not a raw libpq write to file descriptor 2 that
bypasses `warn()` and `$SIG{__WARN__}` entirely — measured directly:
`PrintWarn => 0` makes the notice vanish completely, which a raw write could
not do, since libpq's own notice processor has no way to know about a DBI
attribute. Earlier revisions of this document claimed the opposite for the
pub/sub listener specifically, on the theory that its `pg_notifies` loop
calls libpq's `PQconsumeInput` directly and so triggers some lower-level,
uninterceptable notice path; that theory was never tested against the actual
code and was wrong. `pg_notifies` warns exactly like every other DBI call
that surfaces a server message — `_capture_pg_notices` was simply not
wrapped around it yet, so its `warn()` reached the real `$SIG{__WARN__}` (or
its absence) instead of the pool's `on_log`, the one call site among
`ping`, `pg_ready`/`pg_result`, and `pg_notifies` where that gap existed.
Closing it (wrapping the `pg_notifies` call in the listener loop the same
way the others already were) makes every one of those paths route through
`on_log` uniformly. Every capture window in this suite asserts `is
$captured, ''` for that reason now, including the pub/sub listener's —
established by running it, not guessed, and confirmed uniform across every
window rather than assumed from one measurement. The descriptor-level
`capture_stderr` helper stays regardless: it is what proves fd 2 stays
empty, catching anything that lands there regardless of source, rather than
assuming it does because the mechanism is understood.

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

---

## Addendum: a hard-won constraint, confirmed by crash, from a related task

Not part of this feature. Recorded here because this document is where this
branch's hard-won measurements already live, and there is nowhere else on
this branch that captures Future::AsyncAwait's own limitations as directly
as this one does.

Every task brief on this branch repeats the rule that a `local` cannot be
stretched across an `await`, because it unwinds with its frame and a caller
may cancel while a sub is suspended, running nothing after that point. Task 5
(routing PostgreSQL notices through `on_log` instead of letting DBI print
them to fd 2) is the first place on this branch where breaking that rule was
tried, by accident, and caught before it shipped rather than discovered
after.

`Connection.pm`'s `_wait_for_result` polls in a loop:

```perl
while (!$dbh->pg_ready) {
    await Future::IO->poll($sock, POLLIN);
}
```

Measurement showed that under `pg_async`, a statement's own NOTICE surfaces
here, during the synchronous `pg_ready` call, not during `execute` or
`pg_result` as a synchronous-DBI measurement would suggest (`execute` under
`pg_async` only dispatches and returns; it never waits for or processes a
response, which is the same fact the design above rests on). The first
attempt at capturing it wrapped the whole loop in one `local $SIG{__WARN__}`,
spanning the `await` inside it. That does not merely fail to route the
notice. It aborts the process:

```
Future::AsyncAwait panic: TODO: Unsure how to handle savestack entry of SAVEt_HELEM=52
```

`SAVEt_HELEM` is Perl's internal record of a localized hash element --
`%SIG` is a hash, and `local $SIG{__WARN__}` is exactly that. `await` has to
save and restore the interpreter's save stack across a suspension point, and
this is a save-stack entry type `Future::AsyncAwait` does not know how to
carry across one. Confirmed with a standalone script instrumenting each
phase (`execute`, the `pg_ready` loop, `pg_result`) separately, run three
times, identical every time; a second engineer reproduced the same panic
independently.

The fix wraps each synchronous call individually -- `execute`, `pg_ready`
(once per loop iteration), and `pg_result` -- through a small helper that
`local`s `$SIG{__WARN__}` around exactly one call and returns. None of those
`local`s ever spans an `await`, so the save-stack entry this panics on is
never present when a suspension happens. The same reasoning that rules out
`local` here also rules out a guard object holding the assignment for a
whole query: a plain `$SIG{__WARN__} = ...` in a constructor, restored in
`DESTROY`, is a global assignment that would be held across every `await`
the query makes, and two connections' queries running concurrently would
have the first one to finish restore whatever it saved -- potentially
clobbering the second one's still-active handler if the two do not happen to
unwind in the same order they were built. `t/pool/basic.t`'s `'concurrent
notices on different connections all reach on_log'` subtest is built
specifically to break that ordering (the first-constructed query is made the
faster one, so its guard would destroy first, before the second, still
in-flight one's) and pins the choice of `local` over a guard by demonstration
rather than by argument: it fails, with the predicted leak, against a
guard-based mutant, and passes against the shipped code.

### A second constraint, found writing the test for the first fix

Getting `_capture_pg_notices` right surfaced a second, unrelated crash in the
test written to prove it, worth recording for the same reason: it was found
because a change made the exact interleaving that triggers it likely for the
first time, not because the pattern itself is new.

`t/pool/basic.t`'s transaction-notice subtest originally nested a
`capture_stderr(sub { $tx->query(...)->get })` inside `$conn->transaction(async
sub { ... })`, mirroring the shape an earlier subtest in the same file already
used successfully for `Future::IO->sleep(...)->get`. Under
`PERL_FUTURE_IO_IMPL=IOAsync` specifically (`UV` was unaffected), this aborted
the process:

```
IO::Async::Future=HASH(0x...) is already done and cannot be ->done at
Future/IO/Impl/IOAsync.pm line 88.
```

Bisected with a series of standalone scripts, isolating one variable at a
time: two plain queries in a transaction, `->get`'d the same way, do not
crash; a notice-producing query does, but only once `_capture_pg_notices`
wraps the synchronous `pg_ready` call the notice fires inside -- the same
change that fixes the routing bug this task exists to fix. The crash needs a
`->get` on a future built from multiple internal `await`s (a query's, not a
`Future::IO->sleep`'s simpler one) called from code that is itself already
running inside an async sub resumed by `IOAsync`'s own reactor. That nested,
blocking wait re-enters the reactor from inside one of its own callbacks,
and something in that reentry marks a `Future::IO::Impl::IOAsync` future
done twice.

The fix was to the test, not to `Connection.pm`: `capture_stderr` now wraps
`$conn->transaction(async sub { ... await $tx->query(...) ... })->get` as a
single call at the outermost, synchronous level, rather than nesting a
second capture (with its own `->get`) inside the already-suspended async
body. A single top-level `->get` is the pattern used throughout this whole
suite and is not what triggers the crash; a `->get` nested inside an
already-running async sub, on a multi-`await` future, is. `await` does not
have this problem -- only a blocking `->get` does -- so the rule this earns
is narrower than "never nest": nest `await`, never nest `->get`, under
`IOAsync`, on anything more than a single-`await` future.

This was not reachable through `UV`, which makes it easy to miss if a branch
is only ever run under one implementation locally. It is why this project's
own constraint says both.

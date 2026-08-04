# Async::DBD::Pg — Open Gaps

Issues still open against the goal of a CPAN-ready, production-reliable async
PostgreSQL client. Closed items live in `gaps-closed.md`, which keeps the
reasoning and measurements behind each one; several of those entries record
conclusions that were reversed by experiment, and are worth reading before
re-deriving anything they cover.

Items keep their original numbers. Numbering is unique but not contiguous.

Every entry below states what is claimed and, where it has been tested, what
was actually observed. An entry that says "not demonstrated" has not been
reproduced and should be before anything is built on it.

---

### 18. No `_wait_for_result` upper bound — EVALUATED, NO CHANGE

**File:** `Connection.pm:182-190`

Without a per-query timeout and without a session `statement_timeout`, the poll loop runs
forever on a hung server.

Tested by terminating the backend with `pg_terminate_backend` while a query was in flight.
There is no busy loop: `pg_ready` goes true on end of file, `pg_result` fails, and the query
fails with the server's own message. The pool then discards the connection when it is
released, because the liveness check fails.

The remaining behaviour is a client waiting indefinitely for a server that never answers,
which is what any client does without a timeout. Two opt-in bounds already exist: the
`timeout` option on a query, and `statement_timeout` on the pool. Imposing a default would
mean guessing a number that suits every workload, so nothing changed here.

### 19. Waiter queue is bounded only by `queue_timeout` — MEASURED, no change

Under spike load the waiting queue grows: every caller that cannot be served
immediately is queued with a timer future, at roughly **8.7 KB each**.

It is not unbounded, which earlier versions of this entry claimed twice.
`queue_timeout` defaults to **30 seconds**, and its timer splices the waiter
out on expiry without needing a connection to be released. The steady-state
ceiling is therefore

    arrival_rate x queue_timeout x ~8.7 KB per waiter

— around 260 MB for a service where 1,000 acquisitions per second all queue,
and it stays there rather than growing. It is genuinely unbounded only if
`queue_timeout => 0` is set, which is an explicit opt-out.

Measured on an otherwise idle database:

    queued 20000 waiters in 0.79s, waiting_count=20000
    process RSS: 174 MB
    releasing one connection hands off to exactly one waiter, in 0.39s

It degrades linearly rather than falling over: queueing is fast, hand-off is
prompt, and the process stayed responsive and shut down cleanly.

**No change made, deliberately.** A hard cap is a product decision — what
should a pool do when 20,000 callers are waiting, fail fast or keep queueing?
— and nothing indicates anyone needs one. Someone sizing a service can compute
the ceiling from the formula above.

### 20. `parse_dsn` doesn't support Unix sockets

**File:** `Util.pm:~85-127`

`host` defaults to `'localhost'` when absent. `postgresql:///dbname` (local socket) is
forced to TCP. `port` is forced to `5432`.

### 21. Future::IO usage is too low-level (feedback from LeoNerd) — PARTLY ANSWERED

**Feedback source:** LeoNerd (author of Future::IO) on IRC, 2026-03-18.

The `_complete_async_connect` in `Pg.pm` is a hand-rolled ~80 line state machine with
manual timeout racing, status code checking, and future cancellation. The `_wait_for_result`
loop and similar patterns are "very lowlevel manual" per LeoNerd's feedback.

**Important nuance:** Our use of `Future::IO->poll()` is actually correct and necessary.
Unlike Async::Redis (which owns the socket and uses `Future::IO->read()`/`write_exactly()`
to speak the wire protocol directly), we don't own the socket — DBD::Pg/libpq does. We
can only wait for readability then call `pg_ready`/`pg_result`. So `->poll()` is the right
primitive.

The issue is the **scaffolding around the poll calls** — the manual `while(1)` loops,
inline timeout racing, status code branching. These should use Future combinators:
- Extract timeout-racing into a reusable helper (the `wait_any` + cancel pattern)
- Consider `Future::Utils::repeat` for poll loops instead of `while(1)`
- Study Async::Redis and other Future::IO dependents for idiomatic patterns

LeoNerd pointed to `https://metacpan.org/dist/Future-IO/requires` for examples of
well-structured Future::IO code.

**Read Conduit, LeoNerd's own Future::IO based HTTP server, for those patterns.** Two of the
three concerns in this entry do not survive contact with it.

- `while` loops around `await` are not the problem. Conduit's own accept loop is
  `while( my $clientsock = await Future::IO->accept( $listensock ) )`, and its client loop
  is `while( defined( my $req = await $self->read_request ) )`. Our `_wait_for_result` is the
  same shape. `Future::Utils::repeat` predates `async`/`await` and is not what its author
  reaches for now.
- `Future::Buffer` and `Future::IO`'s `sysread`/`write_exactly` are the idiomatic parts we
  cannot use, for the reason already recorded above: Conduit owns its socket and speaks the
  protocol itself, and we do not.

What did transfer is how Conduit treats work nobody is awaiting. It collects those futures
in a `Future::Selector` and gives each an `->else` that logs and returns `Future->done`, so
one failed client cannot take the server down. We had the opposite: `->retain` scattered
about, meaning start it and hope. See item 63.

`Future::Selector` itself was considered and not adopted. It wants a run loop of its own,
which suits a server with a top level `run` and does not suit a library living inside
someone else's event loop; adopting it would either force a supervisor future on callers or
amount to `->retain` with extra machinery and an `Object::Pad` dependency. The idea was
worth taking without the module.

---

### 46. COPY protocol support — DEFERRED to 0.002

Every mature async PG library has COPY support built-in or via companion package. It's the
standard mechanism for bulk data loading/export — dramatically faster than multi-row INSERT.

Deliberately out of scope for 0.001001. No COPY code exists in the distribution today, so
this is a scoping decision rather than a removal.

**COPY TO (reading out):** Not blocked. `pg_getcopydata_async` ships in DBD::Pg 3.20.2 and
maps directly onto our `Future::IO->poll` pattern.

**COPY FROM (writing in):** Blocked on DBD::Pg 3.21.0, which is merged upstream but not yet
released to CPAN. See Section 10.

**The earlier "mostly async" plan is withdrawn.** It proposed issuing the COPY command
asynchronously while accepting that each `pg_putcopydata` call blocks, chunking writes to
keep the stalls short, and documenting the caveat. That was the right call when no upstream
fix existed. It no longer is: real non-blocking support is merged, so building the
compromise would mean shipping a knowingly-blocking call inside a library whose whole
premise is that it never blocks the reactor, then deleting that code and retracting the
caveat one release later.

**Why both halves wait.** COPY TO could be built today, but shipping export without import
is a confusing public interface — callers expect the pair. Ship both, properly non-blocking,
once 3.21.0 is on CPAN.

With 3.21.0 the write side becomes a genuine non-blocking loop that maps onto
`Future::IO->poll($sock, POLLOUT)`:

- `pg_putcopydata_async` — 1 queued (then call `pg_flush`), 0 buffer full (wait for
  write-ready, retry the same call)
- `pg_flush` — 1 data still pending (wait for write-ready, call again), 0 flushed
- `pg_putcopyend_async` — 0 retry, 1 done and the connection returns to blocking mode

### 48. Transaction `readonly` and `deferrable` options

asyncpg, pgx, tokio-postgres, r2dbc, and Npgsql all support the full
`BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE READ ONLY DEFERRABLE` combination. We
support isolation levels but not `readonly` or `deferrable`. This matters for read replicas
and reporting workloads.

Add `readonly` and `deferrable` options to the `transaction()` method.

### 50. Connection `max_lifetime` with jitter

pgx, node-postgres (`maxLifetimeSeconds`), asyncpg (`max_inactive_connection_lifetime`),
Npgsql (`ConnectionLifetime`), and r2dbc (`maxLifeTime`) all have this. Prevents using
connections that have been open so long they've accumulated leaked state or crossed a server
restart boundary.

Add a `max_lifetime` pool parameter (separate from `idle_timeout`) that closes connections
after an absolute age, regardless of activity. Include configurable jitter (like pgx) to
prevent thundering herd when many connections reach max lifetime simultaneously.

---

### 51. No type binding control — FIXED (silent bytea data loss)

No way to set `pg_type` on bind params (needed for BYTEA, JSON/JSONB). No way to configure
`pg_bool_tf`, `pg_expand_array`, `pg_int8_as_string`, or `pg_enable_utf8` at connection
time. Users working with binary data, JSON, or boolean columns will hit this immediately.

At minimum, support:
- Per-bind `pg_type` (e.g., `query($sql, { col => [$val, PG_BYTEA] })`)
- Pool-level type defaults via `on_connect` (already works as escape hatch)
- Document the `on_connect` pattern for setting type attributes

### 52. No `pg_placeholder_dollaronly` support

**Not blocked on anything.** Available in DBD::Pg 3.20.2 on CPAN.

Needed for JSONB operators (`?`, `?|`, `?&`) and geometric operators (`?#`, `?-|`). Without
this, any query using JSONB containment checks will break because `?` is treated as a
placeholder. JSONB is extremely common in modern PostgreSQL usage.

### 53. No connection diagnostic attributes

No way to get `pg_pid`, `pg_server_version`, `pg_db` from a connection. These are basic for
logging ("query failed on backend PID 12345"), version-gated behavior, and debugging.

### 54. No explicit prepare/execute cycle

Everything goes through combined prepare+execute. No way to prepare a statement once and
execute it many times with different parameters. This is a significant performance gap for
hot loops (e.g., inserting 10,000 rows with the same statement structure).

### 55. No `pg_skip_deallocate` support

**Not blocked on anything.** Available in DBD::Pg 3.20.2 on CPAN.

Needed for PgBouncer compatibility. Without this, using the library behind PgBouncer (which
many production deployments use for external connection pooling) will fail with prepared
statement errors. Should be configurable at the pool level.

### 56. Document pool sizing vs PostgreSQL `max_connections`

Users need to understand that the pool's `max_connections` should always be well below
PostgreSQL's `max_connections`. Reasons:
- Other clients need connections (psql, monitoring, migrations, other app instances)
- PgBouncer or connection proxies need their own slots
- Our PubSub checks out a dedicated connection per listener
- PostgreSQL reserves `superuser_reserved_connections` (default 3) for admin access
- Multiple app instances share the same PostgreSQL connection limit

A typical setup: PG at 200, each of 3-4 app instances pooling 20-30 connections, with
headroom for admin/monitoring.

This needs a dedicated documentation section covering pool sizing guidance, the
relationship between client pool limits and server limits, and what happens when limits
are exceeded (waiter queue, `Error::PoolExhausted`).

### 57. Validate pool size against PostgreSQL `max_connections` at startup

If a user sets `max_connections = 500` on the pool but PostgreSQL only allows 100, they
get cryptic connection errors under load instead of a clear message at startup. On the
first successful connection, query `SHOW max_connections` and warn if the pool's
`max_connections` exceeds the server's limit. This is a simple safety check that prevents
a common misconfiguration.

---

### 59. JSON/JSONB column auto-expansion

Mojo::Pg's `expand()` auto-decodes JSON/JSONB columns to Perl hashrefs/arrayrefs on read,
which is genuinely convenient. Questions to resolve before implementing:
- Read-only (auto-decode) or also auto-encode on write?
- Per-query opt-in or connection-level default?
- How to handle cases where raw JSON string is preferred (e.g., pass-through to HTTP
  response)?
- Partial update patterns (modify one key in a large document)?

Low priority for initial release but high user-experience value.

---

### 73. Teardown cancels in-flight work by name, not from a registry — DECIDED, not a defect

**File:** `PubSub.pm` (`disconnect`, `_pool_shutdown`)

`disconnect()` cancels four things by explicitly naming each one:
`{_reconnect_future}`, `{_connecting}`, `{_control_query_inflight}`, and
the listener. A fifth mechanism added later gets cleaned up only if
whoever adds it remembers to extend teardown.

A design for a single `{_inflight}` registry was written and deliberately
not built (see the phase-model spec). The reasoning for skipping it: a
registry makes forgetting *benign* rather than impossible — a future
nobody registers is exactly as orphaned as one nobody names — so it
softens the failure mode without preventing it, at the cost of another
indirection over four call sites that are currently explicit and
readable. Recorded here so the option is not re-derived from scratch.

Two related debts it would not have fixed either way:

- Item 70's race is a *checkout* leak, not a future leak; a registry of
  futures does not see it.
- `_pool_shutdown` and `disconnect` reach the same terminal state by
  three unrelated routes — `listen()` gates on `{phase}`, `unlisten()` and
  `unlisten_all()` check `{channels}` and `{conn}`, and the reconnect
  loop's replay is aborted by cancelling `{_reconnect_future}`. Four
  attempts to describe that as one tidy mechanism in a comment were all
  wrong; it is three mechanisms, and any future consolidation has to
  start from that.


### 74. `_CheckoutGuard::DESTROY` has no `${^GLOBAL_PHASE}` check — TESTED, no observable effect

**File:** `PubSub.pm` (`_CheckoutGuard::DESTROY`)

The destructor calls `$conn->release` unconditionally. During global
destruction the pool and the connection may already have been torn down
in an unspecified order, so a release firing then can touch objects in a
partially destroyed state. The other guards in this file weaken their
reference to the pub/sub object and return early when it is gone;
`_CheckoutGuard` deliberately holds its connection strongly, because
nothing else does, so it has no equivalent early-out.

Checked, not assumed: exiting the process with a `notify` in flight and
the guard still armed produces zero bytes of stderr under both
`Future::IO::Impl::UV` and `::IOAsync`. The guard gained a second call
site (`notify`, alongside `_establish`) without that changing, so the
wider exposure did not make it bite.

Left as recorded rather than fixed: adding
`return if ${^GLOBAL_PHASE} eq 'DESTRUCT'` is a one-line change, but
nothing currently demonstrates a failure it would prevent, and a guard
that silently skips its release is its own hazard if the condition is
ever wrong.

---

**74 does not manifest.** Exercised deliberately: a process exiting with five
connections checked out, a pub/sub listening, and a `notify` in flight holding
an armed `_CheckoutGuard`. Exit status 0 and zero bytes on stderr under both
`Future::IO::Impl::UV` and `::IOAsync`. Adding
`return if ${^GLOBAL_PHASE} eq 'DESTRUCT'` remains a one-line change, but
nothing observable justifies it, and a guard that silently skips its release is
its own hazard if the condition is ever wrong. Left as recorded rather than
fixed.

**Fixed 2026-08-04.** `_pool_shutdown` now ends at a fifth phase, `'shut'`,
distinct from `disconnect()`'s transient `'closing'`. Both refusal sites report
`PubSub has been shut down` for it and `PubSub is disconnecting` for the other,
matching the pool's existing `is shutting down` / `has been shut down` pair. A
`_tearing_down` predicate keeps the disjunction in one place.

`disconnect()` also returns immediately on a shut object. It previously set
`'closing'` on entry and `'disconnected'` at its early return, so calling it on
a terminally shut pub/sub reversed the terminal state — and a first attempt at
the fix guarded the *later* assignment, which never fired because the earlier
one had already destroyed the distinction.

One existing expectation changed: `t/pool/shutdown.t` asserted that a refusal
after a fully settled shutdown says `is disconnecting`. That subtest is named
`'shutdown refuses pub/sub work permanently'`, so the new message is what its
own name always meant.

See `docs/superpowers/specs/2026-08-04-pubsub-terminal-phase-design.md`, which
also records a claim it got wrong: the audit argued that the reconnect
supervisor's `ne 'closing'` tests would spin once a new phase existed. Mutating
the predicate reds only the refusal tests — `_pool_shutdown` cancels the
supervisor outright, so those phase tests sit behind the cancellation as a
second line of defence. They were still made positive, as defence rather than
as a proven fix.

**Fixed 2026-08-04.** The title understated it: without a way to state a
parameter's type, `bytea` was sent as text and **truncated at the first NUL
with the write reporting success**. Measured before the fix — 256 bytes in, 0
stored; `"abc\0def"` in, 3 stored.

A bind value may now carry its own type as `{ type => PG_BYTEA, value => $x }`,
Mojo::Pg's convention adopted verbatim. Works positionally, through named
placeholders, and mixed with untyped parameters; `undef` still stores NULL.

Two things the research settled, in
`docs/superpowers/specs/2026-08-04-typed-bind-parameters-design.md`:
node-postgres, psycopg and asyncpg all dispatch on their language's native
binary type — `Buffer`, `bytes` — which Perl does not have, so annotation is
the only mechanism available rather than a wart. And a lone hashref is
disambiguated from a named-bind map by the *statement*: no `:name`
placeholders means it cannot be one. That is psycopg's principle, and it keeps
a genuine `:type`/`:value` query working.

Covered by seven subtests in `t/integration/connection.t`, two of which guard
existing behaviour rather than the new. Mutation-verified separately: removing
the sentinel unwrapping reds four, removing the SQL disambiguation reds only
the lone-hashref one.

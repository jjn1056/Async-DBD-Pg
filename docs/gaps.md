# Async::DBD::Pg - Gaps to Production-Ready CPAN Release

End-to-end review of the codebase against the goal: a CPAN-ready, production-reliable
async PostgreSQL client. Early release (0.001001) where "things might change to fix bugs"
is acceptable, but the core must be correct and safe since this is database infrastructure.

---

## Section 1: Correctness Bugs (must fix)

### 1. `_query_with_timeout` winner comparison is broken

**File:** `Connection.pm:100-112`

`Future->wait_any` returns the result value of the winning future, not the future object.
`$winner == $timer` compares a scalar to a Future reference — this will never work as
intended. The timeout path is completely broken.

### 2. `pg_result` returning 0 is treated as error

**File:** `Connection.pm:144`

`!$result` is true when `pg_result` returns `0`, which is a valid return for UPDATE/DELETE
affecting zero rows. Any zero-row DML will throw a spurious error.

### 3. `_throw_query_error` uses wrong DBD::Pg attribute

**File:** `Connection.pm:352`

`pg_errorlevel` is the verbosity setting (0/1/2), not the error detail text. Should be
`$dbh->pg_diag_message_detail` or similar. Also, `constraint`, `hint`, and `position` are
hardcoded to `undef` when DBD::Pg exposes all of them via `err_diag_*` attributes.

### 4. `is_healthy` logic is always true

**File:** `Pg.pm:133`

`waiting_count < max_connections` compares the number of waiters to the number of
connections — these are unrelated quantities. The method is useless as a health check.

### 5. `idle_timeout` is accepted but never implemented

**File:** `Pg.pm:59`

The parameter is stored and documented but no timer or reaping logic exists. Idle
connections are never reaped.

### 6. PubSub `connect` is not re-entrant

**File:** `PubSub.pm:52-66`

Two concurrent callers both see `!$self->{connected}` and both check out a connection.
The second overwrites `$self->{conn}`, leaking the first connection permanently.

### 7. PubSub `_stopping` flag never resets on error

**File:** `PubSub.pm:~228`

If `_run_control_query` fails, `_stopping` stays true and the listener loop never restarts.
All subsequent LISTEN/UNLISTEN operations silently fail.

---

## Section 2: Resource Leaks & Data Integrity (must fix)

### 8. Cursor `DESTROY` is a no-op

**File:** `Cursor.pm:102-110`

If a cursor is garbage collected without `close()`, the server-side cursor stays open and
the owning transaction is never committed. For long-lived pooled connections, this leaks
server resources and holds transaction locks.

### 9. Cursor SQL injection

**Files:** `Cursor.pm:47`, `Connection.pm:272`

Cursor name and batch_size are interpolated directly into SQL (`"FETCH $batch_size FROM
$name"`, `"DECLARE $cursor_name CURSOR FOR $sql"`). User-supplied cursor names are an
injection vector. `batch_size` should be validated as a positive integer.

### 10. Pool can exceed `max_connections`

**File:** `Pg.pm:~101`

`total_count` doesn't account for connections currently being created (in-flight async
connect futures). Under concurrent load, multiple callers see `total_count <
max_connections` simultaneously and each creates a new connection.

### 11. Waiter queue race

**Files:** `Pg.pm:~159-206, 415`

When a waiter times out, it removes itself from the queue and fails its future. But
`_release_to_idle_or_waiting` does `shift @{waiting}` and calls `->done($conn)` without
checking if the future is already failed. If timing aligns, a connection is delivered to a
dead future and never released — permanent pool shrinkage.

### 12. Statement handle leak on error

**File:** `Connection.pm:143-145`

When `pg_result` fails, the sth from `prepare`/`execute` is never `finish`-ed. Under load,
these accumulate.

### 13. `_complete_async_connect` fd leak on error

**File:** `Pg.pm:~277-367`

When async connect fails mid-handshake, the duped socket fd is not closed on all error
paths.

### 14. `DESTROY` calls `release` which calls `ping`

**Files:** `Connection.pm:333-341`, `Pg.pm:~377`

`ping` is a blocking network call. Running it from `DESTROY` during event loop teardown can
block the reactor or trigger re-entrant async code.

### 15. `convert_placeholders` silently emits broken SQL

**File:** `Util.pm:~57-75`

If a `:name` appears in the SQL but the params hash has no matching key, the literal `:name`
passes through to PostgreSQL, which will reject it with a confusing syntax error. Should die
at conversion time with a clear message about missing placeholder names.

---

## Section 3: Missing Functionality (needed for production confidence)

### 16. No connection validation on checkout

`_return_connection` pings on release, but when a connection is taken from the idle pool,
there's no staleness check. A connection that went dead while idle is handed to the caller,
who discovers it on first query.

### 17. No PubSub reconnect

If the listener connection drops (network, server restart), `_listener_loop` either errors
or spins on EOF. All subscriptions are lost silently. No callback or event to detect this.

### 18. No `_wait_for_result` upper bound

**File:** `Connection.pm:182-190`

Without a per-query timeout and without a session `statement_timeout`, the poll loop runs
forever on a hung server.

### 19. No waiter queue bound

Under spike load, the waiting queue is unbounded (limited only by memory). Thousands of
waiters can queue up, each with a timer future.

### 20. `parse_dsn` doesn't support Unix sockets

**File:** `Util.pm:~85-127`

`host` defaults to `'localhost'` when absent. `postgresql:///dbname` (local socket) is
forced to TCP. `port` is forced to `5432`.

### 21. Future::IO usage is too low-level (feedback from LeoNerd)

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

---

## Section 4: CPAN Packaging (release blockers)

### 21. No `Changes` file

`[@Basic]` includes `[CheckChangesHasContent]` — `dzil release` will refuse to run
without it. Required by CPAN convention.

### 22. `dist.ini` MetaResources point to old repo

**File:** `dist.ini:13-17`

All URLs reference `github.com/jjn1056/future-io-pg`. CPAN will link users to a stale or
nonexistent repo.

### 23. License inconsistency

`dist.ini` says `Artistic_2_0`. README and module POD say "same terms as Perl itself"
(which is Artistic 1.0 OR GPL). These are legally different licenses. Pick one.

### 24. `.gitignore` has old package name

Line 1: `/Future-IO-Pg-*`. Built tarballs from `dzil build` won't be ignored.

### 25. `docker-compose.yml` will ship in the tarball

`[@Basic]`'s `[GatherDir]` includes everything not pruned. Need a `[PruneFiles]` rule or
similar. Same concern for `CONTRIBUTORS.md` if that should be dev-only.

### 26. No `$VERSION` in submodules

Only `Async::DBD::Pg` declares `$VERSION`. All other modules (`Connection`, `Results`,
`Error`, `Util`, `PubSub`, `Cursor`) have none. `perl -MAsync::DBD::Pg::Connection -e
'print $VERSION'` returns nothing.

### 27. Stale SEE ALSO link

**File:** `Pg.pm:608`

References `L<IO::Async::DBD::Pg>` which doesn't exist.

### 28. `copyright_year = 2025` in `dist.ini`

Should be 2026.

### 29. Inconsistent env var naming in examples

`prove_async.pl` uses `TEST_PG_DSN`; all other examples use `DATABASE_URL`.

---

## Section 5: Documentation (release blockers)

### 30. `Async::DBD::Pg::Results` has almost no POD

Just NAME and AUTHOR. This is the object every query returns — `rows`, `columns`, `count`,
`first`, `scalar`, `is_empty` are all undocumented. This is the single biggest doc gap.

### 31. `Async::DBD::Pg::Connection` public methods undocumented

`query`, `transaction`, `cursor`, `release`, `cancel` have no `=head2` entries. The
`{timeout => N}` option, transaction isolation levels, savepoint nesting — none described.

### 32. `Async::DBD::Pg::PubSub` methods undocumented

`listen`, `unlisten`, `notify`, `disconnect`, `connect` have no `=head2` entries. Callback
signature (`$channel, $payload, $pid`) is shown in SYNOPSIS but never described.

### 33. Pool-level pub/sub methods undocumented

**File:** `Pg.pm`

`listen`, `unlisten`, `unlisten_all`, `notify`, `pubsub`, `is_healthy`, `safe_dsn` have no
`=head2` entries.

### 34. Error subclass accessors undocumented

**File:** `Error.pm`

`Error::Query` fields (`code`, `state`, `constraint`, `detail`, `hint`, `position`),
`Error::Connection::dsn`, `Error::PoolExhausted::pool_size`, `Error::Timeout::timeout` —
none described.

### 35. `Async::DBD::Pg::Util` exports undocumented

`parse_dsn`, `safe_dsn`, `convert_placeholders` are exportable but have no `=head2` entries.

### 36. Pool constructor parameters only partially documented

`connect_timeout`, `statement_timeout`, `max_queries`, `on_connect`, `on_release`, `on_log`
are listed in SYNOPSIS but have no individual descriptions of types, defaults, or callback
signatures.

---

## Section 6: Test Coverage Gaps (needed for production confidence)

### 37. Cursor module: zero tests

`next`, `each`, `all`, `close`, owns-transaction commit, exhaustion detection — the entire
module is untested. This is the largest single gap.

### 38. Pool exhaustion/waiting queue: zero tests

The queue logic, timeout, `Error::PoolExhausted`, waiter handoff on release — the most
complex pool path has no coverage.

### 39. Per-query timeout: zero tests

`_query_with_timeout`, cancel-on-timeout, `Error::Timeout` — completely untested (and as
noted in item 1, also broken).

### 40. `Results::new($sth)` never tested

Every unit test uses `new_from_data`. The live DBI path through
`fetchall_arrayref`/`NAME`/`finish` is only exercised indirectly via integration tests.

### 41. Error SQLSTATE mapping: 2 of 15 codes tested

Only `23505` and `42601` are covered. The remaining 13 entries in `%STATE_MAP` are untested.

### 42. PubSub error paths untested

Callback throwing, connection loss, `_process_notifications` error handling,
`_pool_shutdown`.

### 43. `on_release` callback: untested

The ROLLBACK-if-in-transaction path and callback failure handling.

### 44. `_return_connection` edge cases: untested

`ping` failure, `max_queries` discard, waiter handoff.

### 45. No concurrency tests

No tests for simultaneous pool acquisition, race between timeout and connection
availability, or multiple PubSub listeners receiving notifications concurrently.

---

## Section 7: Feature Gaps (competitive parity with mature async PG libraries)

Cross-language analysis of asyncpg (Python), pgx (Go), tokio-postgres (Rust),
node-postgres (Node.js), Npgsql (.NET), and Perl's Mojo::Pg / AnyEvent::Pg identified
these as table-stakes features we're missing.

### 46. COPY protocol support

Every mature async PG library has COPY support built-in or via companion package. It's the
standard mechanism for bulk data loading/export — dramatically faster than multi-row INSERT.

**COPY TO (reading out):** Fully async via DBD::Pg's `pg_getcopydata_async`. This is
non-blocking and maps directly to our Future::IO poll pattern. Should be straightforward.

**COPY FROM (writing in):** DBD::Pg's `pg_putcopydata` is fundamentally blocking — DBD::Pg
never calls `PQsetnonblocking()`, does not expose `PQflush()`, and has no
`pg_putcopydata_async`. The C implementation blocks in `PQputCopyData` when the TCP send
buffer fills.

**Plan:** Implement as "mostly async" for the initial release — issue the COPY command
asynchronously, accept that `pg_putcopydata` calls block per-chunk, send data in small
chunks to minimize blocking time. Document the write-side blocking caveat clearly. For most
real-world usage (CSV loading, ETL), individual putcopydata calls are fast (just buffering
into libpq) and only block when the TCP buffer fills.

**Upstream:** True non-blocking COPY FROM would require DBD::Pg changes: expose
`PQsetnonblocking()`, expose `PQflush()`, add `pg_putcopydata_async` returning 0 on
buffer-full. See Section 10 (DBD::Pg upstream spike) for details.

### 47. Rich error diagnostics from `pg_error_field`

We have the `Error::Query` class with fields for `detail`, `hint`, `constraint`,
`position` — but `_throw_query_error` never populates them. DBD::Pg exposes
`$dbh->pg_error_field($field)` with severity, detail, hint, constraint, schema, table,
column, statement_position, and more. Every other mature library surfaces these.

Must call `pg_error_field` immediately after an error (before any subsequent query clears
it) and populate the existing Error::Query fields. Also add `schema`, `table`, `column`
fields to Error::Query.

### 48. Transaction `readonly` and `deferrable` options

asyncpg, pgx, tokio-postgres, r2dbc, and Npgsql all support the full
`BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE READ ONLY DEFERRABLE` combination. We
support isolation levels but not `readonly` or `deferrable`. This matters for read replicas
and reporting workloads.

Add `readonly` and `deferrable` options to the `transaction()` method.

### 49. PubSub reconnect with subscription recovery

Mojo::Pg has `reconnect_interval` and emits disconnect/reconnect events. AnyEvent::Pg::Pool
auto-resubscribes channels after reconnect. Our PubSub silently dies on connection loss.

For a feature that is inherently long-lived (listeners run for hours/days), silent failure
on connection loss is unacceptable. Implement:
- Configurable `reconnect_interval`
- Automatic re-LISTEN for all registered channels on reconnect
- `on_disconnect` / `on_reconnect` callbacks so the application knows

### 50. Connection `max_lifetime` with jitter

pgx, node-postgres (`maxLifetimeSeconds`), asyncpg (`max_inactive_connection_lifetime`),
Npgsql (`ConnectionLifetime`), and r2dbc (`maxLifeTime`) all have this. Prevents using
connections that have been open so long they've accumulated leaked state or crossed a server
restart boundary.

Add a `max_lifetime` pool parameter (separate from `idle_timeout`) that closes connections
after an absolute age, regardless of activity. Include configurable jitter (like pgx) to
prevent thundering herd when many connections reach max lifetime simultaneously.

---

## Section 8: Convenience Gaps vs. Plain DBD::Pg

Features that users of DBD::Pg will expect and find missing.

### 51. No type binding control

No way to set `pg_type` on bind params (needed for BYTEA, JSON/JSONB). No way to configure
`pg_bool_tf`, `pg_expand_array`, `pg_int8_as_string`, or `pg_enable_utf8` at connection
time. Users working with binary data, JSON, or boolean columns will hit this immediately.

At minimum, support:
- Per-bind `pg_type` (e.g., `query($sql, { col => [$val, PG_BYTEA] })`)
- Pool-level type defaults via `on_connect` (already works as escape hatch)
- Document the `on_connect` pattern for setting type attributes

### 52. No `pg_placeholder_dollaronly` support

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

## Section 9: Nice to Have (future consideration)

### 56. JSON/JSONB column auto-expansion

Mojo::Pg's `expand()` auto-decodes JSON/JSONB columns to Perl hashrefs/arrayrefs on read,
which is genuinely convenient. Questions to resolve before implementing:
- Read-only (auto-decode) or also auto-encode on write?
- Per-query opt-in or connection-level default?
- How to handle cases where raw JSON string is preferred (e.g., pass-through to HTTP
  response)?
- Partial update patterns (modify one key in a large document)?

Low priority for initial release but high user-experience value.

---

## Section 10: DBD::Pg Upstream Spike (COPY FROM async support)

For true non-blocking COPY FROM STDIN, DBD::Pg would need:

1. **Expose `PQsetnonblocking()`** — or call it internally when entering COPY mode. Currently
   DBD::Pg never calls this; the connection is always in blocking mode.

2. **Expose `PQflush()`** — needed for the non-blocking write loop. When `PQputCopyData`
   returns 0 (buffer full), the caller must: call `PQflush()`, if it returns 1 wait for
   socket write-ready or read-ready, if read-ready call `PQconsumeInput()` (to avoid
   deadlock from server NOTICEs), then retry.

3. **Add `pg_putcopydata_async`** — or modify `pg_putcopydata` to honor non-blocking mode
   and return 0 on buffer-full instead of blocking. Currently `dbdimp.c:4537` has a
   `copystatus == 0` branch that is dead code with a comment `/* non-blocking mode only */`.

4. **Possibly expose `PQconsumeInput()`** — for the write-side flush loop. Already used
   internally for `pg_getcopydata_async`.

The C changes in `dbdimp.c` appear contained: the non-blocking branches already exist as
dead code, they just need `PQsetnonblocking()` to be called and the return values to be
surfaced to Perl. A patch to DBD::Pg is feasible but out of scope for our initial release.

# Async::DBD::Pg - Gaps to Production-Ready CPAN Release

End-to-end review of the codebase against the goal: a CPAN-ready, production-reliable
async PostgreSQL client. Early release (0.001001) where "things might change to fix bugs"
is acceptable, but the core must be correct and safe since this is database infrastructure.

Two items previously shared a number with an earlier item. They were given the next free
numbers (58, 59) rather than renumbering the document, so existing references to an item
number stay valid. Numbering is therefore unique but not in document order.

---

## Section 1: Correctness Bugs (must fix)

### 1. `_query_with_timeout` winner comparison is broken — FIXED

**File:** `Connection.pm:100-112`

`Future->wait_any` returns the result value of the winning future, not the future object.
`$winner == $timer` compares a scalar to a Future reference — this will never work as
intended. The timeout path is completely broken.

Worse than described: passing a timeout to `query()` failed in *both* directions, not only
on timeout. When the query won, `$winner` held a Results object and `$winner->get` died
with "Can't locate object method get"; when the timer won, `$winner` was undef, the `==`
warned about an uninitialized value, and `->get` died on undef.

Fixed by reading the outcome from the futures rather than from the awaited value. `wait_any`
cancels the loser and a cancelled future reports `is_ready`, so completion is tested with
`is_done`, which also distinguishes a query that failed on its own merits from one that ran
out of time. Covered by t/integration/connection.t.

### 2. `pg_result` returning 0 is treated as error — NOT A BUG

**File:** `Connection.pm:144`

Claimed: `!$result` is true when `pg_result` returns `0`, which is a valid return for
UPDATE/DELETE affecting zero rows, so any zero-row DML throws a spurious error.

This is incorrect and no change is needed. `pg_result` follows the DBI convention and
returns the string `'0E0'` for zero rows, which is numerically 0 but true in boolean
context, so `!$result` is false. Measured against DBD::Pg 3.20.2:

    UPDATE zero rows   pg_result='0E0'  bool=TRUE   numeric=0
    DELETE zero rows   pg_result='0E0'  bool=TRUE   numeric=0
    ON CONFLICT NOP    pg_result='0E0'  bool=TRUE   numeric=0
    UPDATE one row     pg_result='1'    bool=TRUE   numeric=1

The existing check is right: it distinguishes `undef` (a genuine failure) from `'0E0'` (a
successful statement that matched nothing). Zero-row UPDATE, DELETE and
`INSERT ... ON CONFLICT DO NOTHING` are covered by t/integration/connection.t so that this
contract is not "corrected" into a numeric test later.

### 3. `_throw_query_error` uses wrong DBD::Pg attribute — FIXED

**File:** `Connection.pm:352`

`pg_errorlevel` is the verbosity setting (0/1/2), not the error detail text. Should be
`$dbh->pg_diag_message_detail` or similar. Also, `constraint`, `hint`, and `position` are
hardcoded to `undef` when DBD::Pg exposes all of them via `err_diag_*` attributes.

Fixed together with item 47, which is the same change: the fields are now read from
`pg_error_field`, which is the accessor DBD::Pg actually provides. Collected before anything
else runs on the handle, since the next statement resets them. Covered by
t/integration/connection.t against a unique violation and a syntax error.

### 4. `is_healthy` logic is always true — FIXED

**File:** `Pg.pm:133`

`waiting_count < max_connections` compares the number of waiters to the number of
connections — these are unrelated quantities. The method is useless as a health check.

Fixed. `is_healthy` now reports whether a connection could be handed out without queuing:
an idle connection exists, or the pool is below `max_connections`. It is O(1) over counts
the pool already keeps, so there is no cost worth documenting.

Two decisions worth recording. The intended definition was "not shut down and can serve
without waiting", but there is no shutdown: no public teardown method exists,
`_close_all_connections` is reached only from `DESTROY` and fork detection, and a pool can
still create connections afterwards. Only the capacity half is implemented. A public
shutdown method remains an open question.

A saturated pool therefore reports false, which is deliberate. The POD says so, and warns
against wiring it to a load balancer health check, where it would take a busy but healthy
service out of rotation.

### 5. `idle_timeout` is accepted but never implemented — FIXED

**File:** `Pg.pm:59`

The parameter is stored and documented but no timer or reaping logic exists. Idle
connections are never reaped.

Implemented rather than dropped. Idle eviction is standard in comparable pools and enabled
by default in both: node-postgres `idleTimeoutMillis` defaults to 10 seconds, asyncpg
`max_inactive_connection_lifetime` to 300, each disabled by passing 0. Our existing default
of 300 already matched asyncpg, and the parameter was documented, so callers had reason to
expect it to work.

`min_connections` is a floor that reaping respects, following node-postgres, whose `min` is
described as the number of clients the pool holds on to and does not destroy on idle
timeout. Without that the reaper and `_ensure_min_connections` would fight each other.
Connections in use count towards the floor.

Reaping runs from a timer that only exists while there is something old enough to close, so
a pool resting at `min_connections` does not hold the event loop open.

### 6. PubSub `connect` is not re-entrant — FIXED

**File:** `PubSub.pm:52-66`

Two concurrent callers both see `!$self->{connected}` and both check out a connection.
The second overwrites `$self->{conn}`, leaking the first connection permanently.

### 7. PubSub `_stopping` flag never resets on error — FIXED

**File:** `PubSub.pm:~228`

If `_run_control_query` fails, `_stopping` stays true and the listener loop never restarts.
All subsequent LISTEN/UNLISTEN operations silently fail.

Fixed. `_stopping` is cleared and the listener restarted whether or not the statement
succeeded, and the failure is still reported to the caller. Covered by t/unit/pubsub.t.

---

## Section 2: Resource Leaks & Data Integrity (must fix)

### 8. Cursor `DESTROY` is a no-op — FIXED

**File:** `Cursor.pm:102-110`

If a cursor is garbage collected without `close()`, the server-side cursor stays open and
the owning transaction is never committed. For long-lived pooled connections, this leaks
server resources and holds transaction locks.

Fixed, but not in `DESTROY`. Two facts decide the design: cursors are declared without
`WITH HOLD`, so PostgreSQL drops them when their transaction ends, and asyncpg's pool takes
the same approach, resetting a connection on release with cursors explicitly among the
resources reset.

So the cleanup belongs to the connection, not the cursor. Releasing a connection now always
ends an open transaction, which reclaims the cursor with it. No blocking call and no attempt
to `await` in `DESTROY`, which cannot.

`DESTROY` warns when a cursor is discarded unclosed, so the mistake is visible while
developing rather than silently costing server resources until release.

**This uncovered a worse defect that was not in this document.** The `ROLLBACK` in
`_return_connection` sat inside the `if (my $on_release = ...)` branch, so it only ran when
an `on_release` callback happened to be configured. With the default of none, a connection
holding an open transaction went straight back to the idle list and the next borrower
inherited its locks. The reset is now unconditional. The synchronous fast path is kept for
the common case of a connection with nothing to reset, so releasing an ordinary connection
still returns it to the pool immediately.

### 9. Cursor SQL injection — FIXED

**Files:** `Cursor.pm:47`, `Connection.pm:272`

Cursor name and batch_size are interpolated directly into SQL (`"FETCH $batch_size FROM
$name"`, `"DECLARE $cursor_name CURSOR FOR $sql"`). User-supplied cursor names are an
injection vector. `batch_size` should be validated as a positive integer.

Fixed. PostgreSQL accepts a bind parameter for neither a cursor name nor a fetch count, so
both are validated instead of parameterised: the name must be a plain identifier within the
63 character limit, and batch_size must be a positive integer. Checked in
`Cursor::_validate_name` and `Cursor::_validate_batch_size`, called both from `Cursor::new`
and from `Connection::cursor` before the DECLARE is built. Covered by t/unit/cursor.t.

### 10. Pool can exceed `max_connections` — FIXED

**File:** `Pg.pm:~101`

`total_count` doesn't account for connections currently being created (in-flight async
connect futures). Under concurrent load, multiple callers see `total_count <
max_connections` simultaneously and each creates a new connection.

Fixed. A `_connecting` count tracks handshakes in progress, and `_committed_count` adds it
to `total_count` for every decision about whether there is room. `total_count` itself still
reports only connections the pool holds, which is what the statistics accessors are for.
`_ensure_min_connections` uses the committed count too, or it would over-create in the same
way.

Measured before the fix: six concurrent callers against `max_connections => 2` produced six
connections. Covered by t/pool/basic.t.

### 11. Waiter queue race — FIXED

**Files:** `Pg.pm:~159-206, 415`

When a waiter times out, it removes itself from the queue and fails its future. But
`_release_to_idle_or_waiting` does `shift @{waiting}` and calls `->done($conn)` without
checking if the future is already failed. If timing aligns, a connection is delivered to a
dead future and never released — permanent pool shrinkage.

Fixed, though the timeout path was not the way in: that handler removes the waiter from the
queue and already guards with `unless $future->is_ready`. The reachable case is a caller
that cancels while queued. Nothing takes such a waiter off the queue, so it was still
shifted and handed a connection, which went onto the active list with nobody left to
release it.

`_release_to_idle_or_waiting` now skips waiters whose future has already settled, whatever
settled it, and falls through to the idle list when none are live. Covered by
t/pool/basic.t.

### 12. Statement handle leak on error — FIXED

**File:** `Connection.pm:143-145`

When `pg_result` fails, the sth from `prepare`/`execute` is never `finish`-ed. Under load,
these accumulate.

Fixed. The in-flight handle is held on the connection as `_active_sth` and released by
`_release_active_sth`, which runs from the error paths and from `cancel`. This also covers
a query abandoned by a timeout: its async sub is torn down with the handle still active,
which made DBI warn "st handle ... cleared whilst still active" during the test run.

### 13. `_complete_async_connect` fd leak on error — FIXED

**File:** `Pg.pm:~277-367`

When async connect fails mid-handshake, the duped socket fd is not closed on all error
paths.

Fixed. The handshake now holds its socket wrappers in a lexical that closes them on every
exit path, including the error paths. This came out of fixing a separate defect in the same
routine: the handshake captured `pg_socket` once and polled it for the whole exchange, but
libpq may close the socket and connect again part way through (GSSAPI or SSL offered and
declined), so acquiring a pooled connection blocked forever. The replacement socket reuses
the descriptor number, which is why the stale handle looked unchanged.

### 14. `DESTROY` calls `release` which calls `ping` — FIXED

**Files:** `Connection.pm:333-341`, `Pg.pm:~377`

`ping` is a blocking network call. Running it from `DESTROY` during event loop teardown can
block the reactor or trigger re-entrant async code.

Fixed. `release` takes a `validate` option and `DESTROY` passes it false, so destruction no
longer makes a round trip. An explicit `release` still checks the connection before it is
reused.

This leans on item 16: a connection returned by `DESTROY` now reaches the idle list without
having been checked at all, so if it died in the meantime the next borrower is the one to
find out. Validating on checkout would close that off, and is the reason to do it.

### 15. `convert_placeholders` silently emits broken SQL — FIXED

**File:** `Util.pm:~57-75`

If a `:name` appears in the SQL but the params hash has no matching key, the literal `:name`
passes through to PostgreSQL, which will reject it with a confusing syntax error. Should die
at conversion time with a clear message about missing placeholder names.

Fixed. An unmatched placeholder now dies naming the placeholder. Two details were needed
beyond the description:

- Only an identifier is treated as a placeholder. A run of digits after a colon is an array
  slice bound, as in `arr[1:3]` or `arr[:2]`, and still passes through. Rejecting those
  would have broken valid SQL, and there was no test covering them.
- The early `return ($sql, []) unless %$params` had to go. It short-circuited the empty
  parameter hash, which is exactly the case where a named placeholder has nothing to bind.

The one construct this gives up is an array slice with identifier bounds,
`arr[lower:upper]`, in a statement using named placeholders; it is documented in the Util
POD along with the rest of the function's contract.

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

### 58. No `Changes` file — FIXED

`[@Basic]` includes `[CheckChangesHasContent]` — `dzil release` will refuse to run
without it. Required by CPAN convention.

The stated mechanism is wrong: `[@Basic]` does not include `[CheckChangesHasContent]`, and
`dzil build` completed without a Changes file. It was a convention gap, not a hard blocker.

Added anyway, since CPAN readers expect one. `[NextRelease]` fills in the version and date
from `{{$NEXT}}` at release time, so the entry cannot go stale the way a hand written date
does.

### 22. `dist.ini` MetaResources point to old repo — ALREADY FIXED

**File:** `dist.ini:13-17`

All URLs reference `github.com/jjn1056/future-io-pg`. CPAN will link users to a stale or
nonexistent repo.

### 23. License inconsistency — FIXED

`dist.ini` says `Artistic_2_0`. README and module POD say "same terms as Perl itself"
(which is Artistic 1.0 OR GPL). These are legally different licenses. Pick one.

Resolved as Artistic 2.0, which is what `dist.ini` already declared and what the generated
LICENSE file and `META.json` already carried. The README and the module POD were the ones
out of step, and now state Artistic 2.0 with a copyright line and a pointer to the LICENSE
file. Verified against a built distribution: metadata reports `artistic_2`, LICENSE carries
the Artistic 2.0 text, and no file claims the Perl terms any more.

### 24. `.gitignore` has old package name — ALREADY FIXED

Line 1: `/Future-IO-Pg-*`. Built tarballs from `dzil build` won't be ignored.

### 25. `docker-compose.yml` will ship in the tarball — FIXED

`[@Basic]`'s `[GatherDir]` includes everything not pruned. Need a `[PruneFiles]` rule or
similar. Same concern for `CONTRIBUTORS.md` if that should be dev-only.

Confirmed by building: `CLAUDE.md`, `CONTRIBUTORS.md`, `docker-compose.yml` and everything
under `docs/` were all in the tarball.

`[PruneFiles]` now drops `CLAUDE.md`, which is agent instructions of no use to anyone
installing the module, and `docs/`, which is internal gap analysis and spike notes rather
than user documentation.

`docker-compose.yml` and `CONTRIBUTORS.md` are kept deliberately. The README tells readers
to bring PostgreSQL up with it to run the integration suite, so pruning it would leave that
instruction pointing at a file that is not there, and CONTRIBUTORS.md credits people.

### 26. No `$VERSION` in submodules — FIXED

Only `Async::DBD::Pg` declares `$VERSION`. All other modules (`Connection`, `Results`,
`Error`, `Util`, `PubSub`, `Cursor`) have none. `perl -MAsync::DBD::Pg::Connection -e
'print $VERSION'` returns nothing.

Fixed with `[PkgVersion]`, which stamps `$VERSION` into every package at build time, rather
than by repeating the version in seven files where they would drift apart. The hand written
declaration in the main module was removed so there is a single source of truth in
`dist.ini`. Every package in the built distribution now carries the version, including the
four error subclasses that share Error.pm.

The trade is that `$VERSION` is absent when running straight from a git checkout, which is
normal for a Dist::Zilla distribution and is noted where the declaration used to be.

### 27. Stale SEE ALSO link — ALREADY FIXED

**File:** `Pg.pm:608`

References `L<IO::Async::DBD::Pg>` which doesn't exist.

### 28. `copyright_year = 2025` in `dist.ini` — FIXED

Should be 2026.

### 29. Inconsistent env var naming in examples — FIXED

`prove_async.pl` uses `TEST_PG_DSN`; all other examples use `DATABASE_URL`.

Fixed. `prove_async.pl` reads `DATABASE_URL` like the other eight examples. `TEST_PG_DSN`
stays what the test suite reads, so the two names now divide cleanly: examples take
`DATABASE_URL`, tests take `TEST_PG_DSN`, as the README and CLAUDE.md describe.

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

### 47. Rich error diagnostics from `pg_error_field` — FIXED

**Was not blocked on anything.** `pg_error_field` has shipped in DBD::Pg since well before
3.20.2, so this was actionable against the current CPAN release all along.

Fixed together with item 3. `Error::Query` gained `severity`, `schema`, `table`, `column`
and `context` accessors alongside the existing `detail`, `hint`, `constraint` and
`position`, all populated from `pg_error_field` and documented in the POD.

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

## Section 9: Nice to Have (future consideration)

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

## Section 10: DBD::Pg Upstream Spike (COPY FROM async support) — RESOLVED UPSTREAM

This spike identified four changes DBD::Pg needed for true non-blocking COPY FROM STDIN.
All four have been implemented and merged into `bucardo/dbdpg` master as commit `8d729c0`
("Add non-blocking async COPY FROM support", pull request #176, Github issue #177), by John
Napiorkowski and Ed Sabol. The spike's premise no longer holds: DBD::Pg does now call
`PQsetnonblocking()`, and the write-side primitives are surfaced to Perl.

The original findings, for the record:

1. **Expose `PQsetnonblocking()`** — or call it internally when entering COPY mode. DBD::Pg
   never called this; the connection was always in blocking mode.

2. **Expose `PQflush()`** — needed for the non-blocking write loop. When `PQputCopyData`
   returns 0 (buffer full), the caller must: call `PQflush()`, if it returns 1 wait for
   socket write-ready or read-ready, if read-ready call `PQconsumeInput()` (to avoid
   deadlock from server NOTICEs), then retry.

3. **Add `pg_putcopydata_async`** — or modify `pg_putcopydata` to honor non-blocking mode
   and return 0 on buffer-full instead of blocking. `dbdimp.c:4537` had a `copystatus == 0`
   branch that was dead code with a comment `/* non-blocking mode only */`.

4. **Possibly expose `PQconsumeInput()`** — for the write-side flush loop. Already used
   internally for `pg_getcopydata_async`.

The assessment that the C changes were contained proved correct: the dead non-blocking
branches needed `PQsetnonblocking()` to be called and their return values surfaced.

**What this means for us.** The delivered API is `pg_putcopydata_async`,
`pg_putcopyend_async` and `pg_flush` (see item 46 for the call contract). It is slated for
DBD::Pg **3.21.0, which is not yet on CPAN** — the current release is 3.20.2 (May 1, 2026).
So COPY FROM is gated on someone else's release schedule, which is why item 46 defers COPY
rather than blocking our own release on it. When 3.21.0 ships, gate COPY behind a runtime
version check, the same way async connect is already gated on DBD::Pg 3.19.0.

Nothing else we want is gated: `pg_error_field` (47), `pg_placeholder_dollaronly` (52),
`pg_skip_deallocate` (55) and `pg_getcopydata_async` are all in 3.20.2 today.

Also unmerged upstream and worth watching, though speculative: the `pipeline-mode`,
`single-row-mode` and `native-bools` branches on `bucardo/dbdpg`.

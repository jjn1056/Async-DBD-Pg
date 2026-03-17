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

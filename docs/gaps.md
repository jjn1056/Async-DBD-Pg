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
without waiting", but at the time there was no shutdown: no public teardown method existed,
`_close_all_connections` was reached only from `DESTROY` and fork detection, and a pool
could still create connections afterwards, so only the capacity half was implemented.

That open question has since been answered by item 60, and `is_healthy` now reports false
for a pool that is shutting down as well.

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

### 67. PubSub `{_stopping}` was overloaded between three different meanings — FIXED

**File:** `PubSub.pm` — `_reconnect_loop` read it as "teardown asked me to
stop"; `_stop_listener` set it for the duration of every control query;
`_ListenerGuard::restore` cleared it unconditionally. A different
`_stopping` defect from item 7 above, in the same flag.

Not theory: reproduced end to end by making one `LISTEN` slow enough that
it was still in flight when the reconnect supervisor woke from backoff.
The supervisor read `last if $self->{_stopping}` while an ordinary
`listen()` held the flag for its own control query, concluded it was told
to stop, and exited permanently. `listen()` only replays the channel it was
called for, so a channel subscribed before the interleaving was silently
dropped: the object reported itself connected with N subscriptions and one
of them dead, with no error and no log line — verbatim the failure class
item 65 exists to prevent, produced by a different mechanism than the one
that item fixed.

Pre-existing on `main`, not introduced by item 65's fix — the identical
script against the commit before that work produced byte-identical output.

Fixed by splitting the flag. `{_stopping}` now means only "teardown asked
me to stop," set by `disconnect`/`_pool_shutdown`/`DESTROY` and read by
`_reconnect_loop`. A separate `{_listener_paused}`, set by `_stop_listener`
and cleared only by `_ListenerGuard::restore`, carries the "a control query
has the listener stopped for a moment" meaning instead; `_listener_loop`
checks both. This also closes the latent second problem the flag shared:
`restore` no longer touches `{_stopping}` at all, so it can no longer
clobber a teardown in progress the way it unconditionally could before.

One consequence the split itself introduced, caught during implementation
rather than left for later: `_stop_listener` is called directly by
`disconnect()`, not only through `_ListenerGuard`, so its call has no guard
to clear `{_listener_paused}` afterward. Left alone, a later `_establish`
would find the flag still set and its fresh listener loop would refuse to
ever poll — reconnecting successfully while silently never delivering
anything again. `_establish` and both of `disconnect()`'s exit points now
clear it explicitly.

The window widens with the number of channels an application re-subscribes
on reconnect — 50 channels at roughly 2ms each against a 0.25-0.5s default
backoff is not a tail case.

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

### 16. No connection validation on checkout — FIXED, DIFFERENTLY

`_return_connection` pings on release, but when a connection is taken from the idle pool,
there's no staleness check. A connection that went dead while idle is handed to the caller,
who discovers it on first query.

The item's instinct was right; its proposed mechanism was the expensive one. What it asked
for was validation on checkout, meaning a `ping` every time a connection is handed out. That
was rejected: `ping` is a real round trip on the pool's hottest path, and item 14 removed
exactly that round trip from `DESTROY`, a far colder path. Neither node-postgres nor asyncpg
validates on acquire either.

What shipped instead checks, but without asking the server: a zero-timeout `select` on a
descriptor already to hand, only on the first statement after a connection comes off the
idle list. A readable idle socket means the peer closed. That gates a `ping`, so the round
trip happens only when something is already known to be wrong.

The premise the original fix was built on was disproved by testing, and that is worth
recording because it is the interesting part: a statement on a dead connection succeeds at
`prepare` and at `execute`, and fails only at `pg_result` — by which point it may already
have run, so retrying after a failure is never safe. That is why the check happens before
dispatch rather than after a failure. This was measured directly, and reproduced
independently before the design was changed to rely on it.

Finding one dead connection also discards the idle ones, since whatever killed it has
usually killed them too.

Controlled by `heal_dead_connections`, on by default. See
`docs/superpowers/specs/2026-08-01-heal-dead-connections-design.md`.

### 17. No PubSub reconnect — FIXED

If the listener connection drops (network, server restart), `_listener_loop` either errors
or spins on EOF. All subscriptions are lost silently. No callback or event to detect this.

Two claims here were wrong, and testing found it. Terminating the listener's
backend produces no spin on end of file: the loop fails cleanly with zero CPU
use. Nor is the failure silent; it reaches `on_log`. What was actually broken
was narrower: `is_connected` reported true while holding a dead connection, and
delivery stopped for good.

Fixed together with item 49. See
`docs/superpowers/specs/2026-07-31-pubsub-reconnect-design.md`.

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

### 19. No waiter queue bound

Under spike load, the waiting queue is unbounded (limited only by memory). Thousands of
waiters can queue up, each with a timer future.

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

### 30. `Async::DBD::Pg::Results` has almost no POD — FIXED

Just NAME and AUTHOR. This is the object every query returns — `rows`, `columns`, `count`,
`first`, `scalar`, `is_empty` are all undocumented. This is the single biggest doc gap.

### 31. `Async::DBD::Pg::Connection` public methods undocumented — FIXED

`query`, `transaction`, `cursor`, `release`, `cancel` have no `=head2` entries. The
`{timeout => N}` option, transaction isolation levels, savepoint nesting — none described.

### 32. `Async::DBD::Pg::PubSub` methods undocumented — FIXED

`listen`, `unlisten`, `notify`, `disconnect`, `connect` have no `=head2` entries. Callback
signature (`$channel, $payload, $pid`) is shown in SYNOPSIS but never described.

### 33. Pool-level pub/sub methods undocumented — FIXED

**File:** `Pg.pm`

`listen`, `unlisten`, `unlisten_all`, `notify`, `pubsub`, `is_healthy`, `safe_dsn` have no
`=head2` entries.

### 34. Error subclass accessors undocumented — FIXED

**File:** `Error.pm`

`Error::Query` fields (`code`, `state`, `constraint`, `detail`, `hint`, `position`),
`Error::Connection::dsn`, `Error::PoolExhausted::pool_size`, `Error::Timeout::timeout` —
none described.

### 35. `Async::DBD::Pg::Util` exports undocumented — FIXED

`parse_dsn`, `safe_dsn`, `convert_placeholders` are exportable but have no `=head2` entries.

### 36. Pool constructor parameters only partially documented — FIXED

`connect_timeout`, `statement_timeout`, `max_queries`, `on_connect`, `on_release`, `on_log`
are listed in SYNOPSIS but have no individual descriptions of types, defaults, or callback
signatures.

---

## Section 6: Test Coverage Gaps (needed for production confidence)

### 37. Cursor module: zero tests — FIXED

`next`, `each`, `all`, `close`, owns-transaction commit, exhaustion detection — the entire
module is untested. This is the largest single gap.

### 38. Pool exhaustion/waiting queue: zero tests — FIXED

The queue logic, timeout, `Error::PoolExhausted`, waiter handoff on release — the most
complex pool path has no coverage.

### 39. Per-query timeout: zero tests — FIXED

`_query_with_timeout`, cancel-on-timeout, `Error::Timeout` — completely untested (and as
noted in item 1, also broken).

### 40. `Results::new($sth)` never tested — FIXED

Every unit test uses `new_from_data`. The live DBI path through
`fetchall_arrayref`/`NAME`/`finish` is only exercised indirectly via integration tests.

### 41. Error SQLSTATE mapping: 2 of 15 codes tested — FIXED

Only `23505` and `42601` are covered. The remaining 13 entries in `%STATE_MAP` are untested.

### 42. PubSub error paths untested — PARTLY FIXED

Callback throwing, connection loss, `_process_notifications` error handling,
`_pool_shutdown`.

A callback that dies is covered: the other callbacks for that channel still run, the failure
is reported through `on_log`, and the listener keeps delivering afterwards. A failing control
query is covered by t/unit/pubsub.t.

Still uncovered: losing the listener connection, and `_pool_shutdown`. Both need the
connection to be broken underneath a running listener, which is worth doing together with
item 17, reconnect, since that is the behaviour being tested for.

### 43. `on_release` callback: untested — FIXED

The ROLLBACK-if-in-transaction path and callback failure handling.

### 44. `_return_connection` edge cases: untested — FIXED

`ping` failure, `max_queries` discard, waiter handoff.

### 45. No concurrency tests — FIXED

No tests for simultaneous pool acquisition, race between timeout and connection
availability, or multiple PubSub listeners receiving notifications concurrently.

Covered as part of fixing items 10 and 11: simultaneous acquisition against a limit of two,
a waiter that is served when a connection frees up, a waiter that gives up while queued, and
concurrent pub/sub connect. Several of these failed against the code as it was.

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

### 49. PubSub reconnect with subscription recovery — FIXED

Mojo::Pg has `reconnect_interval` and emits disconnect/reconnect events. AnyEvent::Pg::Pool
auto-resubscribes channels after reconnect. Our PubSub silently dies on connection loss.

For a feature that is inherently long-lived (listeners run for hours/days), silent failure
on connection loss is unacceptable. Implement:
- Configurable `reconnect_interval`
- Automatic re-LISTEN for all registered channels on reconnect
- `on_disconnect` / `on_reconnect` callbacks so the application knows

Implemented as `reconnect`, off by default, with `reconnect_min_interval`,
`reconnect_max_interval` and `on_reconnect`. The wait doubles from the minimum
to the maximum and is jittered, so many listeners do not reconnect to a
recovering server in lockstep.

Two measured facts kept this small: the listener future fails when the
connection dies, so it is already a precise trigger and no health check was
needed, and the channel registry survives the failure, so it can be replayed
unchanged.

Scope was settled by `PAGI::Middleware::Channels`, whose Redis backend passes
`reconnect` through to `Async::Redis` rather than implementing it. Reconnect
belongs to the transport client. Replay of notifications missed while
disconnected does not, and cannot be done with `LISTEN`/`NOTIFY` alone; that
belongs to a messaging layer with its own storage, where
`Backend::Role::History` already lives.

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


---

## Section 11: Pool Shutdown

### 60. No way to close the pool — FIXED

There was no public teardown. `_close_all_connections` was private and reached only from
`DESTROY` and fork detection, so an application had no way to say it was finished with a
pool. Three things followed from that:

- The pub/sub listener holds a connection for as long as it is subscribed, and the only way
  to get it back was to still be holding the pub/sub object and call `disconnect` on it.
- The idle reaper timer could keep the event loop alive for up to `idle_timeout` at exit.
- There was no way to drain before a deploy: stop accepting work, let queries in flight
  finish, then close.

Relying on `DESTROY` is not a substitute in async code, where a future holding a connection
keeps the pool alive and destruction order at exit is not something to depend on.

**Modelled on the two pools that solved this already.** node-postgres `end()` waits for
checked out clients to come back, then closes the clients and the pool timers, and refuses
`connect()` afterwards. asyncpg pairs a graceful `close()`, which waits for every connection
to be released, with `terminate()`, which does not wait at all.

`shutdown` takes both: it drains by default, `force => 1` does not wait. asyncpg's own
documentation recommends wrapping `close()` in a timeout because it can hang, so `timeout`
is offered directly rather than left as something each caller has to remember.

Queued callers are failed rather than left waiting, since no connection is coming. This is a
deliberate difference from node-postgres, whose `_pulseQueue` returns early once the pool is
ending, leaving anything already queued unserved.

**This uncovered a leak in the existing teardown.** `PubSub::_pool_shutdown` set
`conn = undef` without releasing the connection. The pool keeps its own reference in the
active list, so dropping that one left the connection checked out to nobody: it was never
closed, never reused, and a drain would have waited on it forever. It is released properly
now.


### 61. Cancelling a connect attempt leaked its slot — FIXED

Both defects were introduced by the fixes for items 10 and 6, and both had the same shape:
state was restored on the line after an `await`, which never runs when the caller cancels,
because cancelling tears the suspended sub down where it stands.

**The pool.** `connection` incremented `_connecting` before the handshake and decremented it
afterwards. A caller giving up mid-handshake left the count raised for good. Measured: three
cancelled attempts against `max_connections => 2` left `_connecting` at 2, after which
`_committed_count` was always at the limit and no connection could ever be created again.
The pool was bricked, silently, and every later caller queued until its timeout.

Now held by a guard object whose destructor releases the slot, so it unwinds however the
attempt ends: returning, dying, or being cancelled while suspended.

**Pub/sub.** `connect` stored the shared attempt in `_connecting` and deleted it after
awaiting. A caller giving up left the cancelled attempt in place, and every later `connect`
awaited a future that was already cancelled, so the listener could never be established
again. Cleared from an `on_ready` handler instead, which fires on completion, failure and
cancellation alike.

Worth remembering as a shape rather than two bugs: in an async sub, anything that must be
undone cannot be undone by the code after the `await`. It needs a guard or a callback on the
future.


### 62. Cancellation left statements and the listener stranded — FIXED

The same shape as item 61, found by sweeping deliberately for it rather than by stumbling
over it, and both predating this series rather than being introduced by it.

**Statement handles.** `_execute_async` released the in-flight handle on the error paths and
handed it to Results on success. A caller cancelling the query did neither, so the handle
stayed on the connection until the next query overwrote the slot, at which point DBI
collected it while still active and said so. Now held by a guard that releases from its
destructor.

That exposed a second detail. Finishing the handle is not enough on its own when the
statement is still running: the server has to be told to stop first, which is why the
timeout path worked, since it cancels before releasing. The guard's destructor now cancels
and then releases, and the warning goes away.

**The listener.** `_run_control_query` stops the listener, runs a statement, then clears
`_stopping` and starts it again. A cancelled control query skipped both, leaving the flag
set and the listener stopped: notifications simply stopped arriving, with nothing logged and
nothing thrown. It self-healed on the next control statement, which made it the kind of
fault that comes and goes. A guard restores the flag and restarts the listener however the
statement ends.

**The pattern, stated once.** In an async sub, anything that has to be undone cannot be
undone by the code after the `await`. A caller may cancel while the sub is suspended, which
tears it down where it stands. Undo belongs in a guard object's destructor, or in a callback
on the future. Four separate defects in this distribution came from getting that wrong.


### 63. Background work could outlive the pool — FIXED

Found by reading Conduit after item 21, rather than from this list.

Releasing a connection finishes in the background when there is a transaction to roll back
or an `on_release` callback to run, and `_ensure_min_connections` creates connections the
same way. Both ended in `->retain`: started, with nothing holding them and nothing able to
stop them.

So a release that was still in flight when `shutdown` ran would finish afterwards and call
`_release_to_idle_or_waiting`, which put the connection back into a pool that was already
closed. Measured: `is_shut_down` true, `total_count` 1, and an open connection that nothing
would ever close. A connection leak that only appears if you look after shutdown returns.

Both paths now check the flag and close instead of returning the connection, and the pool
keeps a handle on the futures it starts so `shutdown` cancels whatever is left. That is the
part of Conduit's `Future::Selector` collection that applies to a library, without the
selector's own run loop.


### 64. `->retain` used as a substitute for ownership — FIXED

`->retain` says only that a future must not be cancelled when the last reference goes. It
says nothing about who owns the work, what happens if it fails, or how to stop it. Used on
its own it means starting something and hoping, which is how item 63 happened.

There is no `->retain` left in the distribution.

- Background pool work is held in the `_background` collection, which both keeps it alive
  and gives `shutdown` something to cancel. Retaining as well would have made it
  uncancellable, which is the opposite of what was wanted.
- Restarting the listener returned an already complete future, since `_start_listener`
  awaits nothing and only builds and stores the loop's future. There was nothing to retain,
  only a failure that was being dropped, so it is logged instead.

The general form: if a future is worth starting, something should own it and something
should look at how it ends. `->retain` supplies neither.

### 65. Pub/sub reconnect can orphan a pooled connection — FIXED

`connect()` and `_reconnect_loop` both decide independently whether to
reconnect, and neither consults the other. `connect()` shares concurrent
explicit callers through `{_connecting}`; the supervisor checks only
`unless ($self->{connected} && $self->{conn})` before checking out a connection
of its own. Whichever `_establish` finishes last silently overwrites `{conn}`
and `{connected}`, abandoning the other connection — and any `LISTEN` issued on
it — without returning it to the pool.

The abandoned connection is never released. `active_count` stays at 1 after
`disconnect()` instead of dropping to 0, so each occurrence permanently costs
the pool one connection, and any channel registered on the losing connection
stops delivering while still appearing subscribed.

Normally invisible: `listen()`'s own reconnect is a single fast round trip that
finishes long before the supervisor's backoff elapses. Under scheduler or IO
contention that fast path can still be in flight when the supervisor wakes.
Reproduced deterministically by delaying one pool checkout by 0.3s and dropping
`reconnect_min_interval` to 0.1s, which produces three connections where there
should be one and leaves the second permanently orphaned.

Observed in the test suite at roughly 6 occurrences in 70 runs of
`t/integration/pubsub.t`, usually as 'listen() during the reconnect backoff does
not orphan a connection'.

Fixing this means making the two paths coordinate — either extending the
`_connecting`-sharing pattern so it also covers and consults
`_reconnect_future`, or folding both into a single slot both paths check. That
is a design change to the reconnect coordination rather than a local fix, so it
is deliberately not bundled with unrelated work.

Fixed by giving `connect()` sole ownership of the one shared attempt, kept in
`_connecting`. The supervisor now reaches it the same way any other caller does,
rather than checking out a connection of its own, so the two paths can no longer
disagree about which connection is current. Concurrent awaiters each hold a
`without_cancel` view onto that attempt, so one caller giving up cannot fail it
for the others still waiting on it, and a count of active awaiters cancels the
underlying attempt only once the last of them has left. Separately, the listener
loop was changed to read notifications from the connection it actually polls
rather than whatever `{conn}` currently holds, closing the other route by which
two connections could end up coexisting unnoticed.

Sharing one connection is only safe if issuing statements on it is also
serialized: once `_reconnect_loop`'s replay and an ordinary `listen()` can
both reach the connection the moment a shared connect resolves, DBD::Pg
refuses a second async query while the first is in flight. Fixed by a
`{_control_query}` mutex in `_run_control_query`, claimed with a
re-checking `while` loop (a single `if` would reproduce the same
check-then-act defect one level up) and released by a guard on every path,
including cancellation. See item 66 for a shipped bug the mutex's own
implementation surfaced, and item 68 for a hazard fixed alongside it.
`disconnect()` and `_pool_shutdown()` were also changed to cancel a
control query still in flight before releasing the connection, and to tell
a waiter woken by that cancellation that teardown is underway rather than
let it issue a query of its own on a connection about to be released out
from under it — without this, the connection-sharing fix above would trade
the orphaned-connection bug for a permanent hang on every `listen()` after
a `disconnect()` that raced an in-flight control query.

### 66. Queued pool callers could never `->get` their connection, only croak — FIXED

**File:** `Async/DBD/Pg.pm:407-413` (the pool's queue-and-wait branch)

`Future::AsyncAwait` builds the pending placeholder a suspended `async sub`
returns by cloning whatever future it is currently suspended on — `Future`'s
own `AWAIT_CLONE` is `shift->new`. A plain `Future->new`, which the pool used
to hand a queued caller its eventual connection, has no event loop of its
own: `->get`/`->await` on one that is not yet ready can only croak
("...is not yet complete and does not provide ->await"), never block. The
poisoning propagates through every nested `async sub` between the queue and
whoever called `->get`, so this reached `$pg->connection->get` itself — the
documented, synchronous way this distribution's own examples and tests
acquire a connection.

Reproduced directly, no pub/sub involved: exhaust a `max_connections => 1`
pool and call `->get` on the second requester. Croaks on `main`.

A prior author had already hit this and worked around it in test code --
`t/pool/basic.t`'s `settle()` helper polls `is_ready` in a loop instead of
calling `->get` directly, with a comment naming the same limitation.

Fixed by `pending_future()` (`Async::DBD::Pg::Util`), a leaf `Future`
cloned from a real, immediately-cancelled `Future::IO` future rather than
`Future->new` — using `Future->new`'s documented instance-method form
("construct another in the same class"), not an undocumented one. A cached
prototype was considered and rejected: it would fix the class at whichever
implementation loaded first, and a consumer switching implementations later
via `Future::IO->override_impl` would silently get a real-implementation
future back from a mocked reactor. Built fresh per call instead; measured at
11.3µs (UV) / 16.8µs (IOAsync) per call, noise beside the round trip it
wraps. Now backs the pool's queue branch and the pub/sub control-query mutex
(item 65). Covered by a permanent regression test in `t/pool/basic.t`.

### 68. `_run_control_query` did not re-check `{conn}` after acquiring its slot — FIXED

**File:** `PubSub.pm` (`_run_control_query`)

A waiter parked behind another caller's control query for the mutex added
in item 65 could be woken after the listener's `on_fail` had deleted
`{conn}` in the meantime, and dereferenced it without revalidating: `Can't
call method "query" on an undefined value` instead of a real
`Async::DBD::Pg::Error::Connection`. Caught by the surrounding `eval` and
cleaned up correctly either way, so the damage was the message, not
corrupted state — but a caller could not distinguish "the connection went
away" from a bug in the library.

Fixed alongside item 65's teardown-cancellation fix, since both touch the
same call site: `{conn}` is re-read immediately before use, after the
mutex wait and the listener-stop wait, and a missing connection now dies
with a proper `Error::Connection` naming what happened.

### 69. The pool's queue branch registers no `on_cancel`

**File:** `Async/DBD/Pg.pm:411-417` (the "3. Queue and wait" branch of
`connection()`)

A cancelled queued caller is spliced out of `{waiting}` only lazily, by
`_release_to_idle_or_waiting` the next time a connection is actually
released (`next if $waiting->{future}->is_ready` skips settled entries).
If no connection is ever released afterward, the stale entry sits in
`{waiting}` indefinitely and `waiting_count` reports a wrong number. It
never hands a connection to a caller that is no longer waiting for one —
the `is_ready` check already handles that — so the damage is a wrong
statistic and a small, bounded leak of a hash entry, not a correctness
bug.

Not fixed here. `t/integration/pubsub.t`'s `'abandoning a queued connect
does not leave a waiter behind'` (the comment at `:401`) depends on the
current lazy-splice behaviour and documents it; adding a proper
`on_cancel` will need that comment and its `waiting_count` assertions
revisited.

### 70. `connect()` racing `disconnect()`'s `UNLISTEN *` can leave a connection checked out to an object reporting itself disconnected — FIXED

**File:** `PubSub.pm` (`disconnect`, `_establish`)

`disconnect()` has one real suspension between deciding to tear down and
finishing: `await $conn->query('UNLISTEN *')` (`:583`). A `connect()` (via
an ordinary `listen()`, or the reconnect supervisor) arriving during that
window runs `_establish`, which checks out a fresh connection
independently of what `disconnect()` is doing. When `disconnect()`
resumes it unconditionally sets the terminal state (`:590`) — clobbering
the `connect()` that ran concurrently. The result: the object reports
itself disconnected, `{conn}` still holds a real checked-out connection,
and `active_count` stays at 1, with no error and no log line — item 65's
failure mode, arriving through a different door than the one that item
closed.

Pre-existing, not introduced by the fix wave that found it — identical at
`781bc9b`, the commit before it.

**Survives the phase model, and gained a wrinkle.** The mechanism above
was originally written in terms of a `connected` boolean; the phase-model
branch replaced that boolean with `{phase}` and the race came through
unchanged, so the description is restated here against the current code.
`disconnect()` now cancels an in-flight `{_connecting}` early (`:566`),
which closes the case where an attempt was *already* running — but a
`connect()` arriving later, at the `UNLISTEN *` await, creates a fresh
attempt that teardown has already passed. `disconnect()` deletes `{conn}`
before that await and releases only the connection it captured, so the
new checkout is the one left stranded.

The wrinkle: `_establish` opens by setting `{phase} = 'connecting'`
(`:146`), overwriting the `'closing'` that teardown set as its
in-progress signal. Anything that gates on `'closing'` — including
`_run_control_query`'s refusal at `:479` — stops seeing a teardown that
is still running.

Note for anyone reading the review notes alongside this: `'connecting'`
has no reader — nothing branches on that value — and was recorded
separately as a Minor for that reason. The two records do not conflict.
The *read* side is inert; the *write* side is not, because the assignment
destroys `'closing'`. Do not conclude from "no reader" that the line can
be left alone.

**Demonstrated, then fixed.** The source reading above was confirmed by
reproduction under both `Future::IO::Impl::UV` and `::IOAsync`: widening
the `UNLISTEN *` await and letting an ordinary `connect()` arrive in the
window leaves `active=1 idle=1`, `is_connected` false, and `{conn}` still
holding a connection — a live checkout behind an object reporting itself
disconnected, with no error and no log line. `shutdown` still returns, so
the symptom is the stranded checkout rather than a wedged pool.

Fixed in `connect()`, the only route into `_establish`: it now refuses
with `Error::Connection` while `{phase}` is `'closing'`, matching
`_run_control_query`, which already declines the same way and with the
same message once teardown has begun. Refusing rather than queueing keeps
the two teardown-time refusals identical, and `'closing'` stays
non-terminal — once the disconnect settles, `{phase}` is `'disconnected'`
and connecting works again.

This also closes the wrinkle above by construction: `_establish` was the
only writer of `{phase} = 'connecting'`, and it is now unreachable while
teardown holds `'closing'`, so the assignment can no longer destroy the
in-progress signal.

Covered by `t/integration/pubsub.t`'s `'a connect arriving during
teardown does not strand a connection'`, which asserts the invariant
(nothing checked out, nothing held) separately from this build's chosen
resolution (the refusal), and pins that a connect after teardown settles
still works. Mutation-verified: removing the refusal reds the
stranded-checkout assertions, not merely the refusal ones.

### 71. The listener's pause around control queries is load-bearing — FIXED, and it exposed item 75

**File:** `PubSub.pm` (`_listener_loop`, `_stop_listener`, `_ControlQueryGuard::release`)

This item previously recorded that the pause was "probably not load-bearing"
and that the stop/restart dance could likely be deleted. **That conclusion was
wrong.** The fragmentation experiment it called for was run, and it reversed
the verdict.

Removing the pause entirely — no `_stop_listener`, no restart, no slot checks
in `_listener_loop` — deadlocks the *first* control query, reproducibly, under
both `Future::IO::Impl::UV` and `::IOAsync`:

    [ctl] issuing: LISTEN frag
    [listener] poll woke, consuming
        ...the query never completes

Both the listener and the in-flight query poll the same fd. Whichever wakes
first calls `PQconsumeInput` and drains the socket; the other is parked in
`Future::IO->poll` waiting for readability that has already been consumed, and
nothing will make that fd readable again. The collision is **readiness theft**,
not data corruption.

That is why the earlier source analysis missed it. It examined protocol
demultiplexing and payload integrity, and was correct about both — libpq does
buffer partial messages safely, and two call sites consuming input do not
corrupt each other. It simply never asked who owns the socket's *readiness*.

It also explains why the earlier mutation survived the whole suite. That
mutation stripped only `_listener_loop`'s slot checks while leaving
`_stop_listener` in place, so the listener was still stopped for the duration
of every control query and the collision was never reachable. It was testing
the second line of defence while the first still held — an equivalent mutant,
for a reason that could not be seen without removing both.

**At the time this was written, the pause stayed and the stop/restart dance
was not deleted.** Its cost was measured and was not the problem: during a
real `LISTEN`, delivery latency was 1.7 ms against a 1.2 ms idle baseline. It
was not a sleep — `_stop_listener` cancelled the poll and awaited the
teardown, and the event loop was never blocked. That verdict was correct for
a *naive* deletion, one that left nothing in the collision's place. It does
not describe what shipped below, which removes the second reader instead of
deleting one side of the collision between two.

The comparison that settled the design was Mojo::Pg, which has no pause
because it has no second reader: one `io` watcher on the socket drains
notifications first and then checks whether the in-flight query's result is
ready. Collapsing to a single reader was identified here as the only way to
remove the pause, and it has now shipped, across five commits:

- `207bed1` extracted the async result-readiness check into
  `Connection::_result_ready` — wrapped once, unable to throw — so the
  listener can call it on a query's behalf without a DBI exception killing
  the listener.
- `c59364c` let a `Connection` nominate a poll delegate: when one is
  installed, a query awaits it instead of polling the socket itself, making a
  second reader on the fd impossible rather than merely avoided.
- `f42517f` made the pub/sub listener install that delegate for exactly its
  own lifetime (`_ReaderGuard`), and complete a waiting control query itself
  once it sees the result is ready. `_run_control_query` no longer calls
  `_stop_listener`, and `_ControlQueryGuard::release` no longer restarts it.
  The `{_control_query}` mutex stays — DBD::Pg still cannot run two async
  operations on one handle, and serializing control queries is a different
  job from pausing the listener, which happened to share the same field.
  This commit also caught and fixed the stall recorded in item 75's update
  below.
- `b7d6281` and `9cc3936` covered the new failure paths: a query error
  reaches its caller with the listener intact, a cancelled query leaves no
  stale waiter, and a listener that stops fails whoever was still waiting on
  it — the last of these reached only by deliberately killing the loop
  mid-iteration, since the more obvious route (killing the backend) resolves
  the query through its own ordinary completion path first and never reaches
  the guard.

The pause is gone. `_stop_listener` still exists — its only remaining caller
is `disconnect()`, which still needs to stop a running listener before
releasing the connection — not `_run_control_query` and not
`_ControlQueryGuard`; that is a different job from pausing the listener for
every control query. Measured after the refactor: a real `LISTEN` now costs 1.3 ms
against a 1.4 ms idle baseline under `Future::IO::Impl::UV`, and 1.2 ms
against 1.2 ms under `::IOAsync` — the penalty recorded above is gone
entirely, not merely reduced.

### 72. The `closing` phase does double duty

**File:** `PubSub.pm` (`{phase}`)

`closing` means both "teardown is in progress" and "terminally shut". The
phase model replaced booleans whose overloading caused item 67, and this
is the one place where the same ambiguity survives in the new field.
Nothing depends on distinguishing the two today, which is why it was left
alone. It matters if a caller ever needs to tell "wait for teardown, then
retry" from "this object is finished" — a `shut` phase would separate
them.

### 73. Teardown cancels in-flight work by name, not from a registry

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

### 74. `_CheckoutGuard::DESTROY` has no `${^GLOBAL_PHASE}` check

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

### 75. Notifications arriving during a control query stalled indefinitely — FIXED

**File:** `PubSub.pm` (`_listener_loop`)

Found by the experiment item 71 called for, not by the review that
requested it.

`Future::IO->poll` reports on the **socket**; `pg_notifies` and `pg_ready`
both consume from the socket into **libpq's internal buffer**. Those are
different places, and the listener waited on the wrong one.

A notification arriving while a control query held the pause was consumed
off the socket by that query's own `pg_ready`, together with the result it
was waiting for. When the query finished and the guard restarted the
listener, the loop's first act was `await Future::IO->poll($sock, POLLIN)`
— on a socket with nothing left on it. `pg_notifies` was never called, so
the notification sat in the buffer, invisible, until unrelated later
traffic happened to make the socket readable again. On a quiet connection
— the ordinary pub/sub case — that is never.

Silent and unbounded: no error, no log line, and the notification is not
lost, merely undeliverable. Measured before the fix, 4 rounds of 40
notifications each: 120/160 delivered, and still 120/160 after a 25-second
uncontended drain. One further unrelated `NOTIFY` then released the entire
backlog at once — 161 — which is what proved they were buffered rather
than dropped.

Fixed by draining before parking rather than after waking:

    while ($self->{phase} eq 'live' && !$self->{_control_query}) {
        $self->_process_notifications($conn);
        await Future::IO->poll($sock, POLLIN);
        last unless $self->{phase} eq 'live' && !$self->{_control_query};
    }

The pause now always ends in a drain, so nothing can be stranded across
one. The connection's own query path already had this ordering right —
`_wait_for_result` checks `pg_ready` before polling — and the listener was
the only reader doing it backwards. 160/160 after, both implementations.

**Why there is no delivery *during* a control query, and no test asserting
it.** An earlier version of this fix added a `Connection` input-observer
hook so the query's own poll loop would drain notifications while it ran.
It was removed: PostgreSQL does not send `NOTIFY` to a backend that is
busy executing a command. Measured — with a `NOTIFY` sent 50 ms into a 2 s
query on the listening connection, that connection's socket did not become
readable until the query completed. There is nothing to deliver mid-query,
so the hook could only ever repeat, a few milliseconds earlier, what the
listener restart already does. Delivery latency during a real `LISTEN` is
1.7 ms against a 1.2 ms idle baseline.

Covered by `t/integration/pubsub.t`'s `'a notification arriving during a
control query needs no later traffic to appear'` — which sends nothing
after the notification, so a build that depends on a later socket wake
fails — and `'a notification queued during a long control query arrives
promptly after it'`. Mutation-verified: restoring the old ordering reds
both.

**Update, single-reader refactor (item 71):** the same bug class recurred at
a second point once the pause was removed. `_listener_loop` now completes a
waiting control query itself with `$waiter->done` when it sees the result is
ready. That resumes the waiting query's frame synchronously, all the way
through its own `pg_result`, which can consume everything currently on the
socket — trailing notification bytes included — into libpq's buffer without
draining them as notifications, the identical mechanism as above, at a
different call site. Going straight to `await Future::IO->poll($sock,
POLLIN)` after completing the waiter would then park on a readability event
that had already happened, stranding whatever had arrived. The drain-before-
poll ordering above used to live in a separate inner loop — the pause's own
loop, shown in the code sample above, that ran only between control queries.
That inner loop is gone along with the pause; the ordering now lives directly
in `_listener_loop`'s single unified loop (`f42517f`), unconditionally on
every iteration, since there is no longer a window where the listener stands
down for the ordering to be scoped to. It survived that restructuring because
it is not this codebase's own invention — Mojo::Pg's single `io` watcher has
the identical invariant, drain before checking readiness, for the identical
reason: it is what a single reader must always do, not an artifact of the
pause. Fixed by `next` after completing the waiter rather than falling
through to the poll: it re-enters the loop at the top, which drains first and
re-tests the `while` condition — needed because the resumed query's own code
(error handling, a user callback, even a `disconnect` call) can invalidate
that condition before the loop would otherwise reach it.

**The asymmetry this exposed, the single most useful fact from that branch:**
the two ways of breaking this ordering are not equally visible.

- Removing the whole waiter-completion stanza (`if ($waiter &&
  $conn->_result_ready) { ... }` in its entirety) is caught by the ordinary
  suite, immediately, as a hang — the first `listen()` anywhere in the file
  never completes, because nothing ever resolves `{_query_waiter}`.
- Removing *only* the `next` — falling through to the poll instead of
  restarting the iteration — is caught by **nothing** in the ordinary suite.
  The full suite passed `189/189`, zero bytes of stderr, both `Future::IO`
  implementations, with the bug present. Only the fragmentation experiment
  (`scratchpad/frag-experiment.pl`, described above) caught it, as a backlog
  that stalled at 122–123/160 until an unrelated later `NOTIFY` flushed it —
  because the failure mode is silent stranding, not a hang or a thrown
  error, and no assertion in the suite observes "did every already-arrived
  notification get delivered without needing later traffic."

A green suite is not evidence the notification path is correct. Run the
fragmentation experiment — not just the ordinary suite — against any future
change to `_listener_loop`.

### 76. The backend-kill helpers terminated every connection on the database — FIXED

**File:** `t/integration/pubsub.t`, `t/pool/basic.t`, `t/pool/shutdown.t`,
`t/lib/Test/Async/DBD/Pg.pm`

Three test helpers simulated a dropped connection with

    SELECT pg_terminate_backend(pid) FROM pg_stat_activity
     WHERE datname = current_database() AND pid <> pg_backend_pid()

which terminates **every** connection to that database, with no notion of
ownership. Pointing `TEST_PG_DSN` at a PostgreSQL instance shared with anything
else — a contributor's own service, another project — meant running the suite
killed that software's connections. Not a flaky test: destructive behaviour in
someone else's environment.

CI never saw it, because the workflow provisions a dedicated `services:
postgres` container. Only humans hit it.

**This was previously recorded here as intermittent suite flakiness. That was
wrong.** Eighteen consecutive full-suite runs on a quiet database produced zero
failures and zero collision signatures. Every failure ever observed carried the
`terminating connection due to administrator command` signature and occurred
while something else was using the database — mostly a second agent, and mostly
put there by me.

Fixed by tagging the suite's own connections and scoping the kills to them.
`Test::Async::DBD::Pg` sets `PGAPPNAME` at load:

    BEGIN { $ENV{PGAPPNAME} = "async-dbd-pg-test-$$" }

libpq reads it at connect time, so it covers the pool's connections, anything
an `on_connect` hook opens, reconnects, and the helpers' own `DBI->connect` —
verified for each. Each helper then adds `AND application_name = ?`. Covered by
`t/integration/pubsub.t`'s `'kill_backends leaves connections it does not own
alone'`, which stands a bystander connection on the database under a different
application name and asserts it survives. Confirmed red before the fix.

**Still open: two concurrent runs of this suite against one database still
interfere, for an unrelated reason.** `LISTEN`/`NOTIFY` channel names are a
per-database namespace, and the suite uses 72 distinct literal channel names.
Two runs both `LISTEN 'cb_error_test'`, both `NOTIFY` it, and each sees the
other's notifications — measured after this fix: both runs fail, with zero
collision signatures, on assertions counting received payloads. Connection
tagging cannot address this; it would need per-process channel names. Until
then, **one suite run per database at a time**, and see the measurement
guidance below.

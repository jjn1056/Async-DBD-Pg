# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Async::DBD::Pg is an event-loop agnostic async PostgreSQL client for Perl, built on top of DBD::Pg/DBI with Future::IO as the async abstraction layer. It provides non-blocking database access via connection pooling, named and typed placeholders, transactions with optional retry and advisory locks, cursors, pub/sub (LISTEN/NOTIFY), an optional prepared-statement cache, and query observability through an `on_query` hook.

## Common Commands

All Perl commands must use perlbrew (see global CLAUDE.md for setup). Prefix commands with:
```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default
```

### Testing

```bash
# Unit tests only (no database required)
prove -l t/unit/

# All tests (requires PostgreSQL - see "Test Database" below)
TEST_PG_DSN="postgresql://postgres:test@localhost:5432/test" prove -r -l t/

# Single test file
TEST_PG_DSN="postgresql://postgres:test@localhost:5432/test" prove -l t/integration/connection.t

# Verbose output
TEST_PG_DSN="postgresql://postgres:test@localhost:5432/test" prove -r -l -v t/
```

### Test Database

Start PostgreSQL via Docker Compose:
```bash
docker compose up -d
```
Default: `postgresql://postgres:test@localhost:5432/test` (PostgreSQL 16-Alpine).

`TEST_PG_DSN` is required — there is no default. Without it the integration
and pool tests skip; only the unit tests run. This is deliberate: the suite
creates and drops data and terminates backends, so it runs only against a
database named explicitly.

`PG_PORT` overrides the published host port when 5432 is already in use
(`PG_PORT=5433 docker compose up -d`); `TEST_PG_DSN` must then name the same
port. Check which port the container actually published before running the
suite — `docker ps` — rather than assuming the documented default.

Stop: `docker compose down` (add `-v` to destroy data volume).

### Building

Uses Dist::Zilla. Install deps: `dzil listdeps --missing | cpanm`

### Running Examples

```bash
DATABASE_URL="postgresql://postgres:test@localhost:5432/test" perl -Ilib examples/01-basic-query/app.pl
```

## Architecture

### Module Hierarchy

- **Async::DBD::Pg** (`lib/Async/DBD/Pg.pm`) - Connection pool manager. Entry point for all database work. Manages min/max connections, idle/active lists, waiting queue, fork detection, and pool statistics. Also provides pub/sub factory methods.

- **Async::DBD::Pg::Connection** (`lib/Async/DBD/Pg/Connection.pm`) - Wraps a single DBI database handle. Executes async queries via `Future::IO->poll()` on the socket fd. Supports named placeholders (`:name`), typed bind parameters (by `PG_*` constant or by type name), transactions with nested savepoints and optional retry, transaction-scoped advisory locks, cursors, query timeouts, and an optional per-connection prepared-statement cache. Carries an `id` unique within its pool, reported on every `on_query` event.

- **Async::DBD::Pg::PubSub** (`lib/Async/DBD/Pg/PubSub.pm`) - Dedicated LISTEN/NOTIFY connection with per-channel callback management and a background listener loop.

- **Async::DBD::Pg::Cursor** (`lib/Async/DBD/Pg/Cursor.pm`) - Streaming result sets via PostgreSQL cursors. `next()` yields one row, buffering `batch_size` rows per round trip; `each()` and `all()` walk the rest. No `reset()`: a server-side cursor is consumed.

- **Async::DBD::Pg::Results** (`lib/Async/DBD/Pg/Results.pm`) - Query result wrapper. Rows are stored **positionally** with the column names and `pg_type` kept alongside; hashes are derived on demand. Every method that builds a hashref (`rows`, `first`, `single`, `next`, `all`, `by`, `groups`) croaks when column names repeat, rather than collapsing them. Positional access (`arrays`, `row_array`, `first_value`, `first_list`, `preview`, `get_column` by index) works regardless, as does `multi`, which is lossless. Views — `as`, `expand`, `multi` — share the rows and carry their own iterator position. `map_rows` hydrates objects positionally, handing a callback the row arrayref and the shared column names, so N objects are built without N throwaway hashrefs.

- **Async::DBD::Pg::Collection** (`lib/Async/DBD/Pg/Collection.pm`) - A blessed arrayref returned wherever a list of rows or values is handed back, so every arrayref idiom keeps working. Deliberately no `map`/`grep`/`sort`/`reduce`.

- **Async::DBD::Pg::Column** (`lib/Async/DBD/Pg/Column.pm`) - One column's values, from `Results::get_column`. The only way to reach a column whose name is repeated.

- **Async::DBD::Pg::Error** (`lib/Async/DBD/Pg/Error.pm`) - Error class hierarchy with stringification overload. Subclasses: `Error::Query` (with SQLSTATE), `Error::Connection`, `Error::PoolExhausted`, `Error::Timeout`. `Error::Query` carries the server's diagnostics — `constraint`, `table`, `schema`, `column`, `detail`, `hint`, `severity`, `context`, `position` — captured in `_throw_query_error` before anything else can reset them. `is_retryable` and the three violation predicates (`is_unique_violation`, `is_foreign_key_violation`, `is_not_null_violation`) answer on **every** error class, not just on query errors, so a caller never has to guard them with `can`.

- **Async::DBD::Pg::Util** (`lib/Async/DBD/Pg/Util.pm`) - Shared helpers: `parse_dsn()`, `convert_placeholders()` (`:name` to `$1`), `safe_dsn()` (password masking), `pending_future()` (a reactor-safe leaf `Future` for queued waiters and mutex slots).

### Key Design Decisions

- **DBD::Pg-backed, not raw libpq**: Reuses the DBI ecosystem rather than binding libpq directly.
- **Future::IO abstraction**: Works with any event loop (UV, IO::Async, etc.) - the test suite uses `Future::IO::Impl::UV`.
- **Socket fd duplication**: Uses `POSIX::dup()` to wrap the Pg socket in an `IO::Socket` without ownership conflicts.
- **Async connect**: `pg_async_connect` arrived in DBD::Pg 3.19.0 and the required version is 3.20.0, so connect is always asynchronous. There is no runtime capability check and no synchronous fallback.
- **Named placeholders**: `:name` syntax is converted to PostgreSQL `$N` positional params. The converter passes over the regions where a colon is text: quoted strings, `E'...'` escapes, dollar-quoted bodies, and comments (which nest). Removing this was weighed and rejected — see the rejected section of the result-access spec.

- **Two placeholder scanners**: the converter's output is re-parsed by DBD::Pg at `prepare`. `pg_placeholder_dollaronly => 1` confines that second scan to `$1`, which is why jsonb's `?`, `?|` and `?&` operators and the `arr[:2]` slice work here. A unit test of the converter cannot see this layer; only an integration test can.

- **Statement cache keyed on SQL *and* bind types**: a type set with `bind_param` persists on the handle for later executes — DBI documents this — so keying on SQL alone let a handle bound `(untyped, bytea)` hand that type to the next `(untyped, untyped)` call. The key is the converted SQL plus the per-position types; a bind list with no typed position keys on the bare SQL. Clearing a type is not possible and there is no safe synthetic default, because "untyped" is not `PG_TEXT`. See `docs/known-issues/2026-08-06-sticky-pg-type-on-cached-statements.md`.

- **Bind type names resolve from DBD::Pg, not from `pg_catalog`**: `%TYPE_OID` in Connection.pm is derived at load from `DBD::Pg`'s own `:pg_types` exports, which is by construction exactly the set `bind_param` accepts. Resolving through `to_regtype` was tried and reversed: it happily returns the OID of a user-defined enum, which `bind_param` then refuses — and such a type needs no typed bind anyway, being text on the wire.

- **Lossless or loud**: no view may silently drop, collapse, or invent data. Refusals are `croak`s. The `single`/`single_value`/`single_list` warnings are the one exception — they report a row-count expectation mismatch, not data loss.

### Test Structure

- `t/unit/` - Pure unit tests, no database needed. Cover DSN parsing, placeholder conversion, error classes, results, collections, cursors, pool lifecycle, pub/sub logic, and documentation drift.
- `t/integration/` - Require a live PostgreSQL instance. Cover connections, async connect, queries and results, placeholders, typed binds, transactions, cursors, pub/sub, error diagnostics, the statement cache, and the delay proxy itself.
- `t/pool/` - Pool behavior and shutdown.
- `t/unit/docs.t` - Checks the documentation against the real API: every method named in a POD example, in the README, or in `llms.txt` must exist, every SYNOPSIS must parse as Perl, the machine reference must stay inside its token budget, and the public API must be covered by it. Prose is not compiled, so this is what compiles it.
- `t/lib/Test/Async/DBD/Pg.pm` - Test helper: `require_postgres()`, `skip_without_postgres()`, `test_dsn()`. `test_dsn()` returns `$ENV{TEST_PG_DSN}` and nothing else — **there is no localhost fallback**, and the helpers `skip_all` when it is unset. Deliberate: the suite creates and drops data and terminates backends, so it only ever runs against a database named explicitly.
- `t/lib/Test/Async/DBD/Pg/DelayProxy.pm` - A forked TCP proxy that puts a known delay between this library and PostgreSQL, so latency claims can be measured rather than asserted. Runs in a child process because libpq blocks inside connect and an in-process proxy would deadlock the reactor it needs.

### Dependencies

Declared in `cpanfile`, which `dist.ini` reads through `[Prereqs::FromCPANfile]` so a checkout and the released metadata cannot drift apart. Edit dependencies there, not in `dist.ini`.

Runtime: `Future::IO` (>= 0.23), `Future::AsyncAwait` (>= 0.66), `Future` (>= 0.49), `DBD::Pg` (>= 3.20.0), `DBI` (>= 1.643).
Recommended, each loaded at point of use by one method: `Hash::MultiValue` (>= 0.15) for `Results::multi`, `JSON::MaybeXS` (>= 1.004) for `Results::expand`.
Test: `Test2::V0`, `Future::IO::Impl::UV` (>= 0.07), plus the recommended pair so their coverage actually runs.

`DBD::Pg` is pinned with three components on purpose: it declares its version with `qv()`, so a single-decimal `3.20` reads as v3.200.0 and every install fails the prerequisite.

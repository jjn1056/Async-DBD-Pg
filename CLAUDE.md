# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Async::DBD::Pg is an event-loop agnostic async PostgreSQL client for Perl, built on top of DBD::Pg/DBI with Future::IO as the async abstraction layer. It provides non-blocking database access via connection pooling, named placeholders, transactions, cursors, and pub/sub (LISTEN/NOTIFY).

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

- **Async::DBD::Pg::Connection** (`lib/Async/DBD/Pg/Connection.pm`) - Wraps a single DBI database handle. Executes async queries via `Future::IO->poll()` on the socket fd. Supports named placeholders (`:name`), transactions with nested savepoints, cursors, and query timeouts.

- **Async::DBD::Pg::PubSub** (`lib/Async/DBD/Pg/PubSub.pm`) - Dedicated LISTEN/NOTIFY connection with per-channel callback management and a background listener loop.

- **Async::DBD::Pg::Cursor** (`lib/Async/DBD/Pg/Cursor.pm`) - Streaming result sets via PostgreSQL cursors with batch fetching. Provides `next()`, `each()`, `all()` iterators.

- **Async::DBD::Pg::Results** (`lib/Async/DBD/Pg/Results.pm`) - Eagerly-fetched query result wrapper with column names and convenience accessors (`first()`, `scalar()`, `is_empty()`).

- **Async::DBD::Pg::Error** (`lib/Async/DBD/Pg/Error.pm`) - Error class hierarchy with stringification overload. Subclasses: `Error::Query` (with SQLSTATE), `Error::Connection`, `Error::PoolExhausted`, `Error::Timeout`.

- **Async::DBD::Pg::Util** (`lib/Async/DBD/Pg/Util.pm`) - Shared helpers with no dependency on the rest of the distribution. Pure functions: `parse_dsn()`, `convert_placeholders()` (`:name` to `$1`), `safe_dsn()` (password masking). Also `pending_future()`, a `Future` for code that must hand a caller a not-yet-ready future (a queued pool waiter, a mutex slot) — cloned from a real `Future::IO` future rather than `Future->new`, so it stays safe to `get`/top-level `await` even for a caller several `async sub` calls removed from whatever eventually completes it.

### Key Design Decisions

- **DBD::Pg-backed, not raw libpq**: Reuses the DBI ecosystem rather than binding libpq directly.
- **Future::IO abstraction**: Works with any event loop (UV, IO::Async, etc.) - the test suite uses `Future::IO::Impl::UV`.
- **Socket fd duplication**: Uses `POSIX::dup()` to wrap the Pg socket in an `IO::Socket` without ownership conflicts.
- **Async connect detection**: Checks for DBD::Pg >= 3.19.0 at runtime to enable `pg_async_connect`; falls back to synchronous connect on older versions.
- **Named placeholders**: `:name` syntax is converted to PostgreSQL `$N` positional params, handling string literals and `::` type casts to avoid false matches.

### Test Structure

- `t/unit/` - Pure unit tests, no database needed. Cover DSN parsing, placeholder conversion, error classes, results, pool lifecycle, pub/sub logic, backend policy.
- `t/integration/` - Require a live PostgreSQL instance. Cover connections, transactions, pub/sub.
- `t/pool/` - Pool behavior tests.
- `t/lib/Test/Async/DBD/Pg.pm` - Test helper: `require_postgres()`, `skip_without_postgres()`, `test_dsn()`. DSN comes from `$ENV{TEST_PG_DSN}` with fallback to localhost defaults.

### Dependencies

Runtime: `Future::IO` (>= 0.23), `Future::AsyncAwait` (>= 0.66), `Future` (>= 0.49), `DBD::Pg` (>= 3.18), `DBI` (>= 1.643).
Test: `Test2::V0`, `Future::IO::Impl::UV` (>= 0.07).

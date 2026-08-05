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

- **Async::DBD::Pg::Connection** (`lib/Async/DBD/Pg/Connection.pm`) - Wraps a single DBI database handle. Executes async queries via `Future::IO->poll()` on the socket fd. Supports named placeholders (`:name`), transactions with nested savepoints, cursors, and query timeouts.

- **Async::DBD::Pg::PubSub** (`lib/Async/DBD/Pg/PubSub.pm`) - Dedicated LISTEN/NOTIFY connection with per-channel callback management and a background listener loop.

- **Async::DBD::Pg::Cursor** (`lib/Async/DBD/Pg/Cursor.pm`) - Streaming result sets via PostgreSQL cursors. `next()` yields one row, buffering `batch_size` rows per round trip; `each()` and `all()` walk the rest. No `reset()`: a server-side cursor is consumed.

- **Async::DBD::Pg::Results** (`lib/Async/DBD/Pg/Results.pm`) - Query result wrapper. Rows are stored **positionally** with the column names and `pg_type` kept alongside; hashes are derived on demand. Every method that builds a hashref (`rows`, `first`, `single`, `next`, `all`, `by`, `groups`) croaks when column names repeat, rather than collapsing them. Positional access (`arrays`, `row_array`, `first_value`, `first_list`, `preview`, `get_column` by index) works regardless, as does `multi`, which is lossless. Views — `as`, `expand`, `multi` — share the rows and carry their own iterator position.

- **Async::DBD::Pg::Collection** (`lib/Async/DBD/Pg/Collection.pm`) - A blessed arrayref returned wherever a list of rows or values is handed back, so every arrayref idiom keeps working. Deliberately no `map`/`grep`/`sort`/`reduce`.

- **Async::DBD::Pg::Column** (`lib/Async/DBD/Pg/Column.pm`) - One column's values, from `Results::get_column`. The only way to reach a column whose name is repeated.

- **Async::DBD::Pg::Error** (`lib/Async/DBD/Pg/Error.pm`) - Error class hierarchy with stringification overload. Subclasses: `Error::Query` (with SQLSTATE), `Error::Connection`, `Error::PoolExhausted`, `Error::Timeout`.

- **Async::DBD::Pg::Util** (`lib/Async/DBD/Pg/Util.pm`) - Shared helpers: `parse_dsn()`, `convert_placeholders()` (`:name` to `$1`), `safe_dsn()` (password masking), `pending_future()` (a reactor-safe leaf `Future` for queued waiters and mutex slots).

### Key Design Decisions

- **DBD::Pg-backed, not raw libpq**: Reuses the DBI ecosystem rather than binding libpq directly.
- **Future::IO abstraction**: Works with any event loop (UV, IO::Async, etc.) - the test suite uses `Future::IO::Impl::UV`.
- **Socket fd duplication**: Uses `POSIX::dup()` to wrap the Pg socket in an `IO::Socket` without ownership conflicts.
- **Async connect**: `pg_async_connect` arrived in DBD::Pg 3.19.0 and the required version is 3.20.0, so connect is always asynchronous. There is no runtime capability check and no synchronous fallback.
- **Named placeholders**: `:name` syntax is converted to PostgreSQL `$N` positional params. The converter passes over the regions where a colon is text: quoted strings, `E'...'` escapes, dollar-quoted bodies, and comments (which nest). Removing this was weighed and rejected — see the rejected section of the result-access spec.

- **Two placeholder scanners**: the converter's output is re-parsed by DBD::Pg at `prepare`. `pg_placeholder_dollaronly => 1` confines that second scan to `$1`, which is why jsonb's `?`, `?|` and `?&` operators and the `arr[:2]` slice work here. A unit test of the converter cannot see this layer; only an integration test can.

- **Lossless or loud**: no view may silently drop, collapse, or invent data. Refusals are `croak`s. The `single`/`single_value`/`single_list` warnings are the one exception — they report a row-count expectation mismatch, not data loss.

### Test Structure

- `t/unit/` - Pure unit tests, no database needed. Cover DSN parsing, placeholder conversion, error classes, results, pool lifecycle, pub/sub logic, backend policy.
- `t/integration/` - Require a live PostgreSQL instance. Cover connections, transactions, pub/sub.
- `t/pool/` - Pool behavior tests.
- `t/lib/Test/Async/DBD/Pg.pm` - Test helper: `require_postgres()`, `skip_without_postgres()`, `test_dsn()`. DSN comes from `$ENV{TEST_PG_DSN}` with fallback to localhost defaults.

### Dependencies

Runtime: `Future::IO` (>= 0.23), `Future::AsyncAwait` (>= 0.66), `Future` (>= 0.49), `DBD::Pg` (>= 3.20.0), `DBI` (>= 1.643).
Test: `Test2::V0`, `Future::IO::Impl::UV` (>= 0.07).

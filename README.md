# Async::DBD::Pg

Event-loop agnostic async PostgreSQL client for Perl using Future::IO,
implemented on top of DBD::Pg.

## Synopsis

```perl
use Future::AsyncAwait;
use Async::DBD::Pg;

my $pg = Async::DBD::Pg->new(
    dsn             => 'postgresql://user:pass@host/db',
    min_connections => 2,
    max_connections => 10,
);

(async sub {
    my $conn = await $pg->connection;
    my $result = await $conn->query('SELECT * FROM users WHERE id = :id', { id => 1 });
    print $result->first->{name}, "\n";
    $conn->release;
})->()->get;
```

## Features

- **Event-loop agnostic** - Works with any Future::IO implementation (IO::Async, UV, GLib, etc.)
- **DBD::Pg-backed** - Uses DBI + DBD::Pg as the only database substrate
- **Connection pooling** - Automatic pool management with min/max connections
- **Async queries** - Non-blocking query execution using DBD::Pg's async support
- **Async connect when supported** - Non-blocking connect with DBD::Pg >= 3.19.0 using Future::IO's official `poll` API
- **Pub/sub** - `LISTEN`, `UNLISTEN`, and `NOTIFY` over a dedicated listener connection
- **Named placeholders** - `:name` style in addition to `$1` positional
- **Transactions** - With savepoint support for nesting
- **Cursors** - Streaming large result sets

## Requirements

- Perl 5.24+
- Future::IO 0.23
- Future::AsyncAwait 0.66+
- DBD::Pg 3.18+ (3.19.0+ for async connect)

### Why Perl 5.24

The floor is set by a dependency, not by preference, and it is not movable
without giving up correctness.

`Future::AsyncAwait` implements **cancellation propagation only on Perl 5.24
and later**. On an older Perl an `async sub` still stops running when it is
cancelled, but the cancellation is not passed into the future it was waiting
on.

That matters here because a connection pool is largely a story about work
being abandoned: a caller gives up on a query, a listener is told to stop, an
application shuts the pool down while a connection is still being
established. Every one of those paths releases something — a connection slot,
a statement handle, a paused listener — and every one of them relies on the
cancellation actually reaching the operation being awaited. Without that, the
resource is never released and the pool quietly degrades.

Tested rather than assumed: on 5.24 through 5.40 the suite passes, and on
5.20 and 5.22 it fails outright, taking the cursor and transaction tests with
it.

Perl 5.18 is doubly excluded — DBI 1.651 and later require 5.20, so a fresh
install cannot resolve a current DBI at all.

## How It Works

`Async::DBD::Pg` is intentionally built on top of DBI + DBD::Pg rather than
binding libpq directly.

For queries, it uses DBD::Pg's async support and waits for PostgreSQL socket
readiness without blocking the event loop via `Future::IO->poll`.

For connection establishment, fully async connect is enabled when:

- `DBD::Pg >= 3.19.0`

Otherwise connect falls back to ordinary synchronous `DBI->connect`, while
query execution remains asynchronous after the connection is established.

## Examples

See the `examples/` directory for working examples covering:

- basic queries
- placeholders
- transactions
- cursors
- parallel queries
- pub/sub
- job queues
- live dashboards

## Advanced Access

Connection objects expose the underlying DBI handle via `dbh` for advanced
DBD::Pg-specific use. The wrapper API remains the supported primary interface.

## Installation

```bash
cpanm Async::DBD::Pg
```

Or from source:

```bash
dzil build
cpanm Async-DBD-Pg-*.tar.gz
```

## Local Test Database

A `docker-compose.yml` file is included for running PostgreSQL locally for
tests and examples:

```bash
docker compose up -d
TEST_PG_DSN='postgresql://postgres:test@localhost:5432/test' prove -r -l t/
```

Set `PG_PORT` if 5432 is already taken on your machine, and point
`TEST_PG_DSN` at the same port.

## Author

John Napiorkowski <jjn1056@yahoo.com>

## License

Copyright (c) 2026 John Napiorkowski.

This library is free software; you may redistribute it and/or modify it under the terms of the Artistic License 2.0. See the [LICENSE](LICENSE) file for the full text.

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

- Perl 5.18+
- Future::IO 0.23
- Future::AsyncAwait 0.66+
- DBD::Pg 3.18+ (3.19.0+ for async connect)

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

## Author

John Napiorkowski <jjn1056@yahoo.com>

## License

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

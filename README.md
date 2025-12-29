# Future-IO-Pg

Event-loop agnostic async PostgreSQL client for Perl using Future::IO.

## Synopsis

```perl
use Future::IO::Impl::IOAsync;  # or any Future::IO implementation
use Future::IO::Pg;

my $pg = Future::IO::Pg->new(
    dsn             => 'postgresql://user:pass@host/db',
    min_connections => 2,
    max_connections => 10,
);

my $conn = await $pg->connection;
my $result = await $conn->query('SELECT * FROM users WHERE id = $1', $id);
print $result->first->{name};
$conn->release;
```

## Features

- **Event-loop agnostic** - Works with any Future::IO implementation (IO::Async, UV, GLib, etc.)
- **Connection pooling** - Automatic pool management with min/max connections
- **Async queries** - Non-blocking query execution using DBD::Pg's async support
- **Async connect** - Non-blocking connect with DBD::Pg >= 3.19.0 and IOAsync impl
- **Named placeholders** - `:name` style in addition to `$1` positional
- **Transactions** - With savepoint support for nesting
- **Cursors** - Streaming large result sets

## Requirements

- Perl 5.18+
- Future::IO 0.15+
- Future::AsyncAwait 0.66+
- DBD::Pg 3.18+ (3.19.0+ for async connect)

## How It Works

Uses `Future::IO->recv($sock, 1, MSG_PEEK)` to wait for PostgreSQL socket readiness without blocking the event loop. When `ready_for_read`/`ready_for_write` are available in the Future::IO implementation (e.g., IOAsync), those are used instead for better efficiency.

## Installation

```bash
cpanm Future::IO::Pg
```

Or from source:

```bash
dzil build
cpanm Future-IO-Pg-*.tar.gz
```

## Author

John Napiorkowski <jjn1056@yahoo.com>

## License

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

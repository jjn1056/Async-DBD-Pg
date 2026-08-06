# Async::DBD::Pg

Event-loop agnostic async PostgreSQL client for Perl using Future::IO,
implemented on top of DBD::Pg.

## Synopsis

```perl
use Future::AsyncAwait;
use Future::IO;
use Async::DBD::Pg;

BEGIN { Future::IO->load_best_impl }

my $pg = Async::DBD::Pg->new(
    dsn             => 'postgresql://user:pass@host/db',
    min_connections => 2,
    max_connections => 10,
);

(async sub {
    # One row, one value, or a row as a list -- the pool checks a connection
    # out and gives it back for each.
    my $user  = await $pg->query_row('SELECT * FROM users WHERE id = $1', 1);
    my $total = await $pg->query_value('SELECT count(*) FROM users');
    my ($id, $name) = await $pg->query_list('SELECT id, name FROM users LIMIT 1');

    print "$user->{name} of $total\n";

    # Or the whole result
    my $rs = await $pg->query('SELECT id, name FROM users WHERE active');
    print $_->{name}, "\n" for @{ $rs->rows };
})->()->get;
```

Several statements that must share a connection go through `with_connection`
or `transaction`, which hold the checkout across every `await` and give it
back however the block ends:

```perl
await $pg->transaction(async sub {
    my ($conn) = @_;
    await $conn->query('INSERT INTO orders (user_id) VALUES ($1)', $id);
    await $conn->query('UPDATE users SET orders = orders + 1 WHERE id = $1', $id);
});
```

## Features

- **Event-loop agnostic** - Works with any Future::IO implementation (IO::Async, UV, GLib, etc.)
- **DBD::Pg-backed** - Uses DBI + DBD::Pg as the only database substrate
- **Connection pooling** - Automatic pool management with min/max connections
- **Async queries** - Non-blocking query execution using DBD::Pg's async support
- **Async connect** - Non-blocking connect using `pg_async_connect` and Future::IO's official `poll` API
- **Pub/sub** - `LISTEN`, `UNLISTEN`, and `NOTIFY` over a dedicated listener connection
- **Named placeholders** - `:name` style in addition to `$1` positional, leaving `?` free for PostgreSQL's own operators
- **Typed binds** - a value may state its PostgreSQL type, by constant or by name. Required for `bytea`: sent as text, a value is truncated at its first NUL and the write reports success
- **Transactions** - with savepoint support for nesting, optional retry on serialization failures and deadlocks, and transaction-scoped advisory locks
- **Cursors** - Streaming large result sets, one row at a time
- **Results that don't lose data** - a repeated column name is an error, not a silent collapse
- **Errors that carry the server's diagnostics** - constraint, table, column, detail, plus predicates like `is_unique_violation` and `is_retryable` that answer on every error class
- **Query observability** - one `on_query` hook reporting SQL, binds, duration, row count, error, cache hit, and which connection ran it
- **Optional statement caching** - off by default; keeps server-side prepared statements alive for repeated parameterized queries

## Results

Rows are stored positionally and hashes are derived on demand, which is what
lets a result carry a column name twice:

```perl
my $rs = await $pg->query('SELECT * FROM a JOIN b ON a.id = b.id');
$rs->columns;  # ['id', 'name', 'id', 'name']

$rs->rows;     # croaks: Column 'id' appears 2 times at positions 0, 2
$rs->arrays;   # works: every value, positionally
$rs->as(['a_id', 'a_name', 'b_id', 'b_name'])->rows;   # works: renamed
```

A hash cannot hold both values, so asking for one is refused rather than
answered wrongly. Everything positional keeps working on that same result,
and so does `multi`, which is lossless.

The rest of the surface:

```perl
$rs->columns  $rs->types  $rs->count  $rs->elapsed
$rs->first  $rs->single  $rs->first_value  $rs->first_list
$rs->get_column('name')->all
$rs->by('id')  $rs->groups('dept')  $rs->expand
say $rs->preview;   # column names, types, row count, first few rows
```

Hydrating objects goes through `map_rows`, which hands the callback each row
positionally so N objects are built without N throwaway hashrefs:

```perl
my $users = $rs->map_rows(sub {
    my ($row, $names) = @_;
    My::User->new(id => $row->[0], name => $row->[1]);
});
```

## Requirements

- Perl 5.24+
- Future::IO 0.23
- Future::AsyncAwait 0.66+
- Future 0.49+
- DBD::Pg 3.20.0+
- DBI 1.643+

Two more are optional, each loaded only by the one method that needs it, so
an installer who never calls them never needs them:

- `Hash::MultiValue` 0.15+ - for `multi`
- `JSON::MaybeXS` 1.004+ - for `expand`

A missing one is reported with an install hint by the method that wanted it.

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

Connection establishment is asynchronous too, using `pg_async_connect` and
`pg_continue_connect`. Those arrived in DBD::Pg 3.19.0, which is part of why
the required version is 3.20.0.

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

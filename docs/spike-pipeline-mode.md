# Spike: PostgreSQL Pipeline Mode Support

## What Is Pipeline Mode?

Pipeline mode (PostgreSQL 14+, libpq) allows sending multiple queries to the server
without waiting for each result before sending the next. Instead of N round-trips for
N queries, you get 1 round-trip for the entire batch.

**Normal mode:** send query₁ → wait → send query₂ → wait → send query₃ → wait
**Pipeline mode:** send query₁, query₂, query₃, sync → read result₁, result₂, result₃

The server still processes queries sequentially — this is a network optimization, not
parallel execution. But for workloads with many small independent queries, the latency
improvement is dramatic.

## Key Constraints

- **COPY is disallowed in pipeline mode.** These are complementary features.
- **Each connection handles one pipeline at a time.** Same pool model as everything else.
- **Deadlock risk in blocking mode.** libpq docs explicitly warn that non-blocking mode
  should be used with pipeline mode. Our async architecture is ideal for this.
- **Only extended query protocol.** No simple query protocol (`PQsendQuery`), no
  multi-statement strings, no synchronous functions.
- **The caller must track query order.** libpq returns results in send order but provides
  no correlation mechanism. The application maintains a FIFO queue.

## Error Semantics

When a query fails mid-pipeline:
1. The failed query returns `PGRES_FATAL_ERROR`
2. All subsequent queries until the next sync point return `PGRES_PIPELINE_ABORTED` (skipped)
3. The server rolls back any implicit transaction for the current sync group
4. At the sync point, `PGRES_PIPELINE_SYNC` is returned
5. Processing resumes normally after the sync point

This means sync points (`PQpipelineSync`) serve as error recovery boundaries. Queries
before the failure that already committed are safe. The failing query and everything after
it (until sync) are rolled back/skipped.

## Transaction Interaction

- **No explicit transaction:** Each sync point is an implicit transaction boundary. All
  queries between syncs succeed or fail atomically.
- **Explicit BEGIN/COMMIT in pipeline:** Works. Committed transactions before the error
  point remain committed. The in-progress transaction is aborted.
- **Multiple explicit transactions:** All committed transactions before the error remain.
  The in-progress one aborts. Subsequent transactions are skipped entirely.

## libpq API Surface

```c
// Mode management
PQenterPipelineMode(conn);     // Enter pipeline mode (connection must be idle)
PQexitPipelineMode(conn);      // Exit (must have no pending results)
PQpipelineStatus(conn);        // PQ_PIPELINE_ON, OFF, or ABORTED

// Query dispatch (same async send functions)
PQsendQueryParams(conn, ...);  // Queue a parameterized query
PQsendQueryPrepared(conn, ...);// Queue a prepared statement execution
PQsendPrepare(conn, ...);      // Queue a PREPARE

// Synchronization
PQpipelineSync(conn);          // Mark sync point + auto-flush
PQsendPipelineSync(conn);      // Mark sync point, manual flush (libpq 17+)
PQsendFlushRequest(conn);      // Ask server to send results so far (no sync)

// Result processing (same as normal)
PQconsumeInput(conn);
PQisBusy(conn);
PQgetResult(conn);             // Returns NULL between queries, then next result

// Pipeline-specific result statuses
PGRES_PIPELINE_SYNC            // Sync point reached
PGRES_PIPELINE_ABORTED         // Query skipped due to earlier error
```

## How Other Libraries Expose Pipeline Mode

### pgx (Go) — Batch API

The cleanest, most user-friendly approach:

```go
batch := &pgx.Batch{}
batch.Queue("INSERT INTO t VALUES ($1)", 1)
batch.Queue("INSERT INTO t VALUES ($1)", 2)
batch.Queue("SELECT count(*) FROM t")
results := conn.SendBatch(ctx, batch)
tag, err := results.Exec()     // result of INSERT 1
tag, err = results.Exec()      // result of INSERT 2
rows, err := results.Query()   // result of SELECT
results.Close()
```

Queue queries into a Batch object, send all at once, read results back in order.
Implicit transaction wraps the batch. Connection is locked until `Close()`.

### EV::Pg (Perl) — Explicit enter/exit

Matches libpq closely:

```perl
$pg->enter_pipeline;
$pg->query("INSERT INTO t VALUES ($1)", [1], sub { my ($res) = @_; });
$pg->query("INSERT INTO t VALUES ($1)", [2], sub { my ($res) = @_; });
$pg->pipeline_sync(sub { my ($ok) = @_; ... });
$pg->exit_pipeline;
```

Each query gets its own callback. `pipeline_sync` fires when all preceding queries
complete. 124K queries/sec pipelined vs 73K sequential in benchmarks (70% improvement).

### Npgsql (.NET) — NpgsqlBatch

```csharp
var batch = new NpgsqlBatch(conn) {
    BatchCommands = { new("SELECT ..."), new("SELECT ...") }
};
var reader = await batch.ExecuteReaderAsync();
// reader.NextResultAsync() to advance between result sets
```

Batch object with sequential result reading. Similar to pgx but .NET-idiomatic.

### Libraries WITHOUT pipeline support

- **tokio-postgres (Rust):** Only `batch_execute()` for simple multi-statement strings.
  No proper pipeline mode.
- **asyncpg (Python):** Uses implicit pipelining internally for prepared statements but
  does not expose pipeline mode to users.
- **node-postgres (Node.js):** No pipeline support.
- **ruby-pg (Ruby):** Added pipeline support in ruby-pg 1.5+ (mirrors libpq API).

## What It Would Look Like in Async::DBD::Pg

Following pgx's pattern (most user-friendly):

```perl
my @results = await $conn->batch(sub {
    my $batch = shift;
    $batch->query("INSERT INTO t VALUES (:id)", { id => 1 });
    $batch->query("INSERT INTO t VALUES (:id)", { id => 2 });
    $batch->query("SELECT count(*) FROM t");
});
# @results = ($insert_result, $insert_result, $select_result)
```

Or pool-level convenience:

```perl
my @results = await $pool->batch(sub {
    my $batch = shift;
    $batch->query("INSERT INTO users VALUES (:name)", { name => 'Alice' });
    $batch->query("INSERT INTO users VALUES (:name)", { name => 'Bob' });
    $batch->query("INSERT INTO logs VALUES (:msg)", { msg => 'created users' });
});
```

## Path to Implementation

### Phase 1: DBD::Pg Patch (prerequisite)

DBD::Pg does not expose any pipeline mode functions. We would need to add:

| libpq function | Proposed DBD::Pg method | Complexity |
|---|---|---|
| `PQenterPipelineMode` | `pg_enter_pipeline` | Low — mode flag |
| `PQexitPipelineMode` | `pg_exit_pipeline` | Low — mode flag |
| `PQpipelineStatus` | `pg_pipeline_status` | Low — read-only |
| `PQpipelineSync` | `pg_pipeline_sync` | Medium — new result types |
| `PQsendPipelineSync` | `pg_send_pipeline_sync` | Medium |
| `PQsendFlushRequest` | `pg_send_flush_request` | Low — already similar to pg_flush |

The harder parts:
- **Result routing:** In pipeline mode, `PQgetResult` returns NULL between queries as a
  separator, then the next query's results. DBD::Pg's current `pg_result` doesn't handle
  this — it drains all results for a single query. Need a way to read results one-at-a-time.
- **New result statuses:** `PGRES_PIPELINE_SYNC` and `PGRES_PIPELINE_ABORTED` need to be
  surfaced to Perl. Currently DBD::Pg doesn't expose these.
- **Interaction with `pg_async`:** Pipeline mode uses the same `PQsendQueryParams` that
  DBD::Pg's async mode uses. Need to ensure they don't conflict.

Estimated scope: Larger than the COPY patch. The COPY patch was ~200 lines because the
stubs already existed. Pipeline mode would require new state management in `imp_dbh_t`,
new result handling logic, and new XS bindings. Rough estimate: 400-600 lines of C/XS.

### Phase 2: Async::DBD::Pg Wrapper

Once DBD::Pg exposes the primitives, the Async::DBD::Pg layer would:
1. Check out a connection from the pool
2. Call `pg_enter_pipeline`
3. Send all queries via the existing async query path
4. Call `pg_pipeline_sync`
5. Poll for results using Future::IO
6. Collect results in order, map back to callers
7. Call `pg_exit_pipeline`
8. Return connection to pool

Error handling: if any query fails, collect `PGRES_PIPELINE_ABORTED` for the rest,
report which query failed, and still cleanly exit pipeline mode.

### Phase 3: Pool-level API

Expose `$pool->batch(sub { ... })` that handles checkout/pipeline/sync/return
automatically. This is the user-facing feature.

## Performance Expectations

Based on EV::Pg benchmarks and PostgreSQL documentation:
- **High-latency connections (cloud, cross-region):** 10-100x improvement for batch inserts
- **Local connections:** 40-70% improvement (EV::Pg saw 73K → 124K queries/sec)
- **Single large queries:** No improvement (already one round-trip)
- **Dependent queries (each needs previous result):** No improvement (can't pipeline)

## Recommendation

Pipeline mode is a strong v2 feature for Async::DBD::Pg. The use case is real, the
performance gain is significant, and our async architecture avoids the deadlock risk that
makes pipeline mode dangerous in blocking mode.

It requires a larger DBD::Pg patch than COPY (~400-600 lines vs ~200 lines), with more
complex result handling semantics. The COPY patch establishes our relationship with the
DBD::Pg maintainer; pipeline mode would be a natural follow-up.

**Priority:** After the v1 release. Not a blocker for CPAN readiness — pipeline mode is
a performance optimization, not a correctness feature. Most production workloads will
benefit more from the pool (connection-level parallelism) than from pipeline mode
(query-level batching on a single connection).

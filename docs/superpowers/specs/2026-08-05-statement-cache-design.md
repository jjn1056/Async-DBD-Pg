# Per-connection statement cache

**Goal:** stop re-preparing the same statement on every query, without letting
a cached handle outlive the state that makes it valid.

## Why a cache buys anything

`_execute_async` calls `$dbh->prepare` for every query and drops the handle
when the result is built. DBD::Pg promotes a statement handle to a named
server-side prepared statement only on repeated use, so a handle that is
thrown away after one execute never reaches that state.

Measured, DBD::Pg 3.20.2 against PostgreSQL 16:

    pg_switch_prepared   after 1 execute      after 2
    2 (the default)      (empty)              dbdpg_p5153_1
    1                    dbdpg_p5153_2        same
    0                    (empty)              (empty)

So the cache's job is not "skip a parse". It is **to keep a handle alive long
enough for DBD::Pg's own promotion to happen**. Under the default that means
the payoff starts at the third execution of a statement.

`pg_switch_prepared` is a **database handle** attribute, not a prepare
attribute: setting it in the attribute hash passed to `prepare` has no effect,
and it applies connection-wide to cached and uncached statements alike.

The table above also shows this promotion never happens at all for a statement
without placeholders, at any setting -- see "Only statements with a server-side
prepared statement may be cached" below, which is what settles both the value
of caching such a statement and the safety of it.

Measured cost of not caching, 500 repeated queries on loopback:

    fresh prepare each time    0.227s
    prepare_cached each time   0.163s
    one handle, reused         0.165s

## Storage

A per-connection LRU keyed on the **converted** SQL -- the statement after
`convert_placeholders` has run -- so the `:name` and `$1` spellings of one
query share an entry and the cache cannot fragment across bind styles.

`statement_cache_size` sets the bound; 0 disables the cache entirely, and
with it disabled the query path must behave exactly as it does today.

Eviction drops the handle reference. DBD::Pg deallocates the server-side
statement when the handle is destroyed, which is what keeps
`pg_prepared_statements` from growing without bound -- and is why the cache
size is a server-memory knob, not only a client-side one.

## Why the Connection owns it

The cache has to see the statement guard's lifecycle, and only the Connection
does. Per guard exit:

- **`hand_over`** -- `Results` finished the handle -- reusable, **keep**.
- **`release` on an error path** -- handle state unknown -- **evict**.
- **guard destroyed with neither** -- the caller cancelled mid-await, or the
  timeout race fired `cancel`/`PQcancel` -- statement aborted in flight --
  **evict**.

Three things follow from Connection ownership at no cost: the cache dies with
the connection when one is healed or replaced, so no dead handles leak; the
recovery decision sits inside `_execute_async`'s error handling, where the
SQLSTATE already is; and the key can be the SQL alone, because a private
cache may assume the house invariant that every `prepare` here passes the
same attributes.

**DBI's `prepare_cached` is rejected**, on two measured grounds. It is unusable
under `pg_async` at all: the second use of a cached handle fails with
`DBD::Pg::st fetchall_arrayref failed: no statement executing`. And its
if-active handling defaults to warn-and-finish, which would paper over exactly
the poisoned-handle states the eviction contract above exists to catch.

## Recovery

Two SQLSTATEs evict, re-prepare and retry, **once, never in a loop**:

- **0A000** -- `cached plan must not change result type`, a schema change under
  a cached plan.
- **26000** -- `prepared statement does not exist`.

**Both states fail at parse or bind time, before the statement executes, so
evict-reprepare-retry cannot double-execute anything.** That is the whole
reason recovery is automatic rather than surfaced to the caller; without it,
retrying a statement that might already have run would be unsafe.

Anything else propagates untouched.

### Only statements with a server-side prepared statement may be cached

0A000 is not merely one recoverable state among several. It is the only thing
standing between a reused handle and a **segfault**.

Re-executing a DBD::Pg statement handle after its result shape has changed
crashes the process. The handle keeps the field count from its first execute
and the fetch walks off it. Measured against DBD::Pg 3.20.2 with plain
synchronous DBI and none of this library involved, in both directions of the
change (`ADD COLUMN` and `DROP COLUMN`), and whether or not `NAME` is read
first. It is not catchable: there is no error, no warning, and no exception --
the process dies during the fetch.

What normally prevents it is PostgreSQL rather than the driver. A **named**
server-side prepared statement has a cached plan, so the server rejects the
execute with 0A000 and nothing is ever fetched. The crash needs a handle with
no such plan.

DBD::Pg promotes **only statements that carry placeholders**. `SELECT * FROM t`
never gets a named prepared statement however often it runs, so it has no
cached plan, gets no 0A000, and is exactly the case that crashes.

Two consequences, both load-bearing:

- **Cache a handle only when it carries placeholders.** Verified with
  `NUM_OF_PARAMS`, which is readable straight after `prepare`. This costs
  almost nothing: with no server-side statement to keep alive, caching an
  unparameterized statement bought DBI's local re-parse and no round trip.
- **Set `pg_switch_prepared` to 1** on any connection whose cache is enabled.
  At the default of 2, promotion happens on a handle's *second* execute -- but
  an uncached handle is dropped before then, so every execute is a first one
  and nothing is ever promoted. Without this the cache never holds anything.
  It also closes the window in which a cached placeholder-carrying handle
  exists without its plan: measured, one execute at the default and then a
  shape change still crashes.

Reuse re-checks that `pg_prepare_name` is still set, and evicts if it is not.
Nothing observed puts a handle in that state; it is checked rather than
assumed because the cost of the invariant failing is a crash, not a wrong
answer.

### The 26000 rationale is transaction pooling, not rollback

An earlier theory held that a statement prepared inside a transaction is lost
when that transaction rolls back, because protocol-level Parse is
transactional. **That was tested and is false on PostgreSQL 16.** Both the
SQL-level `PREPARE` path and the protocol-level `PQprepare` path survive a
rollback, control-validated in every run by creating a table in the same
transaction and confirming it was gone afterwards:

    SQL-level PREPARE, AutoCommit=1 + manual BEGIN/ROLLBACK
      CONTROL table existed in txn=1, after rollback=0   <-- transaction real
      EXECUTE after rollback: SURVIVED

    protocol-level, prepared inside txn as dbdpg_p3100_1
      CONTROL table after rollback: 0                    <-- transaction real
      reuse after rollback: SURVIVED

The real source is a pooler in **transaction-pooling mode**. With pgbouncer in
that mode, consecutive transactions can land on different backends, so a
statement prepared on one is simply absent on the next -- which is exactly
26000.

### The vacuous-pass trap in the 26000 test

Because promotion happens on the second execute, the obvious test passes
without exercising anything. Measured:

    one execute   -- name (empty)         -- DEALLOCATE ALL, reuse: SURVIVED
    two executes  -- name dbdpg_p4866_2   -- DEALLOCATE ALL, reuse: state=26000

A test that executes once, deallocates and reuses proves nothing: it never
touched the named-statement path. The test must execute at least twice **and
assert `pg_prepare_name` is non-empty first**, so the setup cannot rot
silently if DBD::Pg's default changes.

This is the same illusory-coverage class as the old `arr[:2]` unit test, which
asserted the converter's output and could not see the failure one layer down.

## Observability

`on_query` gains `cached => 1` on a hit. The assertion "this path ran two
queries" becomes "and the second was a hit" at no cost.

## Measurement

A repeated execute on a cached handle sends Bind/Execute of the named
statement: the same number of round trips as an uncached one, with less server
work. **The cache saves parse and plan CPU and protocol bytes, not a round
trip.** The two runs therefore answer different questions:

- **Loopback isolates the mechanism.** With RTT near zero, this is where the
  per-execution microsecond saving is measurable at all.
- **Injected latency is the honesty measurement.** It shows the end-to-end win
  shrinking as network time dominates, which is the number that belongs in the
  POD so the feature is not oversold.

The POD claim takes the shape: *saves ~X us per repeated execution; ~Y%
end-to-end at loopback, ~Z% at 1 ms RTT.*

**Measured, PostgreSQL 16, 300 statements per run, best of 3, cache hits
counted in every cell so that a run where nothing was cached cannot be read as
a result:**

    workload  latency   cache          off        on   speedup  saved/query  hits
    trivial   loopback  size 10     0.149s    0.146s      2.0%      10.2 us  300/300
    trivial   2.0ms     size 10     1.591s    1.636s     -2.9%    -152.1 us  300/300
    trivial   loopback  size 1      0.165s    0.381s   -130.9%    -720.7 us    1/300
    joins     loopback  size 10     0.626s    0.487s     22.2%     463.4 us  300/300
    joins     2.0ms     size 10     2.097s    1.978s      5.7%     396.7 us  300/300
    joins     loopback  size 1      0.579s    0.789s    -36.3%    -700.4 us    1/300

What this says, and it is not what the projection above assumed: **the cache
buys planning, not round trips.** A statement the planner disposes of instantly
gains nothing at any latency. A three-table join with an `ORDER BY` saves about
400 microseconds per execution, and that absolute saving barely moves as
latency grows -- the percentage falls only because the round trips grow around
it. That is the signature of amortized planning and is what makes the number
credible.

The adversarial cell is the one that changes the advice. Two statements in a
cache of one thrash: every query evicts, re-prepares, and pays a round trip
that not caching would never have paid. That is 36% slower than off on the
join workload and 131% slower on the trivial one. **An undersized cache is
substantially worse than no cache**, so the documentation tells the reader to
leave it off rather than guess low, and `on_query` reports `cached` so a poor
hit rate is observable rather than inferred.

`pg_switch_prepared` is no longer a free axis of this matrix: the cache
requires it at 1 to function at all, so it is set with the cache rather than
crossed against it.

Latency is injected by `t/lib/Test/Async/DBD/Pg/DelayProxy.pm`, a TCP proxy
built on `Future::IO` that accepts locally, connects through to PostgreSQL and
sleeps before relaying each chunk. `tc`/`netem` is not used: unavailable in the
CI sandbox and awkward on macOS. The proxy is unprivileged and deterministic,
it makes the whole suite latency-parameterizable by pointing `TEST_PG_DSN` at
it, and it exercises this library's own async stack.

Matrix, every cell reported:

- workload: a small `SELECT` with binds, repeated well past the promotion
  threshold -- otherwise the benchmark measures `PQexecParams` against itself
- latency: 0 (direct loopback), 0.5 ms, 2 ms injected
- cache: off / on, crossed with `pg_switch_prepared` 2 and 1
- adversarial: cache size 1 with two alternating statements, which is pure
  eviction churn, and a cold-cache run showing first-execution cost unchanged

## Documentation

- **Deployment note.** Behind a transaction-pooling pgbouncer every transaction
  can land on a fresh backend, the cache degenerates into constant 26000
  recovery, and it is slower than no cache. Use `statement_cache_size => 0`
  there, unless pgbouncer is 1.21 or newer with `max_prepared_statements` set,
  which tracks protocol-level named statements across backends.
- The measured claim, in the shape above.
- One sentence on recovery: which two states, and why the retry cannot
  double-execute.

## Testing

Each shown failing first.

1. Cache hit: the same SQL twice on one connection reuses the handle, with
   `pg_prepare_name` identical; `on_query` reports `cached => 1` on the second.
2. The key is the converted SQL: the `:name` and `$1` spellings of one query
   share an entry.
3. LRU: size N, N+1 distinct statements, the oldest evicted and its server
   statement deallocated.
4. Guard exits: an error path evicts; a cancelled or timed-out query evicts; a
   completed query's handle stays cached and is reusable after `Results`
   finished it.
5. 26000 recovery: execute twice, **assert `pg_prepare_name` is non-empty**,
   `DEALLOCATE ALL` out of band, reuse. Recovers transparently, exactly one
   re-prepare, correct result.
6. 0A000 recovery: cache a `SELECT *` **carrying a placeholder**, assert it has
   a named prepared statement, `ALTER TABLE` to change the result type, reuse.
   Recovers transparently and reports the new shape. The placeholder is not
   incidental -- without one the statement is not cached, and the subtest would
   pass while exercising nothing.
6a. A statement without placeholders is never cached, so the same shape change
   cannot reach a reused handle. Asserted directly on the cache, because the
   behaviour it buys is the absence of a crash and there is nothing else to
   observe.
7. Retry-once bound: a statement that fails 26000 again after re-preparing
   surfaces the error rather than looping.
8. Eviction inside an aborted transaction neither dies nor poisons the
   connection. Measured today as clean -- 0 warnings, connection still usable
   afterwards -- so this is a regression guard rather than a fix.
9. `statement_cache_size => 0` disables caching; behaviour is identical to
   today's.
10. DelayProxy: the suite passes unchanged through it at 0 ms, and a query
    through a 50 ms proxy takes at least 100 ms, proving it injects what it
    claims.

Mutations: remove the guard-exit eviction, test 4 must red. Remove the retry,
tests 5 and 6 must red. Remove the execute-twice setup from test 5, its
`pg_prepare_name` assertion must red -- which is what proves the trap is
guarded rather than merely described.

## Out of scope

No cross-connection sharing, since server statements belong to one backend. No
cache warming. No decision by statement type -- the LRU handles a one-off DDL
without help. No pipeline mode.

The warn-once heuristic for "26000 recoveries exceed some fraction of hits,
this looks like transaction pooling" ships only if it earns its place; it is a
guess about a deployment from inside a library, and a wrong guess is noise in
someone's log.

## Risk

Every query in the distribution goes through `_execute_async`, so this touches
the hot path of everything. The eviction contract is the dangerous part: a
handle kept when it should have been evicted is a poisoned statement reused
silently, which is the failure class this distribution has spent its whole
history removing. That is why the guard exits are enumerated above rather than
inferred, and why their mutation is the one that must red.

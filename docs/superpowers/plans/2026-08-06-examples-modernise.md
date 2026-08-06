# Examples Modernisation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make the eight examples teach the library as it is now, and keep a test that says so.

**Architecture:** The examples all run and do what they claim -- that half is already true and must stay true. What has drifted is the idiom: every one checks a connection out by hand and releases it last, half never use `async`/`await` at all, six never shut the pool down, and none uses the ergonomic accessors or anything added in the last several branches. The work is to modernise the idiom without changing what each example demonstrates, and to add a guard so they cannot silently rot again.

**Tech Stack:** Perl 5.42 via perlbrew, PostgreSQL 16, Future::AsyncAwait, Test2::V0.

## Global Constraints

- Never run Perl tooling under system perl. Prefix: `source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default`
- Examples read `$ENV{DATABASE_URL}`, defaulting to port 5432. **Run them with `DATABASE_URL="postgresql://postgres:test@localhost:5433/test"`.** Do not change the in-file default -- 5432 is correct for the repository's documented setup.
- Baseline: **321 tests, 23 files, pristine**, via `prove -r -l t/` with `TEST_PG_DSN` on 5433.
- Test output MUST be pristine. POD must be ASCII, enforced by `t/unit/docs.t`.
- `llms.txt` has a 3000-token budget enforced by `docs.t`.
- **Every example must still produce the same observable output it does today** (allowing for values that legitimately vary: timings, pids, random metrics). The output each currently produces is recorded below -- diff against it.

## Research findings this plan rests on

Measured. Do not re-derive; do flag anything the code contradicts.

- **All eight examples run and do what they claim today.** Verified against a live database: version query, placeholders including a SQL-injection demonstration, transactions with rollback and savepoint nesting, 250 rows streamed 50 at a time, a genuine 3.4x parallel speedup, a LISTEN/NOTIFY round trip, a 3-worker job queue that correctly fails job 6, and a live dashboard. **Nothing here is broken; this is not a bug-fix plan.**

- **Every example uses the manual `$pg->connection` / `$conn->release` pattern.** None uses `with_connection`. That is the pattern removed from the SYNOPSIS this week because a throwing query skips the release and the pool slot is lost for the life of the pool.

- **Four of eight never use `async`/`await`:** `01-basic-query`, `02-placeholders`, `04-cursors`, `06-pubsub` are pure blocking `->get`. `04-cursors` makes twelve blocking calls to demonstrate a streaming API.

- **Six of eight never call `shutdown`** -- only `07-job-queue` and `08-live-dashboard` do.

- **None uses `query_row`, `query_value` or `query_list`.** `01` does `$conn->query('SELECT version() AS version')->get` then `->first->{version}`, which is `query_value`.

- **None uses anything added recently**: no `retry`, advisory locks, violation predicates, `map_rows`, `on_query`, or typed binds. Zero hits across all eight.

- **`llms.txt` documents the LISTEN callback arguments in the wrong order.** The implementation calls `$cb->($channel, $payload, $pid)` (`PubSub.pm:313`), the POD says so correctly (`PubSub.pm:975`), and `06-pubsub` uses it correctly. `llms.txt:194` says `sub { my ($payload, $channel) = @_ }`. Running the documented spelling verbatim yields `payload='order_check'` and `channel='THE-PAYLOAD'` -- each variable holds the other's value, silently. `docs.t` cannot catch this: it verifies method names exist, not signatures.

- **Two things are already right and must not be "improved":** `07-job-queue` claims work with `FOR UPDATE SKIP LOCKED`, which is the correct primitive -- advisory locks would be a downgrade. And `05-parallel-queries` measures and prints a real speedup, which is exactly the property that was silently broken in the documentation last week.

### Current output, for diffing after each change

    01 PostgreSQL version + "n = 1".."n = 5"
    02 10 + 20 = 30 / Full name = John Doe / '; DROP TABLE users; --
    03 Alice $1000.00, Bob $500.00 / Caught: Oops, rollback / Alice $900, Bob $500, Charlie $100
    04 Streamed 250 rows, ids 1 - 250, 50 at a time / fetched 16 rows
    05 Sequential ~0.56s, Parallel ~0.16s, speedup ~3.4x, created 5 / idle 5 / active 0
    06 Sending notification... / Received on demo_channel from pid N: hello from Async::DBD::Pg
    07 Schema created / 3 workers / jobs 1-5 finish, job 6 FAILED (broken)
    08 dashboard frames with cpu_usage / latency_ms / memory_pct / requests_sec bars

## File Structure

| File | Change |
|---|---|
| `llms.txt` | Correct the LISTEN callback argument order (Task 1) |
| `examples/01-basic-query/app.pl` | async/await, pool accessors, shutdown (Task 2) |
| `examples/02-placeholders/app.pl` | async/await, `query_value`, shutdown (Task 2) |
| `examples/04-cursors/app.pl` | async/await, `with_connection`, shutdown (Task 3) |
| `examples/06-pubsub/app.pl` | async/await, shutdown (Task 3) |
| `examples/03-transactions/app.pl` | drop manual checkout, shutdown (Task 4) |
| `examples/05-parallel-queries/app.pl` | drop manual checkout, shutdown; keep the timing (Task 4) |
| `examples/07-job-queue/app.pl` | `with_connection`, violation predicates on the failure path (Task 5) |
| `examples/08-live-dashboard/app.pl` | `with_connection`, `on_query` (Task 5) |
| `examples/*/README.md` | Update any code shown that changed (Task 6) |
| `t/unit/examples.t` | **new** -- every example compiles and follows the idiom (Task 6) |

---

### Task 1: Correct the LISTEN callback order in the machine reference

Independent of everything else, and the only actual bug in this plan. Do it first.

**Files:** `llms.txt`

- [ ] **Step 1: See the defect for yourself**

Write a scratch script using the spelling `llms.txt` documents, run it against the database on 5433, and confirm the two variables hold each other's values:

```perl
$pg->listen('order_check', sub { my ($payload, $channel) = @_;
    print "payload='$payload' channel='$channel'\n" })->get;
$pg->notify('order_check', 'THE-PAYLOAD')->get;
```

Expected: `payload='order_check' channel='THE-PAYLOAD'`. Paste the output into your report.

- [ ] **Step 2: Fix it**

In `llms.txt`, change:

```
    await $pg->listen('channel', sub { my ($payload, $channel) = @_ });
```

to:

```
    await $pg->listen('channel', sub { my ($channel, $payload, $pid) = @_ });
```

That matches `PubSub.pm:313`, the POD at `PubSub.pm:975`, and `examples/06-pubsub`.

- [ ] **Step 3: Verify and commit**

Re-run the scratch script with the corrected spelling and confirm the values land in the right variables. Run `prove -l t/unit/docs.t` (the token budget and compile checks must still pass). Commit.

---

### Task 2: Bring 01 and 02 into the async idiom

Both are short, both are pure blocking `->get`, and `01` is the first example anyone opens.

**Files:** `examples/01-basic-query/app.pl`, `examples/02-placeholders/app.pl`

- [ ] **Step 1: Rewrite 01**

Replace the whole file with:

```perl
#!/usr/bin/env perl
use strict;
use warnings;

use Future::AsyncAwait;
use Future::IO;
use Async::DBD::Pg;

BEGIN { Future::IO->load_best_impl; }

my $dsn = $ENV{DATABASE_URL} // 'postgresql://postgres:test@localhost:5432/test';

my $pg = Async::DBD::Pg->new(
    dsn             => $dsn,
    min_connections => 1,
    max_connections => 5,
);

(async sub {
    # Asking the pool runs one statement on any free connection and gives it
    # straight back, so nothing can be left checked out.
    my $version = await $pg->query_value('SELECT version()');
    print "PostgreSQL version:\n  $version\n\n";

    my $series = await $pg->query('SELECT generate_series(1, 5) AS n');
    print "Generated series:\n";
    print "  n = $_->{n}\n" for @{ $series->rows };
})->()->get;

await $pg->shutdown(timeout => 5);
```

Note `query_value` replaces query-then-`->first->{version}`, and the pool is asked directly rather than a connection being checked out.

- [ ] **Step 2: Run it and diff the output**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
DATABASE_URL="postgresql://postgres:test@localhost:5433/test" perl -Ilib examples/01-basic-query/app.pl
```

Expected: the PostgreSQL version line, then `n = 1` through `n = 5`. Same as before.

- [ ] **Step 3: Rewrite 02 the same way**

Keep all three demonstrations -- positional placeholders, named placeholders, and the SQL-injection-safety one, which is the point of the example. Use `query_value` for each, since each selects exactly one value:

```perl
(async sub {
    print "Positional placeholders:\n";
    my $sum = await $pg->query_value('SELECT $1::int + $2::int', 10, 20);
    print "  10 + 20 = $sum\n";

    print "\nNamed placeholders:\n";
    my $full = await $pg->query_value(
        q{SELECT :first_name || ' ' || :last_name},
        { first_name => 'John', last_name => 'Doe' },
    );
    print "  Full name = $full\n";

    # The value is data, never SQL. Nothing here is escaped by hand.
    my $malicious = q{'; DROP TABLE users; --};
    my $safe = await $pg->query_value('SELECT $1::text', $malicious);
    print "\nSafely escaped:\n  $safe\n";
})->()->get;

await $pg->shutdown(timeout => 5);
```

- [ ] **Step 4: Run it and diff the output**

Expected, unchanged: `10 + 20 = 30`, `Full name = John Doe`, `'; DROP TABLE users; --`.

- [ ] **Step 5: Commit**

---

### Task 3: Bring 04 and 06 into the async idiom

`04-cursors` is the starkest case -- twelve blocking calls demonstrating a streaming API.

**Files:** `examples/04-cursors/app.pl`, `examples/06-pubsub/app.pl`

- [ ] **Step 1: Rewrite 04's body**

Keep both demonstrations: the 250-row stream at `batch_size => 50`, and the parameterised cursor over ids 10..25 at `batch_size => 5`. A cursor is bound to one connection, so this is a genuine `with_connection` case -- say so in a comment.

```perl
(async sub {
    await $pg->with_connection(async sub {
        my ($conn) = @_;

        # A cursor lives on the connection that opened it, so every statement
        # here has to run on that same connection -- which is what this block
        # guarantees, including if something below dies.
        await $conn->query('SET client_min_messages TO warning');
        await $conn->query('DROP TABLE IF EXISTS large_data');
        await $conn->query(q{
            CREATE TABLE large_data (id SERIAL PRIMARY KEY, value TEXT)
        });
        await $conn->query(q{
            INSERT INTO large_data (value)
            SELECT 'row_' || generate_series(1, 250)
        });

        my $cursor = await $conn->cursor(
            'SELECT * FROM large_data ORDER BY id', { batch_size => 50 });

        # next yields one row at a time. batch_size is how many rows come back
        # per round trip, which this loop never has to think about.
        my ($seen, $first, $last) = (0, undef, undef);
        while (my $row = await $cursor->next) {
            $seen++;
            $first //= $row->{id};
            $last = $row->{id};
        }
        await $cursor->close;
        print "Streamed $seen rows, ids $first - $last, 50 at a time\n";

        print "\nCursor with parameters:\n";
        my $ranged = await $conn->cursor(
            'SELECT * FROM large_data WHERE id BETWEEN $1 AND $2 ORDER BY id',
            10, 25, { batch_size => 5 });

        my $count = 0;
        $count++ while await $ranged->next;
        await $ranged->close;
        print "  fetched $count rows\n";

        await $conn->query('DROP TABLE large_data');
    });
})->()->get;

await $pg->shutdown(timeout => 5);
```

- [ ] **Step 2: Run it and diff**

Expected, unchanged: `Streamed 250 rows, ids 1 - 250, 50 at a time` and `fetched 16 rows`.

- [ ] **Step 3: Rewrite 06's body**

Keep the callback signature exactly as it is -- `my ($channel, $payload, $pid) = @_` is correct and is what Task 1 corrects `llms.txt` to match. Replace the blocking `->get` calls and the polling loop:

```perl
(async sub {
    my @received;

    await $pg->listen('demo_channel', sub {
        my ($channel, $payload, $pid) = @_;
        push @received, [$channel, $payload, $pid];
        print "Received on $channel from pid $pid: $payload\n";
    });

    print "Sending notification...\n";
    await $pg->notify('demo_channel', 'hello from Async::DBD::Pg');

    # A notification arrives on the listener's own connection, so this waits
    # for the callback above rather than for the notify to return.
    my $deadline = time + 2;
    while (!@received && time < $deadline) {
        await Future::IO->sleep(0.05);
    }

    @received or die "Timed out waiting for notification\n";

    await $pg->unlisten_all;
})->()->get;

await $pg->shutdown(timeout => 5);
```

Note `shutdown` replaces the explicit `$pg->pubsub->disconnect` -- shutting the pool down takes the listener with it. Verify that is true when you run it; if the process hangs, restore the explicit disconnect and say so in your report.

- [ ] **Step 4: Run it and diff**

Expected, unchanged: `Sending notification...` then `Received on demo_channel from pid N: hello from Async::DBD::Pg`, and the process must EXIT rather than hang.

- [ ] **Step 5: Commit**

---

### Task 4: Drop the manual checkout from 03 and 05

Both already use `async`/`await`. What they still do is check a connection out by hand.

**Files:** `examples/03-transactions/app.pl`, `examples/05-parallel-queries/app.pl`

- [ ] **Step 1: 03-transactions**

It demonstrates a transaction, a rollback, and savepoint nesting -- keep all three. Replace the outer `my $conn = $pg->connection->get` / `$conn->release` with `$pg->transaction(...)`, which checks out and returns a connection for you and is what the example is about. Where the example needs a connection outside a transaction, use `$pg->with_connection`.

Add `await $pg->shutdown(timeout => 5);` at the end.

- [ ] **Step 2: Run it and diff**

Expected, unchanged: Alice $1000.00 / Bob $500.00, then `Caught: Oops, rollback`, then Alice $900.00 / Bob $500.00 / Charlie $100.00.

- [ ] **Step 3: 05-parallel-queries**

**Do not change what it measures.** The sequential-versus-parallel timing and the printed speedup are the entire point, and that property was silently broken in the documentation last week -- this example is the thing that would have caught it.

Replace the two manual checkouts with pool-level calls, keep the timing exactly as it is, and add `shutdown` at the end. The pool stats printed at the end must still be reachable -- `created`, `idle`, `active` -- so take the stats BEFORE shutting down.

- [ ] **Step 4: Run it and diff**

Expected: a sequential time, a parallel time, a speedup meaningfully above 1x, and the pool stats. The exact numbers vary; the speedup must not collapse to ~1x. If it does, stop and report -- that would mean the change serialised the example.

- [ ] **Step 5: Commit**

---

### Task 5: Modernise 07 and 08, and let them show the newer API

The two largest, both already async. They mainly need the connection pattern fixed, plus one genuine use each of something added recently.

**Files:** `examples/07-job-queue/app.pl`, `examples/08-live-dashboard/app.pl`

- [ ] **Step 1: 07-job-queue -- connection pattern**

It has four manual checkouts. Replace each with `with_connection` or `transaction` as fits. **Leave the `FOR UPDATE SKIP LOCKED` claiming logic exactly as it is** -- that is the correct primitive for a job queue and must not be replaced with advisory locks.

- [ ] **Step 2: 07-job-queue -- use a violation predicate on the failure path**

The example already has a job that fails (job 6, type `broken`). Where it records the failure, show that the error carries the server's diagnostics rather than only a string -- for example distinguishing a unique violation from any other failure using `$err->is_unique_violation` and `$err->constraint`, or at minimum printing `$err->state_name`. Keep the observable output shape: job 6 must still report as FAILED.

- [ ] **Step 3: Run 07 and diff**

Expected, unchanged: schema created, three workers, jobs 1-5 finishing, job 6 FAILED.

- [ ] **Step 4: 08-live-dashboard -- connection pattern**

Three manual checkouts; same treatment.

- [ ] **Step 5: 08-live-dashboard -- add `on_query`**

A dashboard is exactly where query observability belongs. Add an `on_query` handler to the pool that counts statements, and print the count in the dashboard frame alongside the metrics. Keep the existing frame layout; add a line rather than restructuring it.

- [ ] **Step 6: Run 08 and diff**

Expected: dashboard frames with the four metrics and their bars, plus the new statement count. It must still terminate on its own.

- [ ] **Step 7: Commit**

---

### Task 6: Guard the examples, and update their READMEs

**Files:** `t/unit/examples.t` (create), `examples/*/README.md`

- [ ] **Step 1: Write the guard**

Create `t/unit/examples.t`:

```perl
use strict;
use warnings;
use Test2::V0;

# The examples are documentation that happens to be executable. Nothing else
# in this suite looks at them, so a rename in lib/ can break all eight and
# every test still passes. This checks the two properties that can be checked
# without a database: they compile, and they follow the idiom the
# documentation now teaches.

my @examples = sort glob 'examples/*/app.pl';

ok scalar @examples >= 8, 'found the examples' or diag "found: @examples";

for my $file (@examples) {
    my $out = qx{$^X -Ilib -c \Q$file\E 2>&1};
    like $out, qr/syntax OK/, "$file compiles" or diag $out;

    open my $fh, '<', $file or die "cannot read $file: $!";
    my $src = do { local $/; <$fh> };
    close $fh;

    # Without a real Future::IO implementation the pool runs serially, with
    # no error and no warning. Every example must load one.
    like $src, qr/Future::IO->load_best_impl/,
        "$file loads a Future::IO implementation";

    # A connection taken by hand is lost to the pool if anything between the
    # checkout and the release dies. The examples should demonstrate the
    # scoped forms instead.
    unlike $src, qr/->connection\b/,
        "$file does not check a connection out by hand";

    like $src, qr/\bshutdown\b/, "$file shuts the pool down";
}

done_testing;
```

- [ ] **Step 2: Run it**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/unit/examples.t
```

Expected: PASS, once Tasks 2-5 have landed. If any example still fails an assertion, that example was missed -- go back and fix the example, not the test.

- [ ] **Step 3: Update the READMEs**

Each example directory has a `README.md`. Read each and update any code it quotes that has changed. Do not rewrite prose that is still accurate.

- [ ] **Step 4: Full suite and commit**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" prove -r -l t/
```

Expected: 23+ files, all pass, pristine.

- [ ] **Step 5: Mutation check**

Commit first. Then, in any one example, replace a `with_connection` call with a manual `$pg->connection` checkout: `t/unit/examples.t` must fail naming that file. Restore and confirm `git diff` is empty.

---

### Task 7: Run all eight end to end

**Files:** none -- this is verification.

- [ ] **Step 1: Run every example against the live database**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default
export DATABASE_URL="postgresql://postgres:test@localhost:5433/test"
for d in examples/*/; do
  echo "=== $d"
  perl -e 'alarm 30; exec @ARGV' perl -Ilib "$d/app.pl" 2>&1 | head -20
  echo "  [exit $?]"
done
```

- [ ] **Step 2: Diff every output against the record**

Compare each against the "Current output" section at the top of this plan. Report any difference, including differences you believe are improvements -- the point is that a reader who ran these yesterday sees what they expect today.

Values that legitimately vary: timings in 05, the pid in 06, the random metrics in 08, and the new statement count in 08.

- [ ] **Step 3: Confirm every example exits on its own**

None may hang. `06` and `08` are the risks. Report the wall-clock each took.

## Out of scope

**New examples.** Eight is enough; this plan modernises what exists.

**Changing what any example demonstrates.** `07`'s `SKIP LOCKED` claiming and `05`'s timing measurement are correct and stay.

**Running the examples in CI.** They need a live database and several are long-running. `t/unit/examples.t` checks what can be checked without one; Task 7 is a manual gate.

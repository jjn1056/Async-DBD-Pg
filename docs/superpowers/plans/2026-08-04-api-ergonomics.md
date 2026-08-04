# API Ergonomics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** make the common case as easy as the competition's, without giving up what this library does better.

**Architecture:** four independent changes to the public surface. Nothing in the pool, listener, or binding machinery changes. Each task is separately reviewable and separately revertable.

**Tech Stack:** Perl 5.24+, Future::AsyncAwait, Future::IO (UV and IOAsync), DBD::Pg 3.20.2, Test2::V0.

**Origin:** an API review on 2026-08-04 that used the library rather than reading it. The engine is strong — 8 concurrent 200 ms queries in 0.34 s, transactions rolling back correctly, error objects carrying SQLSTATE, table and constraint. Every problem found was on the surface.

## Global Constraints

- Every Perl command prefixed: `source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default`. Never system perl.
- `TEST_PG_DSN` is **required** — there is no default. Locally the database is on port **5433**; confirm with `docker ps` rather than trusting either number.
- Run the full suite under **both** `PERL_FUTURE_IO_IMPL=UV` and `=IOAsync`. Expect **209 tests** before any task adds to it.
- **Test output must be pristine** — zero bytes on stderr, checked explicitly.
- POD must stay **ASCII only**. No em-dashes. `dist.ini` runs `[PodSyntaxTests]`, and a non-ASCII character without `=encoding` fails it. Run `podchecker` on any file whose POD you touch.
- Document every new public method in POD **in the same commit**.
- TDD: write the failing test, watch it fail for the stated reason, then implement. Mutation-verify each task.
- One agent on the database at a time. Confirm `pgrep -f prove` is empty and `pg_stat_activity` shows no other backends before each run.

## File Structure

- `lib/Async/DBD/Pg/Error.pm` — accessor rename (Task 1)
- `lib/Async/DBD/Pg/Cursor.pm` — close on exhaustion (Task 2)
- `lib/Async/DBD/Pg.pm` — pool-level `query`/`transaction` (Task 3), scoped handle (Task 4)
- `t/unit/error.t`, `t/integration/cursor.t`, `t/integration/connection.t`, `t/pool/basic.t`

---

### Task 1: `state` means SQLSTATE, as it does everywhere else

**Files:**
- Modify: `lib/Async/DBD/Pg/Error.pm`
- Test: `t/unit/error.t`, `t/integration/connection.t`

**Interfaces:**
- Produces: `$err->state` returns the five-character SQLSTATE (`'23505'`). `$err->code` is retained as an alias for it. `$err->state_name` returns the readable name (`'unique_violation'`) or `'unknown'`.

**Why this first:** it is a breaking rename, and it gets more expensive every day the distribution is public. It is currently at 0.001001.

DBI documents `state` as the five-character SQLSTATE. Ours returns a name, and `'unknown'` more often than not — the map covers about thirteen codes and PostgreSQL has hundreds. So the accessor named after DBI's SQLSTATE holds something else, and usually holds nothing useful. Anyone with DBI muscle memory writes `$e->state eq '23505'` and it silently never matches.

- [ ] **Step 1: Write the failing test**

Replace the `state` assertions in `t/unit/error.t` and add:

```perl
subtest 'state is the SQLSTATE, matching DBI' => sub {
    my $err = Async::DBD::Pg::Error::Query->new(
        message => 'boom', code => '23505',
    );

    is $err->state, '23505',
        'state is the five-character SQLSTATE, as DBI documents it';
    is $err->code, '23505',
        'code remains an alias for the same thing';
    is $err->state_name, 'unique_violation',
        'the readable name moved to state_name';

    my $odd = Async::DBD::Pg::Error::Query->new(message => 'x', code => '99999');
    is $odd->state, '99999', 'an unmapped code still reports its SQLSTATE';
    is $odd->state_name, 'unknown', 'and only the name is unknown';
};
```

- [ ] **Step 2: Run it and watch it fail**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && perl -Ilib -It/lib t/unit/error.t
```

Expected: `state` returns `unique_violation` where `23505` is wanted, and `state_name` does not exist.

- [ ] **Step 3: Rename**

In `Error.pm`, `state` returns the code and `state_name` does the lookup:

```perl
# The five-character SQLSTATE, which is what DBI's own state() returns and
# what callers compare against. Kept as the meaning of state() rather than a
# readable name: a name is only useful for the handful of codes this module
# happens to map, while the code is always present and is what PostgreSQL's
# documentation is indexed by.
sub state { $_[0]->{code} }
sub code  { $_[0]->{code} }

# The readable name for the codes worth naming, 'unknown' otherwise.
sub state_name {
    my ($self) = @_;
    return $STATE_MAP{ $self->{code} // '' } // 'unknown';
}
```

- [ ] **Step 4: Update the other tests that pin the old meaning**

`t/unit/error.t:35`, `:101`, `:111` and `t/integration/connection.t:158` assert the old `state`. Change them to `state_name`, preserving what each was checking. Do not delete any assertion.

- [ ] **Step 5: POD**

Document all three accessors, and say plainly that `state` changed meaning. ASCII only.

- [ ] **Step 6: Run the full suite, both implementations, and podchecker**

- [ ] **Step 7: Mutation-verify**

Make `state` return `$STATE_MAP{...}` again. Expected: the new subtest reds on `state`, and nothing else does.

- [ ] **Step 8: Commit**

```bash
git add lib/Async/DBD/Pg/Error.pm t/unit/error.t t/integration/connection.t
git commit -m "state is the SQLSTATE, as DBI documents it

state returned a readable name and 'unknown' for most codes -- the map
covers thirteen of PostgreSQL's hundreds. Anyone with DBI muscle memory
compares state against '23505' and never matches.

state and code now both return the SQLSTATE; the name moved to state_name."
```

---

### Task 2: A drained cursor is finished

**Files:**
- Modify: `lib/Async/DBD/Pg/Cursor.pm`
- Test: `t/integration/cursor.t`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `next` and `each` close the cursor when they exhaust it. `is_closed` is then true, the cursor's transaction is committed, and `DESTROY` does not warn.

Draining a cursor today leaves it open, leaves the connection in a transaction, and warns at destruction:

    after ->each drained 300 rows: is_exhausted=yes is_closed=no
    in_transaction after the cursor is drained: YES
    Cursor 'cursor_1' was discarded without close()

`each` consumed every row and knows it is exhausted, then warns for not closing. `close` already commits and clears `in_transaction`; it simply is not called.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'draining a cursor finishes it' => sub {
    my $pg   = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 3);
    my $conn = $pg->connection->get;
    $conn->query('CREATE TEMP TABLE drained AS SELECT g AS id FROM generate_series(1,250) g')->get;

    my $cursor = $conn->cursor('SELECT id FROM drained', { batch_size => 100 })->get;

    my $seen = 0;
    my $noise = capture_stderr(sub {
        $cursor->each(async sub { $seen++ })->get;
    });

    is $seen, 250, 'every row was delivered';
    ok $cursor->is_exhausted, 'the cursor knows it is exhausted';
    ok $cursor->is_closed, 'and closed itself rather than warning about it later';
    ok !$conn->in_transaction,
        'the transaction the cursor opened was ended, not left on the connection';
    is $noise, '', 'nothing was written to stderr';

    $conn->release;
    $pg->shutdown->get;
};

subtest 'a cursor abandoned before exhaustion still warns' => sub {
    my $pg   = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 3);
    my $conn = $pg->connection->get;
    $conn->query('CREATE TEMP TABLE partial AS SELECT g AS id FROM generate_series(1,250) g')->get;

    # Closing on exhaustion must not silence the case the warning is for:
    # a caller who walks away mid-stream still leaves a cursor open.
    my $noise = capture_stderr(sub {
        my $cursor = $conn->cursor('SELECT id FROM partial', { batch_size => 10 })->get;
        $cursor->next->get;
        undef $cursor;
    });
    like $noise, qr/discarded without close/,
        'abandoning a cursor part-way through is still reported';

    $conn->release;
    $pg->shutdown->get;
};
```

- [ ] **Step 2: Run and watch both fail**

The first on `is_closed` and `in_transaction`; the second may already pass — record which, and do not weaken it if so.

- [ ] **Step 3: Close on exhaustion**

Wherever `next` sets `{exhausted}`, close before returning. `close` is async and both `next` and `each` are async subs, so awaiting it is safe. Guard against double-close, which `close` already tolerates.

- [ ] **Step 4: Run both new subtests, then the full suite on both implementations**

- [ ] **Step 5: Mutation-verify**

Remove the close-on-exhaustion call. Expected: the first subtest reds on `is_closed` and `in_transaction`; the second stays green.

- [ ] **Step 6: POD and commit**

Say that a fully consumed cursor closes itself and that an abandoned one must still be closed. ASCII only.

---

### Task 3: `$pg->query` and `$pg->transaction`

**Files:**
- Modify: `lib/Async/DBD/Pg.pm`
- Test: `t/pool/basic.t`

**Interfaces:**
- Consumes: nothing.
- Produces: `await $pg->query($sql, @bind)` returning `Async::DBD::Pg::Results`. `await $pg->transaction($code)` returning the callback's value. Both check out a connection, run, and release it — including when the work dies or the caller cancels.

The most common operation in any database library is one query. Today:

```perl
my $conn = await $pg->connection;
my $r    = await $conn->query('SELECT 1');
$conn->release;                    # forget this and it leaks -- measured
```

Every peer does it in one call: `pool.query` (node-postgres), `pool.fetch` (asyncpg), `$pg->db->query` (Mojo::Pg). The pool already proxies `listen`, `unlisten`, `notify` and `pubsub` to a connection — so the convenience layer exists and covers pub/sub but not the thing people do most.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'the pool runs a single statement without a manual checkout' => sub {
    my $pg = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 3);

    my $r = $pg->query('SELECT 42 AS answer')->get;
    is $r->first->{answer}, 42, 'the pool ran the statement';
    is $pg->active_count, 0, 'and released the connection';
    is $pg->idle_count, 1, 'back to idle, reusable';

    is $pg->query('SELECT $1::int AS n', 7)->get->first->{n}, 7,
        'bind parameters are passed through';

    $pg->shutdown->get;
};

subtest 'the pool releases its connection when the statement fails' => sub {
    my $pg = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 3);

    my $err = dies { $pg->query('SELECT * FROM no_such_table')->get };
    ok $err, 'the failure reaches the caller';
    is $pg->active_count, 0,
        'and the connection is still returned -- this is the leak the helper exists to prevent';

    ok $pg->query('SELECT 1')->get, 'the pool still works afterwards';
    $pg->shutdown->get;
};

subtest 'the pool runs a transaction without a manual checkout' => sub {
    my $pg = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 3);
    $pg->query('CREATE TABLE IF NOT EXISTS pooltx (n int)')->get;
    $pg->query('DELETE FROM pooltx')->get;

    $pg->transaction(async sub {
        my ($tx) = @_;
        await $tx->query('INSERT INTO pooltx VALUES (1)');
        await $tx->query('INSERT INTO pooltx VALUES (2)');
    })->get;
    is $pg->query('SELECT count(*) AS c FROM pooltx')->get->first->{c}, 2,
        'both statements committed';
    is $pg->active_count, 0, 'and the connection came back';

    my $err = dies {
        $pg->transaction(async sub {
            my ($tx) = @_;
            await $tx->query('INSERT INTO pooltx VALUES (3)');
            die "no\n";
        })->get
    };
    ok $err, 'a dying transaction still fails the caller';
    is $pg->query('SELECT count(*) AS c FROM pooltx')->get->first->{c}, 2,
        'and rolled back';
    is $pg->active_count, 0, 'and released the connection even so';

    $pg->query('DROP TABLE pooltx')->get;
    $pg->shutdown->get;
};

subtest 'a cancelled pool query does not strand its connection' => sub {
    my $pg = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 3);

    my $slow = $pg->query('SELECT pg_sleep(5)');
    ok wait_until(sub { $pg->active_count == 1 }, 'query in flight', 3),
        'the statement is running';
    $slow->cancel;

    ok wait_until(sub { $pg->active_count == 0 }, 'released after cancel', 5),
        'cancelling releases the checkout rather than stranding it';

    $pg->shutdown->get;
};
```

- [ ] **Step 2: Run and watch them fail** with `Can't locate object method "query"`.

- [ ] **Step 3: Implement**

```perl
# Check out, run, release -- including when the statement fails or the caller
# cancels mid-flight. A guard rather than a release after the await: a
# cancelled async sub never resumes, so anything after the await would not
# run, which is exactly how a checkout gets stranded.
async sub query {
    my ($self, @args) = @_;

    my $conn  = await $self->connection;
    my $guard = Async::DBD::Pg::_ReleaseGuard->new($conn);

    return await $conn->query(@args);
}

async sub transaction {
    my ($self, $code) = @_;

    my $conn  = await $self->connection;
    my $guard = Async::DBD::Pg::_ReleaseGuard->new($conn);

    return await $conn->transaction($code);
}
```

`_ReleaseGuard` is the same shape as `Async::DBD::Pg::PubSub::_CheckoutGuard`: holds the connection, releases it in `DESTROY`, and is never disarmed because the checkout is never published anywhere else. Read that class before writing this one — it exists because a release placed after an `await` is skipped on cancellation, which is the bug this task is preventing.

Do **not** add `$pg->cursor` here. A cursor outlives the call that created it, so the connection cannot be released when `cursor()` returns; that needs Task 2's self-closing cursor and is deferred to a follow-up.

- [ ] **Step 4: Full suite, both implementations**

- [ ] **Step 5: Mutation-verify**

Replace the guard with a plain `$conn->release` after the await. Expected: `'a cancelled pool query does not strand its connection'` reds, and the failure subtest reds too. If neither does, the guard is not what is releasing and that is the finding.

- [ ] **Step 6: POD and commit**

Document both, and say the connection is returned automatically. Note that `query` is for one statement and a scoped handle (Task 4) is for several. ASCII only.

---

### Task 4: A scoped connection handle

**Files:**
- Modify: `lib/Async/DBD/Pg.pm`
- Test: `t/pool/basic.t`

**Interfaces:**
- Consumes: Task 3's `_ReleaseGuard`.
- Produces: a handle that borrows a connection and returns it when the handle goes out of scope.

`$pg->query` covers one statement. Several statements on one connection still means a manual checkout and a release you can forget. A handle whose lexical scope owns the checkout removes the obligation without a callback.

**This task's shape needs a ruling before it starts.** The obvious model is Mojo::Pg's `$pg->db`, and there is unease about adopting Mojo idioms wholesale. The mechanism is not in question; the naming and the borrow semantics are:

| option | call site | notes |
|---|---|---|
| `$pg->db` | `my $db = await $pg->db; await $db->query(...)` | Mojo's name. Familiar to Mojo users, opaque to everyone else -- "db" names the wrong thing, since it is a borrowed connection rather than a database. |
| `$pg->checkout` | `my $c = await $pg->checkout; await $c->query(...)` | Says exactly what it does. No precedent in other clients. |
| `$pg->with_connection(async sub {...})` | callback, released at return | No lexical-lifetime subtlety at all, and no chance of holding it past its usefulness. Costs an indentation level. |

The callback form is the safest and the least surprising; the handle form reads better for long procedural code. They are not exclusive.

- [ ] **Step 1: Get the ruling.** Do not implement until the shape is chosen. Record the decision and the reason in this plan before writing any code.

- [ ] **Step 2 onwards:** to be written once the shape is settled. The tests will mirror Task 3's: it releases on success, on failure, and on cancellation; a second borrow works afterwards; and the mutation is removing whatever performs the release.

---

## Deferred, for discussion after these four

- `Results` shapes: `hashes`, `arrays`, `hash`, `array`, `expand`, `each`. Mojo::Pg has them all and we have none, but the shape is exactly the Mojo influence that needs discussing rather than importing.
- `$pg->cursor`, once Task 2 makes a cursor clean up after itself.
- Batch insert / `executemany`, which every peer has and is the common bulk path.

## Done when

- The suite passes under both implementations with zero bytes on stderr, and `pg_stat_activity` shows no leaked backends.
- `podchecker` is clean on every module whose POD was touched.
- Each task's mutation redded the test that names its property, and nothing else.
- `$pg->query('SELECT 1')` works, which is the sentence this whole plan exists to make true.

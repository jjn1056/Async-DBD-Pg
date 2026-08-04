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
- `lib/Async/DBD/Pg/Connection.pm` — `transaction` signature (Task 3)
- `lib/Async/DBD/Pg.pm` — pool-level `query`, `transaction`, `with_connection` (Task 4)
- `t/unit/error.t`, `t/integration/cursor.t`, `t/integration/transaction.t`, `t/pool/basic.t`

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

### Task 3: One callback convention -- options lead, arguments trail

**Files:**
- Modify: `lib/Async/DBD/Pg/Connection.pm` (`transaction`), `lib/Async/DBD/Pg/Cursor.pm` (`each`)
- Test: `t/integration/transaction.t`, `t/integration/cursor.t`

**Interfaces:**
- Produces: `await $conn->transaction($code, @args)` and
  `await $conn->transaction(\%opts, $code, @args)`. `$code` is called as
  `$code->($conn, @args)`. `await $cursor->each($code, @args)` calls
  `$code->($row, @args)`.

**Why before the pool helpers:** Task 4 adds three more callback-taking methods.
Settling the convention first means they are written once against it, rather
than written and then changed.

Two problems today. Every callback captures what it needs from the enclosing
scope, so a loop that spawns work has to be careful about what each closure
closed over -- passing values as parameters removes the question. And
`transaction` takes its options *after* the callback:

```perl
await $conn->transaction($code, isolation => 'serializable');
```

which both hides the options behind a block a reader has to scroll past, and
occupies the slot trailing arguments need.

**Ruling:** options move to a leading hashref, so a reader sees them before the
body, and trailing arguments are forwarded to the callback. This is a breaking
change to a documented signature. It is used nowhere in the tree except its own
POD example, and the distribution is at 0.001001, so it is cheaper now than
after a release.

- [ ] **Step 1: Write the failing tests**

```perl
subtest 'transaction forwards trailing arguments to its callback' => sub {
    my $pg   = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 3);
    my $conn = $pg->connection->get;
    $conn->query('CREATE TEMP TABLE argtest (n int, tag text)')->get;

    # Passed in rather than closed over, so a caller looping over work does
    # not have to reason about what each closure captured.
    $conn->transaction(async sub {
        my ($tx, $n, $tag) = @_;
        await $tx->query('INSERT INTO argtest VALUES ($1, $2)', $n, $tag);
    }, 42, 'from-args')->get;

    my $r = $conn->query('SELECT n, tag FROM argtest')->get->first;
    is $r->{n}, 42, 'a trailing argument reached the callback';
    is $r->{tag}, 'from-args', 'and so did the second';

    $conn->release;
    $pg->shutdown->get;
};

subtest 'transaction takes its options first, where they are visible' => sub {
    my $pg   = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 3);
    my $conn = $pg->connection->get;

    my $level = $conn->transaction({ isolation => 'serializable' }, async sub {
        my ($tx) = @_;
        return await $tx->query('SHOW transaction_isolation');
    })->get;
    is $level->first->{transaction_isolation}, 'serializable',
        'a leading options hashref is read as options';

    # And options plus arguments together, which is the shape that has to work
    # for the convention to be worth having.
    my $got = $conn->transaction({ isolation => 'serializable' }, async sub {
        my ($tx, $value) = @_;
        return $value;
    }, 'passed-through')->get;
    is $got, 'passed-through', 'options and arguments coexist';

    $conn->release;
    $pg->shutdown->get;
};

subtest 'each forwards trailing arguments to its callback' => sub {
    my $pg   = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 3);
    my $conn = $pg->connection->get;
    $conn->query('CREATE TEMP TABLE eachargs AS SELECT g AS id FROM generate_series(1,5) g')->get;

    my $cursor = $conn->cursor('SELECT id FROM eachargs', { batch_size => 2 })->get;
    my @seen;
    $cursor->each(async sub {
        my ($row, $prefix) = @_;
        push @seen, "$prefix$row->{id}";
    }, 'row-')->get;

    is scalar(@seen), 5, 'every row was delivered';
    is $seen[0], 'row-1', 'and the trailing argument came with it';

    $conn->release;
    $pg->shutdown->get;
};
```

- [ ] **Step 2: Run and watch them fail.** The first two on the arguments not arriving and the leading hashref being taken for a callback; the third on `each` ignoring extra arguments.

- [ ] **Step 3: Implement in `Connection::transaction`**

```perl
async sub transaction {
    my ($self, @rest) = @_;

    # Options lead so a reader sees them before the block, and so the trailing
    # slot is free for arguments the caller wants forwarded rather than closed
    # over. A code ref is never a hashref, so the two forms cannot be confused.
    my %opts = ref $rest[0] eq 'HASH' ? %{ shift @rest } : ();
    my ($code, @args) = @rest;
    ...
}
```

Every `$code->($self)` call site in that sub becomes `$code->($self, @args)`.
There are several -- the savepoint path and the top-level path both invoke it.
Change them all; missing one gives a callback that silently receives nothing.

- [ ] **Step 4: Implement in `Cursor::each`** -- `each($code, @args)` calling `$callback->($row, @args)`.

- [ ] **Step 5: Update the POD for both.** Show the options-first form and the trailing-argument form. State plainly that options moved. ASCII only, and run `podchecker`.

- [ ] **Step 6: Full suite, both implementations**

- [ ] **Step 7: Mutation-verify.** Drop `@args` from the `$code->(...)` calls in `transaction`. Expected: the first subtest reds on the values not arriving; the isolation subtest stays green, proving the two are independent.

- [ ] **Step 8: Commit**

```bash
git add lib/Async/DBD/Pg/Connection.pm lib/Async/DBD/Pg/Cursor.pm t/integration/transaction.t t/integration/cursor.t
git commit -m "Callback convention: options lead, arguments trail

transaction took its options after the callback, which hid them behind a
block and occupied the slot trailing arguments need. Options now come
first, where a reader sees them, and trailing arguments are forwarded to
the callback so a caller can pass values instead of closing over them.

Breaking change to a documented signature, used nowhere in the tree but
its own POD example, and cheaper at 0.001001 than after a release."
```

---

### Task 4: The pool runs statements without a manual checkout

**Files:**
- Modify: `lib/Async/DBD/Pg.pm`
- Test: `t/pool/basic.t`

**Interfaces:**
- Consumes: Task 3's callback convention.
- Produces: `await $pg->query($sql, @bind)`, `await $pg->transaction($code, @args)`,
  `await $pg->transaction(\%opts, $code, @args)`, and
  `await $pg->with_connection($code, @args)`. All check out a connection, run,
  and release it -- including when the work dies or the caller cancels.

The most common operation in any database library is one query. Today it is a
checkout, a query, and a release you can forget -- measured: forgetting leaves
`active_count` at 1. Every peer does it in one call: `pool.query`
(node-postgres), `pool.fetch` (asyncpg), `$pg->db->query` (Mojo::Pg). The pool
already proxies `listen`, `unlisten`, `notify` and `pubsub`, so the convenience
layer exists and covers pub/sub but not the thing people do most.

`with_connection` covers the multi-statement case with a scope a reader can
see, and forwards arguments so a loop does not have to reason about what each
closure captured. Verified against a prototype: it releases on success, on a
dying body, and on cancellation.

- [ ] **Step 1: Write the failing tests**

```perl
subtest 'the pool runs a single statement without a manual checkout' => sub {
    my $pg = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 3);

    is $pg->query('SELECT 42 AS answer')->get->first->{answer}, 42, 'the pool ran it';
    is $pg->active_count, 0, 'and released the connection';
    is $pg->idle_count, 1, 'back to idle, reusable';
    is $pg->query('SELECT $1::int AS n', 7)->get->first->{n}, 7, 'binds pass through';

    $pg->shutdown->get;
};

subtest 'the pool releases its connection when the statement fails' => sub {
    my $pg = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 3);

    ok dies { $pg->query('SELECT * FROM no_such_table')->get }, 'the failure reaches the caller';
    is $pg->active_count, 0,
        'and the connection is returned -- the leak this helper exists to prevent';
    ok $pg->query('SELECT 1')->get, 'the pool still works afterwards';

    $pg->shutdown->get;
};

subtest 'with_connection scopes a checkout and forwards arguments' => sub {
    my $pg = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 3);
    $pg->query('CREATE TABLE IF NOT EXISTS wc (id int, tag text)')->get;
    $pg->query('DELETE FROM wc')->get;

    my $out = $pg->with_connection(async sub {
        my ($conn, $id, $tag) = @_;
        await $conn->query('INSERT INTO wc VALUES ($1, $2)', $id, $tag);
        return await $conn->query('SELECT tag FROM wc WHERE id = $1', $id);
    }, 5, 'scoped')->get;

    is $out->first->{tag}, 'scoped', 'the callback ran with its arguments';
    is $pg->active_count, 0, 'and the connection came back';

    ok dies { $pg->with_connection(async sub { die "boom\n" })->get }, 'a dying body fails the caller';
    is $pg->active_count, 0, 'and still releases';

    $pg->query('DROP TABLE wc')->get;
    $pg->shutdown->get;
};

subtest 'a cancelled pool call does not strand its connection' => sub {
    my $pg = Async::DBD::Pg->new(dsn => test_dsn(), min_connections => 0, max_connections => 3);

    my $slow = $pg->query('SELECT pg_sleep(5)');
    ok wait_until(sub { $pg->active_count == 1 }, 'query in flight', 3), 'the statement is running';
    $slow->cancel;
    ok wait_until(sub { $pg->active_count == 0 }, 'released after cancel', 5),
        'cancelling releases the checkout rather than stranding it';

    $pg->shutdown->get;
};
```

- [ ] **Step 2: Run and watch them fail** with `Can't locate object method "query"`.

- [ ] **Step 3: Implement**

```perl
# Check out, run, release -- including when the work fails or the caller
# cancels mid-flight. A guard rather than a release after the await: a
# cancelled async sub never resumes, so anything written after the await would
# not run, which is exactly how a checkout gets stranded. See
# Async::DBD::Pg::PubSub::_CheckoutGuard, which exists for the same reason.
async sub with_connection {
    my ($self, $code, @args) = @_;

    my $conn  = await $self->connection;
    my $guard = Async::DBD::Pg::_ReleaseGuard->new($conn);

    return await $code->($conn, @args);
}

async sub query {
    my ($self, @args) = @_;

    my $conn  = await $self->connection;
    my $guard = Async::DBD::Pg::_ReleaseGuard->new($conn);

    return await $conn->query(@args);
}

async sub transaction {
    my ($self, @rest) = @_;

    my $conn  = await $self->connection;
    my $guard = Async::DBD::Pg::_ReleaseGuard->new($conn);

    return await $conn->transaction(@rest);
}
```

`_ReleaseGuard` holds the connection and releases it in `DESTROY`. It is never
disarmed, because the checkout is never published anywhere else. Read
`_CheckoutGuard` in `PubSub.pm` before writing it.

Do **not** add `$pg->cursor`. A cursor outlives the call that created it, so
the connection cannot be released when `cursor()` returns. Task 2 makes a
cursor close itself, which is the prerequisite; it is listed as deferred.

- [ ] **Step 4: Full suite, both implementations**

- [ ] **Step 5: Mutation-verify.** Replace the guard with a plain `$conn->release` after the await. Expected: the cancellation subtest reds, and the dying-body assertions red. If neither does, the guard is not what is releasing, and that is the finding.

- [ ] **Step 6: POD and commit.** Document all three, and say the connection is returned automatically. Note that `query` is for one statement and `with_connection` for several. ASCII only, `podchecker` clean.

## Deferred, for discussion after these four

- `Results` shapes: `hashes`, `arrays`, `hash`, `array`, `expand`, `each`. Mojo::Pg has them all and we have none, but the shape is exactly the Mojo influence that needs discussing rather than importing.
- `$pg->cursor`, once Task 2 makes a cursor clean up after itself.
- Batch insert / `executemany`, which every peer has and is the common bulk path.

## Done when

- The suite passes under both implementations with zero bytes on stderr, and `pg_stat_activity` shows no leaked backends.
- `podchecker` is clean on every module whose POD was touched.
- Each task's mutation redded the test that names its property, and nothing else.
- `$pg->query('SELECT 1')` works, which is the sentence this whole plan exists to make true.

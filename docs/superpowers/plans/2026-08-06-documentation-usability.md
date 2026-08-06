# Documentation Usability Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make the documentation produce working, non-leaking, genuinely asynchronous code when a newcomer copies it.

**Architecture:** Three of these are not wording problems. Copying the canonical SYNOPSIS today gives you a database client that runs serially and leaks a pool slot on any query error, and the machine reference shows code that does not compile. Those get fixed first and guarded by tests that execute rather than parse. The rest closes gaps a reader hits in their first hour: how to catch an error, when to use the pool versus a connection, and how to type a bind.

**Tech Stack:** Perl 5.42 via perlbrew, POD, Markdown, Test2::V0.

## Global Constraints

- Never run Perl tooling under system perl. Prefix: `source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default`
- Database on **port 5433**: `TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test"`
- Baseline: **315 tests, 22 files, pristine**, via `prove -r -l t/`.
- **POD must be ASCII.** Use `--`, never an em-dash. Markdown files may use them. Note this is currently a convention, not an enforced rule: there is no `xt/` in this checkout and no ASCII assertion in `t/`; `[PodSyntaxTests]` checks POD syntax via podchecker, not character set. Task 7 makes it enforced.
- Test output MUST be pristine.
- `llms.txt` has a token budget enforced by `t/unit/docs.t`. Check it still passes after every edit there; prefer replacing words over adding them.
- Documentation claims must be true of the installed stack. Where this plan states a measurement, it was taken; do not restate it differently.

## Research findings this plan rests on

Measured before the plan was written. Do not re-derive; do flag anything that contradicts them.

> **CORRECTION, added after the final review.** One research finding below is
> false and is left in place rather than rewritten, because the work it drove
> was still worth doing and the record should show why. The claim that `await`
> at file scope "is a syntax error" is wrong: Future::AsyncAwait has allowed
> toplevel await since 0.47, this distribution requires 0.66+, and 0.71 is
> installed. Verified after the fact -- `perl -c` reports syntax OK and the
> program runs. The compile check this finding motivated still earns its place:
> it caught four genuinely broken listing blocks in `llms.txt` and a broken
> snippet in Task 6's own instructions. What it guards is that every block is
> syntactically valid Perl, which is what `t/unit/docs.t` now says.

- **Every SYNOPSIS omits the line that makes the library asynchronous.** All 8 modules' SYNOPSIS use `await`; none loads a Future::IO implementation. All 8 `examples/` do. Measured, four 1-second queries on four connections:

      WITHOUT load_best_impl: 4.12s   (serialized)
      WITH    load_best_impl: 1.11s   (concurrent)

  Future::IO's documentation gives the cause: its default implementation *"allows a single queue of read or write calls on a single filehandle only"* and *"will temporarily set filehandles into blocking mode"*. A pool is many filehandles. There is no error and no warning.

- **An unreleased connection never returns to the pool.** Not at scope exit, not after the enclosing async sub ends. `Connection::DESTROY` does release, but the async sub's frame holds the reference, so it never runs in practice. Measured `active=1 idle=0` at every point, and a pool of 2 with leaked connections raised `Connection pool exhausted (waited 30s)`.

- **The Pg.pm SYNOPSIS leaks on any query error.** It checks out, queries, then releases last, so a throwing query skips the release:

      SYNOPSIS pattern + query throws : active=1 idle=0   (lost)
      with_connection + same failure  : active=1 idle=1   (returned)

- **`eval { await ... }` catches correctly** inside an async sub, yielding an `Async::DBD::Pg::Error::Query` with `state`, `state_name` and the predicates populated. So an error-handling example is straightforward to write and to test.

- **`query_list` in scalar context yields the first value only** (measured: returns `1` for `SELECT 1 AS a, 2 AS b`). Undocumented.

- **`elapsed` is documented with units** in `Results.pm` POD ("fractional seconds"). Only the README's bare method list omits them. Corrected here: this is a README-only gap, not a POD one.

- **`t/unit/docs.t` cannot catch any of this.** It verifies documented methods exist and that each SYNOPSIS *parses*. Its own comment says so: *"It does NOT catch one that parses and then does the wrong thing ... Only executing the examples catches that class."* `llms.txt` code is not parsed at all.

## File Structure

| File | Change |
|---|---|
| `lib/Async/DBD/Pg.pm` | SYNOPSIS rewritten to be correct and non-leaking; new sections on async setup, pool-vs-connection, and error handling; `connection` documents the lifecycle |
| `lib/Async/DBD/Pg/{Connection,Cursor,PubSub,Results,Error}.pm` | SYNOPSIS gains a one-line pointer to the setup |
| `README.md` | Setup made explicit; typed-bind and named-placeholder examples; error handling; pool-vs-connection; `shutdown`; `elapsed` units |
| `llms.txt` | Runnable async context; missing constructor options; `query_list` scalar note; Collection wording |
| `t/unit/docs.t` | Guards: llms.txt code parses; every `await`-bearing SYNOPSIS names the setup |
| `t/integration/documented-setup.t` | **new** -- executes the documented setup and asserts it is genuinely concurrent and does not leak |

---

### Task 1: Make the documented setup correct, and prove it by running it

This is the one that matters most: today the canonical example is silently serial.

**Files:**
- Modify: `lib/Async/DBD/Pg.pm` (SYNOPSIS + a new section)
- Modify: `lib/Async/DBD/Pg/{Connection,Cursor,PubSub,Results,Error}.pm` (SYNOPSIS pointer)
- Test: `t/integration/documented-setup.t` (create)

- [ ] **Step 1: Write the failing test**

Create `t/integration/documented-setup.t`:

```perl
use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 't/lib';
use Test::Async::DBD::Pg qw(skip_without_postgres test_dsn);

my $dsn = skip_without_postgres();

use Future::IO;
BEGIN { Future::IO->load_best_impl; }

use Async::DBD::Pg;

# docs.t checks that a SYNOPSIS parses. Parsing is not the property that
# matters here: the setup this distribution documents either produces real
# concurrency or it does not, and the difference is invisible to a parser.
# Future::IO's default implementation drives one filehandle at a time and
# puts handles into blocking mode, so a pool built without loading a real
# implementation runs serially while looking perfectly correct.

subtest 'the documented setup actually overlaps queries' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 4, max_connections => 4);

    my $started = time;
    Future->wait_all(map { $pg->query_value('SELECT pg_sleep(1)') } 1 .. 4)->get;
    my $elapsed = time - $started;

    # Four one-second queries on four connections. Concurrent is ~1s;
    # serialized is ~4s. The threshold is deliberately loose -- this is
    # distinguishing 1 from 4, not benchmarking.
    ok $elapsed < 3,
        "four 1s queries on four connections took ${elapsed}s, so they overlapped";

    $pg->shutdown(timeout => 10)->get;
};

subtest 'every module SYNOPSIS names the setup it needs' => sub {
    my @modules = glob 'lib/Async/DBD/Pg.pm lib/Async/DBD/Pg/*.pm';

    for my $file (@modules) {
        open my $fh, '<', $file or die "cannot read $file: $!";
        my (@block, $in);
        while (my $line = <$fh>) {
            if ($line =~ /^=head1 SYNOPSIS/)     { $in = 1; next }
            if ($in && $line =~ /^=(head1|cut)/) { last }
            push @block, $line if $in;
        }
        close $fh;
        my $synopsis = join '', @block;

        next unless $synopsis =~ /\bawait\b/;

        # Either it shows the setup, or it says where the setup lives. A
        # synopsis that awaits and mentions neither is one a reader can copy
        # into a program that silently never runs concurrently.
        like $synopsis, qr/load_best_impl|Async::DBD::Pg\/SYNOPSIS|SEE ALSO/,
            "$file SYNOPSIS points at the async setup";
    }
};

done_testing;
```

- [ ] **Step 2: Run it and watch the second subtest fail**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
prove -l t/integration/documented-setup.t
```

Expected: the concurrency subtest PASSES (the test file loads an implementation itself); the SYNOPSIS subtest FAILS for all six `await`-bearing modules.

- [ ] **Step 3: Fix the main SYNOPSIS**

In `lib/Async/DBD/Pg.pm`, replace the whole SYNOPSIS block with:

```pod
=head1 SYNOPSIS

    use Future::AsyncAwait;
    use Future::IO;
    use Async::DBD::Pg;

    # Required. Without a real implementation loaded, Future::IO drives one
    # filehandle at a time and puts handles into blocking mode, so a pool
    # runs its queries one after another -- with no error and no warning.
    BEGIN { Future::IO->load_best_impl }

    my $pg = Async::DBD::Pg->new(
        dsn             => 'postgresql://user:pass@host/db',
        min_connections => 2,
        max_connections => 10,
    );

    (async sub {
        # The pool checks a connection out and gives it back for each of
        # these, so nothing can be left checked out by accident.
        my $user  = await $pg->query_row('SELECT * FROM users WHERE id = $1', 1);
        my $count = await $pg->query_value('SELECT count(*) FROM users');

        # Statements that must share one connection go in a block, which
        # returns the connection however the block ends -- including on death.
        await $pg->with_connection(async sub {
            my ($conn) = @_;
            await $conn->query('SET LOCAL statement_timeout = 5000');
            await $conn->query('SELECT * FROM big_report');
        });
    })->()->get;

    await $pg->shutdown(timeout => 5);
```

Two deliberate changes beyond adding the setup: the example no longer checks a connection out by hand, and it ends by shutting the pool down. The previous version did both wrongly -- see Task 3.

- [ ] **Step 4: Point the other SYNOPSISes at it**

In each of `Connection.pm`, `Cursor.pm`, `PubSub.pm`, `Results.pm` and `Error.pm`, add this as the first line of the SYNOPSIS block, indented as code:

```pod
    # Setup as in Async::DBD::Pg/SYNOPSIS -- Future::IO->load_best_impl is
    # required, or the pool runs serially.
```

- [ ] **Step 5: Run the test**

Expected: both subtests PASS.

- [ ] **Step 6: Full suite and commit**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" prove -r -l t/
git add lib/ t/integration/documented-setup.t
git commit -m "Document the setup without which the pool runs serially"
```

- [ ] **Step 7: Mutation check**

Commit first. Remove the `load_best_impl` line from the Pg.pm SYNOPSIS: the SYNOPSIS subtest must fail for that file. Restore. Then, in `t/integration/documented-setup.t`, remove its own `BEGIN { Future::IO->load_best_impl }`: the concurrency subtest must fail with roughly 4 seconds, which is the bug this task exists to prevent. Restore both.

---

### Task 2: Make the machine reference produce code that compiles

**Files:**
- Modify: `llms.txt`
- Modify: `t/unit/docs.t`

- [ ] **Step 1: Write the failing test**

Add to `t/unit/docs.t` before `done_testing`:

```perl
subtest 'the machine reference shows code that compiles' => sub {
    # This file exists to be read by code generators, so a snippet that
    # cannot compile becomes generated code that cannot run. The method-name
    # check above cannot see this: `await $pg->query(...)` at file scope
    # names a real method and is still a syntax error.
    open my $fh, '<', 'llms.txt' or die "cannot read llms.txt: $!";
    my @lines = <$fh>;
    close $fh;

    # Indented blocks are the code samples.
    my (@blocks, @current);
    for my $line (@lines, "\n") {
        if ($line =~ /^\s{4}\S/) { push @current, $line; next }
        push @blocks, join('', @current) if @current;
        @current = ();
    }

    my $checked = 0;
    for my $code (@blocks) {
        next unless $code =~ /\bawait\b|\bAsync::DBD::Pg\b/;

        # Wrapped exactly as the SYNOPSIS check wraps: await is legal only
        # inside an async sub, and a reference names variables it never
        # declares.
        my $ok = eval "use feature 'say'; no strict; no warnings; "
                    . "my \$unused = async sub {\n$code\n}; 1";
        my $err = $@; $err =~ s/\s+at\s\(eval.*//s; $err =~ s/\n.*//s;

        ok $ok, 'llms.txt block compiles' or diag "$err\n$code";
        $checked++;
    }

    ok $checked >= 5, "checked a real number of blocks ($checked)";
};
```

- [ ] **Step 2: Run it and watch it fail**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/unit/docs.t
```

Expected: FAIL. The Getting Started block awaits outside any async sub.

- [ ] **Step 3: Fix the Getting Started block**

Replace the `## Getting started` block in `llms.txt` with:

```
    use Future::AsyncAwait;
    use Future::IO;
    use Async::DBD::Pg;

    # Required: without it Future::IO drives one filehandle at a time and
    # the pool runs serially, with no error and no warning.
    BEGIN { Future::IO->load_best_impl }

    my $pg = Async::DBD::Pg->new(dsn => 'postgresql://user:pass@host/db');

    # await is legal only inside an async sub.
    (async sub {
        my $row   = await $pg->query_row('SELECT * FROM users WHERE id = $1', 42);
        my $count = await $pg->query_value('SELECT count(*) FROM users');
        my $rs    = await $pg->query('SELECT id, name FROM users');
    })->()->get;

    await $pg->shutdown(timeout => 5);
```

Later blocks in the file may keep using bare `await` as shorthand, but the top of the file must show the real shape once. If the compile check rejects a later shorthand block, wrap that block rather than deleting the check.

- [ ] **Step 4: Run the test, then the token budget**

Both must pass. `docs.t` enforces the budget; if the additions push it over, shorten prose elsewhere in `llms.txt` rather than dropping the setup.

- [ ] **Step 5: Commit**

```bash
git add llms.txt t/unit/docs.t
git commit -m "Show runnable async context in the machine reference"
```

---

### Task 3: Document the connection lifecycle, and stop teaching the leaking pattern

**Files:**
- Modify: `lib/Async/DBD/Pg.pm` (the `connection` section)
- Modify: `lib/Async/DBD/Pg/Connection.pm` (the `release` section)
- Test: `t/integration/documented-setup.t` (add a subtest)

- [ ] **Step 1: Write the failing test**

Add to `t/integration/documented-setup.t`:

```perl
subtest 'a connection checked out by hand is lost if it is not released' => sub {
    # The behaviour the documentation has to warn about, pinned so the
    # warning cannot quietly stop being true. DESTROY does release, but the
    # enclosing async sub's frame holds the reference, so it never runs.
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 2);

    (async sub {
        my $conn = await $pg->connection;
        await $conn->query_value('SELECT 1');
    })->()->get;

    is $pg->active_count, 1,
        'still checked out after the sub that took it has ended';
    is $pg->idle_count, 0, 'and the pool does not have it back';

    # with_connection returns it even when the body dies.
    my $err = dies {
        $pg->with_connection(async sub {
            my ($conn) = @_;
            await $conn->query('SELECT * FROM no_such_table_at_all');
        })->get
    };
    ok $err, 'the failure still reaches the caller';
    is $pg->idle_count, 1, 'and with_connection gave the connection back anyway';

    $pg->shutdown(timeout => 10)->get;
};
```

- [ ] **Step 2: Run it**

Expected: PASS immediately -- it documents current behaviour rather than changing it. That is the point: it is a regression guard for the warning being written in Step 3. Note in the report that this test passed without any code change.

- [ ] **Step 3: Document `connection`**

In `lib/Async/DBD/Pg.pm`, replace the body of `=head2 connection` with:

```pod
=head2 connection

    my $conn = await $pg->connection;
    ...
    $conn->release;

Check a connection out of the pool. Returns a
L<Async::DBD::Pg::Connection>.

B<You must release it, and a connection that is not released is gone for the
life of the pool.> Destruction would return it, but an C<async sub> holds its
lexicals until the sub itself is collected, so in practice the destructor does
not run and the slot is never recovered. A pool that loses every slot this way
stops answering: callers queue on C<connection> until C<queue_timeout> and then
fail with L<Async::DBD::Pg::Error::PoolExhausted>.

Releasing at the end of the block is not enough either, because anything that
dies in between skips it -- including a query that fails, which is not an
unusual event.

Prefer L</with_connection> or L</transaction>, which hold the checkout across
every C<await> and give it back however the block ends, death included. Reach
for C<connection> only when the checkout has to outlive a single block, and
then release it in the same place you would close a filehandle.
```

- [ ] **Step 4: Cross-reference from `release`**

In `lib/Async/DBD/Pg/Connection.pm`, extend the `release` documentation with:

```pod
A connection obtained from L<Async::DBD::Pg/connection> must be released, and
one that is not is lost to the pool permanently -- see that method for why the
destructor does not save you. Connections given to L<Async::DBD::Pg/with_connection>
or L<Async::DBD::Pg/transaction> are released for you.
```

- [ ] **Step 5: Full suite and commit**

```bash
git add lib/ t/integration/documented-setup.t
git commit -m "Say plainly that an unreleased connection is lost"
```

---

### Task 4: Show a failure being handled

**Files:**
- Modify: `README.md`, `lib/Async/DBD/Pg.pm`, `llms.txt`

- [ ] **Step 1: Add the section to Pg.pm POD**

After the pool-versus-connection section added in Task 5 -- or before `=head1 METHODS` if Task 5 has not landed yet -- add:

```pod
=head2 Handling failures

Every failure is thrown, not returned, so an ordinary C<eval> around the
C<await> catches it. What you catch is an object that stringifies to the
server's message and carries the detail with it:

    (async sub {
        my $ok = eval {
            await $pg->query('INSERT INTO users (email) VALUES ($1)', $email);
            1;
        };

        if (!$ok) {
            my $err = $@;

            if ($err->is_unique_violation) {
                warn "already taken: ", $err->constraint;   # users_email_key
            }
            elsif ($err->is_retryable) {
                # 40001 or 40P01: this transaction lost a race it may win
                # next time. See the retry option to transaction.
            }
            else {
                die $err;
            }
        }
    })->()->get;

The predicates answer on every error this distribution raises, not only on
query errors, so C<< $err->is_unique_violation >> on a lost connection is
false rather than fatal and needs no guarding.

PostgreSQL reports C<constraint> for a unique violation but leaves C<column>
undef -- it names the index that was violated, not the columns in it -- so
mapping one back to a field is done through the constraint name. See
L<Async::DBD::Pg::Error>.
```

- [ ] **Step 2: Add a compact version to README**

After the transaction example, add:

```markdown
Failures are thrown as objects that stringify to the server's message and
carry its diagnostics:

```perl
my $ok = eval {
    await $pg->query('INSERT INTO users (email) VALUES ($1)', $email);
    1;
};

if (!$ok && $@->is_unique_violation) {
    warn "already taken: ", $@->constraint;   # users_email_key
}
```

`is_retryable`, `is_unique_violation`, `is_foreign_key_violation` and
`is_not_null_violation` answer on every error class, so they never need
guarding with `can`.
```

- [ ] **Step 3: Add two lines to llms.txt**

Under `## Errors`, before the class list:

```
Thrown, not returned, so `eval { await ... ; 1 } or do { $@ }` catches them.
Predicates answer on every class, so they need no `can` guard.
```

- [ ] **Step 4: Verify the example actually works**

Write the README snippet to a scratch file against a table with a unique
constraint and run it. `docs.t` cannot execute examples, so this is a manual
check -- report the output in the task report.

- [ ] **Step 5: Full suite and commit**

---

### Task 5: Explain the pool and the connection

**Files:** `lib/Async/DBD/Pg.pm`, `README.md`, `llms.txt`

- [ ] **Step 1: Add the section to Pg.pm POD**

Immediately before `=head1 METHODS`:

```pod
=head2 The pool and a connection

Both objects answer C<query>, C<query_row>, C<query_value> and C<query_list>,
and the difference is which connection runs them.

Asking the B<pool> checks a connection out, runs the one statement, and gives
it straight back. Each call may land on a different connection, which is what
you want for statements that stand alone.

Asking a B<connection> runs on that connection every time. That matters
whenever two statements have to see each other: a transaction, a cursor, a
temporary table, C<SET LOCAL>, an advisory lock, C<LISTEN>. Sending those
through the pool would scatter them across connections and they would not
work.

So: reach for the pool by default, and get a connection when statements must
share one -- through L</with_connection> or L</transaction>, which give it
back for you.
```

- [ ] **Step 1a: Resolve an apparent contradiction between two sections**

The `connection` documentation says an `async sub` holds its lexicals, "so in
practice the destructor does not run" -- which is why an unreleased connection
is lost. But `with_connection` reliably gives its connection back even when the
body dies, and it is also inside an `async sub`. Both statements are true and a
careful reader comparing them will stall on it. Found by the Task 3 reviewer.

Add this to the end of the pool-and-connection section:

```pod
This is also why C<with_connection> can promise something C<connection>
cannot. Dying inside the block unwinds the scope in the ordinary way, and the
guard holding the checkout is released as part of that unwind -- immediately,
not whenever the enclosing C<async sub> is eventually collected. A connection
you took by hand has no such guard: nothing is watching the scope on your
behalf, so nothing gives it back.
```

Verify the claim before writing it rather than taking it from this plan: read
`Async::DBD::Pg::_ReleaseGuard` and confirm its C<DESTROY> is what releases,
and that C<with_connection> wraps the checkout in one. Say in your report what
you found.

- [ ] **Step 2: Add the short form to README**

Before the transaction example, replacing "Several statements that must share a connection go through...":

```markdown
`$pg->query` runs one statement on any free connection and gives it straight
back. Statements that must see each other -- a transaction, a cursor, a
temporary table, `SET LOCAL`, an advisory lock -- have to share one
connection, which is what `with_connection` and `transaction` are for: they
hold the checkout across every `await` and give it back however the block
ends.
```

- [ ] **Step 3: Add one line to llms.txt**

Under `## Pool`, after the method list:

```
Pool methods run one statement on any free connection. Use a Connection when
statements must see each other (transaction, cursor, temp table, SET LOCAL,
advisory lock) -- via with_connection or transaction, which release for you.
```

- [ ] **Step 4: Commit**

---

### Task 6: Close the remaining gaps

**Files:** `README.md`, `llms.txt`

Each item is small and independent. Do them together and commit once.

- [ ] **Step 1: Typed binds in the README**

The feature list warns that a `bytea` is silently truncated, then never shows
the fix. After the Results section:

```markdown
## Typed binds

A value may state its PostgreSQL type. This is required for `bytea`: sent as
text, a value is truncated at its first NUL byte and the write reports
success.

```perl
use DBD::Pg qw(:pg_types);

await $pg->query('INSERT INTO files (name, body) VALUES ($1, $2)',
    $name, { type => PG_BYTEA, value => $bytes });

# Or by name, which is what ->types reports and what a schema introspection
# already holds. Matching is case-insensitive.
await $pg->query('INSERT INTO files (name, body) VALUES ($1, $2)',
    $name, { type => 'bytea', value => $bytes });
```

Names are DBD::Pg's `PG_*` constants lowercased. A type DBD::Pg does not know
-- a user-defined enum, an extension type -- croaks naming the type; such a
type needs no typed bind anyway, being text on the wire.
```

- [ ] **Step 2: Named placeholders in the README**

In the same area:

```markdown
Placeholders come in two forms, not mixable in one statement:

```perl
await $pg->query('SELECT * FROM t WHERE id = $1 AND x = $2', 1, 'a');
await $pg->query('SELECT * FROM t WHERE id = :id', { id => 1 });
```

`?` is not a placeholder here, which leaves PostgreSQL's own operators alone:

```perl
await $pg->query(q{SELECT data ? 'key' FROM docs});   # jsonb exists
```
```

- [ ] **Step 3: `elapsed` units in the README**

In the Results method list, change `$rs->elapsed` to:

```
$rs->elapsed        # query duration, fractional seconds
```

(The POD already says this; only the README list is bare.)

- [ ] **Step 4: `query_list` scalar context**

In `llms.txt`, change the `query_list` line to:

```
    await $pg->query_list($sql, @bind)   # one row as a list: my ($id, $name) = ...
                                         # in scalar context: the first value only
```

And in `Connection.pm`'s `query_list` POD, add a sentence stating the same.

- [ ] **Step 5: Missing constructor options in llms.txt**

The list omits several real options, one of which is on by default. Replace it with:

```
Constructor options: `dsn`, `min_connections`, `max_connections`,
`idle_timeout`, `queue_timeout`, `connect_timeout`, `statement_timeout`,
`max_queries`, `statement_cache_size`, `heal_dead_connections` (default on),
`on_connect`, `on_release`, `on_log`, `on_query`, `reconnect`.
```

- [ ] **Step 6: Collection wording**

The section says `map`, `grep`, `sort` "all work" and then that there are no
such methods. Both are true; together they read as a contradiction. Replace
the opening line with:

```
A blessed arrayref, so the builtins apply directly: `@$collection`,
`$collection->[0]`, `map { ... } @$collection`.
```

- [ ] **Step 7: `shutdown` in the README**

The README never shows it. The Task 1 SYNOPSIS adds it to the POD; add the
same closing line to the README synopsis, with a sentence saying a
long-running program should shut the pool down so in-flight work finishes
rather than being cut off.

- [ ] **Step 8: Full suite and commit**

`docs.t` must still pass, including the token budget.

---

### Task 7: Verify the whole thing by running it

**Files:** `t/integration/documented-setup.t`

- [ ] **Step 1: Add a smoke test that executes the README's first example**

```perl
subtest 'the README synopsis runs against a real database' => sub {
    # docs.t proves the examples parse and name real methods. It cannot
    # prove they work, which is the class of bug that put a serialized
    # example in front of every new reader for months.
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 2, max_connections => 10);

    (async sub {
        await $pg->query('DROP TABLE IF EXISTS readme_users');
        await $pg->query('CREATE TABLE readme_users (id int, name text, active bool)');
        await $pg->query("INSERT INTO readme_users VALUES (1, 'Ada', true)");

        my $user  = await $pg->query_row('SELECT * FROM readme_users WHERE id = $1', 1);
        my $total = await $pg->query_value('SELECT count(*) FROM readme_users');
        my ($id, $name) = await $pg->query_list('SELECT id, name FROM readme_users LIMIT 1');

        is $user->{name}, 'Ada',  'query_row returns the row';
        is $total, 1,             'query_value returns the count';
        is [$id, $name], [1, 'Ada'], 'query_list returns the row as a list';

        my $rs = await $pg->query('SELECT id, name FROM readme_users WHERE active');
        is scalar(@{ $rs->rows }), 1, 'the result iterates';

        await $pg->query('DROP TABLE readme_users');
    })->()->get;

    $pg->shutdown(timeout => 10)->get;
};
```

Keep it in step with the README: if the synopsis changes, this changes.

- [ ] **Step 2: Run the full suite**

Expected: 22 files, pristine, with the new counts.

- [ ] **Step 3: Make the ASCII rule enforced rather than merely observed**

Every plan in this repository states that POD must be ASCII, but nothing
checks it: there is no `xt/` directory, and `[PodSyntaxTests]` generates a
podchecker test, which validates POD syntax and says nothing about character
set. The rule has held by discipline. A single smart quote pasted into a POD
example would pass every test in the suite.

Add to `t/unit/docs.t`, before `done_testing`:

```perl
subtest 'the shipped modules are ASCII' => sub {
    # An em-dash or a smart quote reads fine in a terminal and breaks
    # downstream consumers that assume Latin-1, and nothing else in this
    # suite would notice. The rule is stated in every plan; this is what
    # makes it true.
    for my $file (@MODULES) {
        open my $fh, '<:raw', $file or die "cannot read $file: $!";
        my $src = do { local $/; <$fh> };
        close $fh;

        my @bad;
        my $line = 1;
        for my $chunk (split /(\n)/, $src) {
            if ($chunk eq "\n") { $line++; next }
            push @bad, "$file:$line" if $chunk =~ /([^\x00-\x7F])/;
        }

        is \@bad, [], "$file is ASCII" or diag "non-ASCII at: @bad";
    }
};
```

Then verify the generated release check still passes:

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
podchecker lib/Async/DBD/Pg.pm lib/Async/DBD/Pg/*.pm
```

Expected: `pod syntax OK` for each, and the new subtest green.

- [ ] **Step 2a: Close the commented-out-setup hole**

Task 1's SYNOPSIS check is a substring match, so a SYNOPSIS whose `BEGIN`
block had been commented out would still pass if the word `load_best_impl`
survived anywhere in it -- in prose, or in a neighbouring comment. Found by
the Task 1 reviewer; the test cannot tell live code from a mention of it.

Tighten the assertion in `t/integration/documented-setup.t` so the main
SYNOPSIS must carry the setup as live code. Replace the `like` in the
'every module SYNOPSIS names the setup it needs' subtest with:

```perl
        if ($file eq 'lib/Async/DBD/Pg.pm') {
            # The canonical example must carry the setup as code, not as a
            # mention of it. A commented-out BEGIN with the word still
            # present nearby would otherwise satisfy a substring match.
            my $live = join "\n",
                grep { !/^\s*#/ } split /\n/, $synopsis;
            like $live, qr/BEGIN\s*\{\s*Future::IO->load_best_impl/,
                "$file SYNOPSIS loads an implementation in live code";
        }
        else {
            like $synopsis, qr/load_best_impl|Async::DBD::Pg\/SYNOPSIS|SEE ALSO/,
                "$file SYNOPSIS points at the async setup";
        }
```

The five pointer modules keep the substring check: they are meant to name
where the setup lives, not to repeat it.

- [ ] **Step 2b: Mutation check it**

Comment out the `BEGIN` line in the Pg.pm SYNOPSIS while leaving the
explanatory comment above it -- which still contains the word -- and confirm
the subtest now fails for `Pg.pm`. Restore.

- [ ] **Step 3a: Mutation check the ASCII test**

Commit first. Put a single em-dash into a POD line in `lib/Async/DBD/Pg.pm`
and confirm the new subtest fails naming that file and line. Restore with
`git checkout`.

- [ ] **Step 4: Commit**

## Out of scope

**New `examples/`.** All eight already load an implementation correctly and
compile. Adding examples for the newer features is feature work, not this.

**Executing every documented example.** Task 7 runs the README synopsis and
Task 1 runs the setup, because those are the two that were wrong. Running
every snippet would need fixtures for each and is a larger project.

**Changing any behaviour.** Every task here changes documentation and tests.
If a task appears to require a code change to make a documented claim true,
stop and report it rather than changing the code -- that means the
documentation and the library disagree about what is correct, which is a
decision, not an edit.

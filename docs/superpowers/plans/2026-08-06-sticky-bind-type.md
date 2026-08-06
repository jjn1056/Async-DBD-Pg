# Sticky Bind Type Fix Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Stop a cached statement handle handing its bind types to a later call that did not ask for them.

**Architecture:** Key the statement cache on the converted SQL *plus* the bind type signature, so calls with different type intent never share a handle. A bind list with no typed positions keeps the bare SQL as its key, so nothing about existing untyped behaviour changes.

**Tech Stack:** Perl 5.42 via perlbrew, DBD::Pg 3.20.2, DBI 1.650, PostgreSQL 16, Test2::V0.

**Issue:** `docs/known-issues/2026-08-06-sticky-pg-type-on-cached-statements.md`

## Global Constraints

- Never run Perl tooling under system perl. Prefix: `source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default`
- Database on **port 5433**: `TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test"`
- Documented test command is `prove -r -l t/`. Baseline at branch point: **313 tests, 22 files, pristine**.
- Test output MUST be pristine.
- POD must be ASCII -- `--`, never an em-dash.
- Commit before mutating a file for a mutation check.

## Research findings this rests on

All measured against the installed stack before the plan was written. Do not
re-derive; do flag anything the code contradicts.

- **The stickiness is documented DBI behaviour, not a driver bug.** DBI's
  `execute` documentation: values bound by passing them to `execute` are
  treated as `SQL_VARCHAR` *"unless `bind_param` ... has already been used to
  specify the type."* Our cache is what puts two different callers on one
  handle.
- **The type persists through `execute($value)`.** Passing values positionally
  does not reset a type set earlier by `bind_param`.
- **Stickiness is per parameter position**, not per handle: typing `$1` leaves
  `$2` untyped.
- **A fresh `prepare` of identical SQL inherits nothing.** State is per-handle,
  which is exactly why giving each type signature its own handle fixes it.
- **A set type cannot be cleared, only overwritten.** Neither `{}` nor
  `pg_type => 0` clears it.
- **"Untyped" is NOT equivalent to `PG_TEXT`**, so "always state a type" is not
  available as a fix:

      integer compare:  untyped=1   PG_TEXT=NULL   *** DIFFERENT ***

  Declaring an integer parameter as text breaks `WHERE n = $1`.
- **Only `pg_type` is at stake.** The bind loop sets no other attribute.
- **Every path into `_execute_async` comes through `query()`**, which resolves
  type names to OIDs first, so a signature built at that layer is canonical:
  `'bytea'` and `PG_BYTEA` produce the same key.

## File Structure

| File | Change |
|---|---|
| `lib/Async/DBD/Pg/Connection.pm` | `_cache_key`; `_statement_for` takes the key; `_execute_once`/`_execute_async` compute it; `_StatementGuard` carries it |
| `t/integration/statement-cache.t` | New subtests for the leak and for both variants coexisting |

Existing assertions in `statement-cache.t` index the cache by bare SQL. Every
bind in that file is untyped, so the fallback rule keeps all of them working
untouched. Do not rewrite them.

---

### Task 1: Key the statement cache on the bind type signature

**Files:**
- Modify: `lib/Async/DBD/Pg/Connection.pm`
- Test: `t/integration/statement-cache.t`

**Interfaces:**
- Produces: `_cache_key($sql, $bind)` -- package sub, returns the bare `$sql`
  when no bind position carries a type, otherwise `$sql`, a NUL, and the
  per-position types joined by commas.
- Changes: `_statement_for($key, $sql)` -- was `_statement_for($sql)`.
- Changes: `_StatementGuard->new($conn, $sth, $key)` -- the third argument was
  already only ever used as an eviction key; it is now named as one.

- [ ] **Step 1: Write the failing test**

Append to `t/integration/statement-cache.t` before `done_testing`:

```perl
subtest 'a typed bind does not leak its type to a later untyped one' => sub {
    my $pg = pool();
    my $conn = $pg->connection->get;

    $conn->query('SET client_min_messages = warning')->get;
    $conn->query('DROP TABLE IF EXISTS leak_probe')->get;
    $conn->query('CREATE TABLE leak_probe (n int, body bytea)')->get;

    # A bytea sent as text truncates at its first NUL. That is why a typed
    # bind exists, and it makes the leak visible as a length: an untyped bind
    # must store 1 byte whether or not a typed bind ran before it.
    my $bytes = "a\0bcd";
    my $sql   = 'INSERT INTO leak_probe VALUES ($1, $2)';

    $conn->query($sql, 1, $bytes)->get;
    $conn->query($sql, 2, { type => 'bytea', value => $bytes })->get;
    $conn->query($sql, 3, $bytes)->get;

    my $got = $conn->query(
        'SELECT n, length(body) AS len FROM leak_probe ORDER BY n')->get;

    is [ map { $_->{len} } @{ $got->rows } ], [1, 5, 1],
        'the third call stores what the first did, not what the second did';

    $conn->query('DROP TABLE leak_probe')->get;
    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

subtest 'each type signature gets its own cache entry' => sub {
    my $pg = pool();
    my $conn = $pg->connection->get;

    my $sql = 'SELECT length($1::bytea) AS n';

    $conn->query_value($sql, "a\0bcd")->get;
    is scalar(keys %{ $conn->{_stmt_cache} }), 1, 'the untyped form cached one';

    $conn->query_value($sql, { type => 'bytea', value => "a\0bcd" })->get;
    is scalar(keys %{ $conn->{_stmt_cache} }), 2,
        'the typed form is a second entry, not a reuse of the first';

    # Both stay cached, so a caller alternating the two forms does not thrash.
    $conn->query_value($sql, "a\0bcd")->get;
    is scalar(keys %{ $conn->{_stmt_cache} }), 2, 'and both survive';

    ok exists $conn->{_stmt_cache}{$sql},
        'the all-untyped form still keys on the bare SQL, so nothing else moves';

    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};
```

- [ ] **Step 2: Run it and watch it fail**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
prove -l t/integration/statement-cache.t
```

Expected: both new subtests FAIL. The first reports `[1, 5, 5]` -- the third
call inheriting the second's type. The second reports 1 entry where 2 are
expected.

- [ ] **Step 3: Add the key function**

In `lib/Async/DBD/Pg/Connection.pm`, add immediately before `sub _statement_for`:

```perl
# The cache key: the converted SQL, plus the types the binds carry.
#
# A type set with bind_param persists on the handle for later executes -- DBI
# documents this, and it survives passing values to execute() as well. So a
# handle bound (untyped, bytea) hands that bytea type to a later
# (untyped, untyped) call on the same handle, and the second caller's value
# goes to the server as something it never asked for. Two calls with different
# type intent must therefore never share a handle.
#
# Clearing a type is not available: neither an empty attribute hash nor
# pg_type => 0 clears one, and there is no synthetic default to overwrite it
# with -- "untyped" is not PG_TEXT, which turns `WHERE n = $1` on an integer
# into a comparison against text that matches nothing.
#
# A bind list with no typed position keys on the bare SQL, so the common case
# is byte-for-byte the key it always was.
sub _cache_key {
    my ($sql, $bind) = @_;

    my @signature = map {
        ref $_ eq 'HASH' && exists $_->{type} && exists $_->{value}
            ? ( $_->{type} // '' )
            : ''
    } @$bind;

    return $sql unless grep { $_ ne '' } @signature;

    # NUL, because it cannot appear in a statement that reached this far.
    return join "\0", $sql, join(',', @signature);
}
```

- [ ] **Step 4: Key the cache on it**

In `_statement_for`, change the signature and every `$sql` used as a cache
subscript to `$key`, leaving the `_prepare_statement($sql)` calls on the SQL:

```perl
sub _statement_for {
    my ($self, $key, $sql) = @_;
```

Inside it: `$self->{_stmt_cache}{$key}`, `grep { $_ ne $key }`,
`push @{ $self->{_stmt_lru} }, $key`, `$self->_evict_statement($key)`, and
`$self->{_stmt_cache}{$key} = $sth`. The two `_prepare_statement($sql)` calls
keep taking `$sql` -- the key is for the cache, the SQL is for the server.

In `_execute_once`, replace the `_statement_for` call and the guard construction:

```perl
    my $key = _cache_key($sql, $bind);
    my ($sth, $cached) = $self->_statement_for($key, $sql);
```

and pass `$key` where the guard currently receives `$sql`:

```perl
    my $statement = Async::DBD::Pg::Connection::_StatementGuard->new($self, $sth, $key);
```

In `_execute_async`, evict by the key rather than the SQL:

```perl
    $self->_evict_statement(_cache_key($sql, $bind));
```

In `_StatementGuard`, rename the third constructor argument and the field from
`sql` to `key` -- it was only ever used as an eviction key:

```perl
sub new {
    my ($class, $conn, $sth, $key) = @_;
    ...
    my $self = bless { conn => $conn, key => $key }, $class;
```

with `delete $self->{key}` in both `release` and `hand_over`.

Rename `_evict_statement`'s parameter from `$sql` to `$key` for the same
reason. Its body is already key-agnostic.

- [ ] **Step 5: Run the new tests**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
prove -l t/integration/statement-cache.t
```

Expected: PASS, all subtests, pristine.

- [ ] **Step 6: Run the full suite**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" prove -r -l t/
```

Expected: 315 tests across 22 files, PASS, pristine. Every pre-existing
assertion that indexes `_stmt_cache` by bare SQL must still pass untouched --
if any fails, the fallback rule in `_cache_key` is wrong, not the test.

- [ ] **Step 7: Update the known-issues note and commit**

Mark `docs/known-issues/2026-08-06-sticky-pg-type-on-cached-statements.md` as
fixed, naming the commit, and keep the reproduction and the research in place
-- it is the record of why the cache is keyed the way it is.

```bash
git add lib/Async/DBD/Pg/Connection.pm t/integration/statement-cache.t \
        docs/known-issues/2026-08-06-sticky-pg-type-on-cached-statements.md
git commit -m "Key the statement cache on bind types, not just SQL"
```

- [ ] **Step 8: Mutation check**

Commit first (done above).

Mutation A -- make the key ignore types by changing `_cache_key`'s body to
`return $sql;`. Expect BOTH new subtests to fail: the leak returns
(`[1, 5, 5]`) and the two-entry assertion drops to 1.

Mutation B -- invert the fallback by removing the
`return $sql unless grep { $_ ne '' } @signature;` line, so every bind list
gets a suffix. Expect the pre-existing assertions that index by bare SQL to
fail, which is what proves the fallback is load-bearing rather than cosmetic.

Restore with `git checkout lib/Async/DBD/Pg/Connection.pm` after each.

## Out of scope

**Anything about untyped `bytea` truncating.** That is DBD::Pg behaviour this
distribution documents and the reason typed binds exist. This fix makes the
behaviour consistent, not different: an untyped bind truncates whether or not
a typed one preceded it.

**A second cache dimension for anything else.** `pg_type` is the only
attribute the bind loop sets.

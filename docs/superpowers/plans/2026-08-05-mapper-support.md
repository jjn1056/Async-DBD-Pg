# Mapper Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a schema mapper the four things it needs from this driver: binds typed by PostgreSQL type name, a positional hydration hook, violation predicates on query errors, and per-connection attribution in the query event.

**Architecture:** Four independent changes across four existing files. Type names resolve through a map derived at load time from DBD::Pg's own `:pg_types` exports -- by construction the set `bind_param` accepts -- and are rewritten to OIDs in `query()` before the bind loop sees them, so the hot path is untouched and no round trip is added. `map_rows` hands the callback the positional row, adding the one thing `map` over `->rows` cannot do. The error predicates are lookups over an existing SQLSTATE map.

**Tech Stack:** Perl 5.42 via perlbrew, DBD::Pg 3.20.2, DBI 1.650, PostgreSQL 16, Future::AsyncAwait, Test2::V0.

**Spec:** `docs/superpowers/specs/2026-08-05-mapper-support-design.md`

## Global Constraints

- Never run `perl`, `prove`, `cpanm` or any Perl tooling under system perl. Every command is prefixed with `source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default`.
- The test database is on **port 5433**. `TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test"`.
- The documented test command is `prove -r -l t/`. Test that form, not an `-It/lib` variant.
- **POD must be ASCII.** Em-dashes in POD fail the release test. Use `--`.
- Test output MUST be pristine. A test that expects a log line or a NOTICE must capture and assert it, not let it print.
- Every new public method or option gets POD in the SAME commit that introduces it.
- Commit before mutating a file for a mutation check. `git checkout` on a file holding uncommitted work destroys it.
- Work on branch `mapper-support`, which already exists and carries the spec.
- Do not reduce coverage. Do not delete a failing test; raise it.

## File Structure

| File | Responsibility in this plan |
|---|---|
| `lib/Async/DBD/Pg/Connection.pm` | `%TYPE_OID` and `_resolve_bind_types` (Task 1); the diagnostics-ordering comment (Task 3); `id` accessor and the `connection` event field (Task 4) |
| `lib/Async/DBD/Pg.pm` | `server_version` and the connection id counter (Task 4) only. Task 1 touches it not at all |
| `lib/Async/DBD/Pg/Results.pm` | `map_rows` (Task 2) |
| `lib/Async/DBD/Pg/Error.pm` | Three violation predicates (Task 3) |
| `t/integration/typed-binds.t` | **new** -- Task 1 |
| `t/unit/results.t` | `map_rows` cases -- Task 2 |
| `t/integration/error-diagnostics.t` | **new** -- Task 3 |
| `t/integration/connection.t` | `server_version` and connection id -- Task 4 |
| `llms.txt` | Machine reference; updated in Tasks 1, 2, 4 |

Task order follows the spec's "Order of work": binds first because the mapper cannot emit a correct bind without them, hydration second, predicates third, the trivia last.

---

### Task 1: Binds by PostgreSQL type name

**Files:**
- Modify: `lib/Async/DBD/Pg/Connection.pm` (`query`, plus two new private methods)
- Modify: `llms.txt`
- Test: `t/integration/typed-binds.t` (create)

**Interfaces:**
- Produces: `$conn->_resolve_bind_types($bind_arrayref)` -- **synchronous**, returns a new arrayref with any `{ type => 'name' }` rewritten to `{ type => $oid }`. Croaks on a name DBD::Pg does not know.
- Produces: `%TYPE_OID` -- file-scope in Connection.pm, lowercased type name => OID, built once at load from `@{ $DBD::Pg::EXPORT_TAGS{pg_types} }` (200 entries).
- Consumes: nothing from other tasks.

- [ ] **Step 1: Write the failing test**

Create `t/integration/typed-binds.t`:

```perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 't/lib';
use Test::Async::DBD::Pg qw(skip_without_postgres test_dsn);

my $dsn = skip_without_postgres();

use Future::IO;
BEGIN { Future::IO->load_best_impl; }

use Async::DBD::Pg;
use DBD::Pg qw(:pg_types);

sub pool {
    my (%args) = @_;
    return Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 2, %args,
    );
}

subtest 'a type name binds the same bytes as the constant' => sub {
    my $pg = pool();
    my $conn = $pg->connection->get;

    $conn->query('SET client_min_messages = warning')->get;
    $conn->query('DROP TABLE IF EXISTS typed_binds')->get;
    $conn->query('CREATE TABLE typed_binds (id int, body bytea)')->get;

    # An embedded NUL is the whole point: bytea sent as text truncates there
    # and reports success, which is the failure typed binds exist to prevent.
    my $bytes = join '', map { chr } 0 .. 255;

    $conn->query('INSERT INTO typed_binds VALUES ($1, $2)',
        1, { type => PG_BYTEA, value => $bytes })->get;
    $conn->query('INSERT INTO typed_binds VALUES ($1, $2)',
        2, { type => 'bytea', value => $bytes })->get;

    my $by_constant = $conn->query_value('SELECT body FROM typed_binds WHERE id = $1', 1)->get;
    my $by_name     = $conn->query_value('SELECT body FROM typed_binds WHERE id = $1', 2)->get;

    is length($by_name), 256, 'the named bind round-trips all 256 bytes';
    is $by_name, $by_constant, 'and is byte-identical to the constant form';

    $conn->query('DROP TABLE typed_binds')->get;
    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

done_testing;
```

- [ ] **Step 2: Run it and watch it fail**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
prove -l t/integration/typed-binds.t
```

Expected: FAIL. `{ type => 'bytea' }` reaches `bind_param` as the string `bytea` where DBD::Pg wants a numeric OID.

- [ ] **Step 3: Build the name map from DBD::Pg's own exports**

In `lib/Async/DBD/Pg/Connection.pm`, add at file scope after the `use` block:

```perl
# name => OID for a bind that names its PostgreSQL type, derived from
# DBD::Pg's own :pg_types exports rather than a table maintained here:
# PG_BYTEA becomes 'bytea'. That is by construction exactly the set
# bind_param accepts, which resolving through PostgreSQL is not -- to_regtype
# happily returns the OID of a user-defined enum, and bind_param then refuses
# it with "Cannot bind 1 unknown pg_type 65025".
#
# Such a type does not need a typed bind in any case: it is text on the wire.
# The types that need one -- bytea above all, whose text form truncates at the
# first NUL -- are exactly the ones DBD::Pg knows.
#
# 29 of these are pseudo-types (any, internal, record, trigger, void) that
# bind_param refuses. They are left in rather than filtered by a list that
# would rot against DBD::Pg's next release; nobody binds them.
#
# 'char' follows DBD::Pg's PG_CHAR, the internal single-byte type (18), not
# SQL CHAR(n), which is 'bpchar' (1042).
my %TYPE_OID = do {
    no strict 'refs';
    map  { ( lc(substr $_, 3) => &{"DBD::Pg::$_"}() ) }
    grep { /\APG_./ }
    @{ $DBD::Pg::EXPORT_TAGS{pg_types} || [] };
};
```

- [ ] **Step 4: Add the resolver**

In `lib/Async/DBD/Pg/Connection.pm`, add these two subs immediately before `sub _parse_query_args`:

```perl
# True if any bind names its type rather than giving the numeric OID. Runs on
# every query, so it is a scan of binds already in hand and never a second
# pass over anything.
sub _binds_name_a_type {
    my ($bind) = @_;

    for my $value (@$bind) {
        next unless ref $value eq 'HASH';
        next unless exists $value->{type} && exists $value->{value};
        return 1 if defined $value->{type} && $value->{type} !~ /\A[0-9]+\z/;
    }

    return 0;
}

# Rewrite { type => 'bytea' } to { type => 17 } before the bind loop sees it.
#
# Done here rather than inside that loop because a croak raised in there would
# be caught by the surrounding eval and re-reported as a query error rather
# than as the caller's mistake.
sub _resolve_bind_types {
    my ($self, $bind) = @_;

    return $bind unless _binds_name_a_type($bind);

    my @resolved = @$bind;

    for my $i (0 .. $#resolved) {
        my $value = $resolved[$i];

        next unless ref $value eq 'HASH';
        next unless exists $value->{type} && exists $value->{value};
        next unless defined $value->{type} && $value->{type} !~ /\A[0-9]+\z/;

        my $oid = $TYPE_OID{ lc $value->{type} };

        croak "Unknown PostgreSQL type name '$value->{type}' for bind "
            . 'parameter ' . ($i + 1) . '. Names are DBD::Pg\'s, such as '
            . 'bytea or jsonb; a type DBD::Pg does not know cannot be bound '
            . 'by type at all, so bind it untyped or cast it in SQL'
            unless defined $oid;

        $resolved[$i] = { type => $oid, value => $value->{value} };
    }

    return \@resolved;
}
```

- [ ] **Step 5: Call it from query()**

In `lib/Async/DBD/Pg/Connection.pm`, in `sub query`, insert immediately after the `if (ref $bind eq 'HASH') { ... }` block and before the `if (delete $self->{_check_liveness})` block:

```perl
    # Synchronous: the map is built at load time, so this costs no round trip
    # and needs no await.
    $bind = $self->_resolve_bind_types($bind);
```

Nothing is added to `lib/Async/DBD/Pg.pm` for this task -- there is no pool-level cache, because there is nothing to cache.

- [ ] **Step 6: Run the test**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
prove -l t/integration/typed-binds.t
```

Expected: PASS.

- [ ] **Step 7: Add the remaining subtests**

Append to `t/integration/typed-binds.t`, before `done_testing`:

```perl
subtest 'a type DBD::Pg cannot bind croaks, naming the type' => sub {
    my $pg = pool();
    my $conn = $pg->connection->get;

    $conn->query('SET client_min_messages = warning')->get;
    $conn->query('DROP TYPE IF EXISTS mapper_mood CASCADE')->get;
    $conn->query("CREATE TYPE mapper_mood AS ENUM ('ok', 'bad')")->get;

    # bind_param refuses any OID outside DBD::Pg's own table, so naming a
    # user-defined type has to fail -- the question is only whether it fails
    # legibly here or as "Cannot bind 1 unknown pg_type 65025" deep inside
    # DBD::Pg. This is the case that decided the design.
    my $err = dies {
        $conn->query_value('SELECT $1::mapper_mood::text',
            { type => 'mapper_mood', value => 'ok' })->get
    };

    like "$err", qr/mapper_mood/, 'the message names the type, not an OID';

    # And it did not need a typed bind in the first place: an enum is text on
    # the wire. This is the documented way to bind one.
    my $value = $conn->query_value('SELECT $1::mapper_mood::text', 'ok')->get;
    is $value, 'ok', 'binding it untyped works, which is why this is no loss';

    $conn->query('DROP TYPE mapper_mood')->get;
    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

subtest 'resolving a name costs no query of its own' => sub {
    my @sql;
    my $pg = pool(on_query => sub { push @sql, $_[0]{sql} });
    my $conn = $pg->connection->get;

    @sql = ();
    $conn->query_value('SELECT length($1)', { type => 'bytea', value => 'abc' })->get;
    $conn->query_value('SELECT length($1)', { type => 'BYTEA', value => 'defg' })->get;

    # The map is built at load time, so the only statements are the caller's.
    is scalar(@sql), 2,
        'two queries in, two statements out -- no lookup round trip, and the '
      . 'name is matched case-insensitively';

    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

subtest 'an unknown type name croaks and names the type' => sub {
    my $pg = pool();
    my $conn = $pg->connection->get;

    my $err = dies {
        $conn->query_value('SELECT $1', { type => 'no_such_type', value => 1 })->get
    };

    like "$err", qr/no_such_type/,
        'the message names the type the caller got wrong';

    ok lives { $conn->query_value('SELECT 42')->get },
        'and the connection is still usable';

    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

subtest 'a numeric type is passed through untouched' => sub {
    my @sql;
    my $pg = pool(on_query => sub { push @sql, $_[0]{sql} });
    my $conn = $pg->connection->get;

    @sql = ();
    my $n = $conn->query_value('SELECT length($1)',
        { type => PG_BYTEA, value => "ab\0cd" })->get;

    is $n, 5, 'the constant form still works, NUL and all';
    is scalar(@sql), 1, 'and adds no statement of its own';

    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};
```

- [ ] **Step 8: Run the whole file**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
prove -l t/integration/typed-binds.t
```

Expected: PASS, 5 subtests, no stray output.

- [ ] **Step 9: Document it**

`Async::DBD::Pg::Connection` already owns this topic at `=head3 Typed bind parameters`. Extend that section; add **nothing** to `Async::DBD::Pg`, which has no typed-bind POD and must not grow a duplicate one.

Do NOT insert a new `=head2` before `=head3 on_query` in `Pg.pm`. That `on_query` is a `=head3` inside the `=head2 new(%args)` run, so a `=head2` there would re-parent on_query, reconnect, and heal_dead_connections under the new heading in rendered docs.

In `lib/Async/DBD/Pg/Connection.pm`, inside the existing `=head3 Typed bind parameters`, insert this immediately after the paragraph ending "...familiar if you have used that." and before "A value that is a hashref without both keys is not a typed parameter". It is POD body text -- do not add new `=head` directives:

```pod
The type may also be given by name, which is what
L<Async::DBD::Pg::Results/types> reports and what an application that has
read C<pg_catalog> already holds:

    await $conn->query('INSERT INTO files (name, body) VALUES ($1, $2)',
        $name, { type => 'bytea', value => $bytes });

The names are DBD::Pg's own, its C<PG_*> constants lowercased with the
prefix dropped, so C<PG_BYTEA> is C<'bytea'>. Resolution happens against a
map built when the module loads and costs no round trip.

That set is exactly what DBD::Pg is able to bind. A type it does not know
-- a user-defined enum, a domain, an extension type -- croaks here, naming
the type. It cannot be bound by type at all: bind it untyped, or cast it in
SQL. This is no loss, because such a type does not need a typed bind; it is
text on the wire. The types that need one, C<bytea> above all, are exactly
the ones DBD::Pg knows.

Two names are worth knowing. C<'char'> is DBD::Pg's C<PG_CHAR>, PostgreSQL's
internal single-byte type -- SQL C<CHAR(n)> is C<'bpchar'>. And the map
includes pseudo-types such as C<'internal'> and C<'trigger'>, which resolve
but which DBD::Pg refuses to bind; nothing sensible binds them.

Numeric types are passed straight through, so C<:pg_types> constants keep
working and cost no lookup.
```

- [ ] **Step 10: Update llms.txt**

In `llms.txt`, replace the typed-values block under `## Placeholders`:

```
Binary and other typed values must say their type, or a NUL byte silently
truncates the value. The type may be a constant or a name:

    use DBD::Pg qw(:pg_types);
    await $pg->query('INSERT INTO f (body) VALUES ($1)',
        { type => PG_BYTEA, value => $bytes });
    await $pg->query('INSERT INTO f (body) VALUES ($1)',
        { type => 'bytea', value => $bytes });

Names are DBD::Pg's PG_* constants lowercased ('bytea', 'jsonb'), resolved
from a load-time map, so no round trip. A type DBD::Pg does not know (a user
enum, an extension type) croaks -- it cannot be bound by type at all, so bind
it untyped or cast in SQL. Note 'char' is PG_CHAR (1 byte); SQL CHAR(n) is
'bpchar'.
```

- [ ] **Step 11: Run the full suite and commit**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" prove -r -l t/
```

Expected: all pass, output pristine.

```bash
git add lib/Async/DBD/Pg.pm lib/Async/DBD/Pg/Connection.pm llms.txt t/integration/typed-binds.t
git commit -m "Accept a PostgreSQL type name where a bind wanted a constant"
```

- [ ] **Step 12: Mutation check**

Commit first (done above), then verify each load-bearing piece.

Mutation A -- make the resolver a no-op by changing the body of `_resolve_bind_types` to `return $bind;`. Expect the byte-identity subtest and the croak subtest to fail: with no resolution, a name reaches `bind_param` and DBD::Pg refuses it.

Mutation B -- drop the case folding by changing `$TYPE_OID{ lc $value->{type} }` to `$TYPE_OID{ $value->{type} }`. Expect only the case-insensitivity assertion in "resolving a name costs no query of its own" to fail, since `%TYPE_OID` is keyed lowercase.

Restore with `git checkout lib/Async/DBD/Pg/Connection.pm` after each -- safe now, because the work is committed. `Async::DBD::Pg` is not touched by this task, so it needs no restore.

---

### Task 2: map_rows

**Files:**
- Modify: `lib/Async/DBD/Pg/Results.pm`
- Modify: `llms.txt`
- Test: `t/unit/results.t`

**Interfaces:**
- Produces: `$results->map_rows($callback)` returns an `Async::DBD::Pg::Collection` of whatever `$callback` returned. The callback is called once per row as `$callback->($row_arrayref, $names_arrayref)`.
- Consumes: nothing from other tasks.

- [ ] **Step 1: Write the failing test**

Append to `t/unit/results.t`, before `done_testing`. The file already has a `results(...)` helper wrapping `new_from_data` -- use it, do not call the constructor directly.

```perl
subtest 'map_rows hands the callback the positional row and the names' => sub {
    my $r = results(
        rows    => [ [1, 'ada'], [2, 'grace'] ],
        columns => ['id', 'name'],
        types   => ['int4', 'text'],
    );

    my @seen;
    my $out = $r->map_rows(sub {
        my ($row, $names) = @_;
        push @seen, [ @$row ];
        return "$names->[0]=$row->[0] $names->[1]=$row->[1]";
    });

    is [@seen], [ [1, 'ada'], [2, 'grace'] ],
        'called once per row, in order, with the positional row';
    is [@$out], ['id=1 name=ada', 'id=2 name=grace'],
        'and collects what the callback returned';
    isa_ok $out, ['Async::DBD::Pg::Collection'], 'the return is a Collection';
};

subtest 'map_rows works where a hash view refuses' => sub {
    # Two columns named id is what ->rows croaks on. Positional access has
    # nothing to refuse, which is the case that justifies map_rows existing
    # rather than being map over ->rows.
    my $r = results(
        rows    => [ [1, 2] ],
        columns => ['id', 'id'],
        types   => ['int4', 'int4'],
    );

    ok dies { $r->rows }, 'the hash view croaks on the repeated name';

    my $out = $r->map_rows(sub { "$_[0][0]/$_[0][1]" });
    is [@$out], ['1/2'], 'map_rows returns both values';
};

subtest 'map_rows leaves the iterator position alone' => sub {
    my $r = results(
        rows    => [ [1], [2], [3] ],
        columns => ['id'],
        types   => ['int4'],
    );

    $r->next;                       # position now 1
    $r->map_rows(sub { $_[0][0] });
    my $after = $r->next;

    is $after->{id}, 2, 'hydration is not iteration';
};

subtest 'map_rows on an empty result returns an empty Collection' => sub {
    my $r = results(rows => [], columns => ['id'], types => ['int4']);

    my $called = 0;
    my $out = $r->map_rows(sub { $called++ });

    is $called, 0, 'the callback is never called';
    is $out->size, 0, 'and the Collection is empty';
};
```

- [ ] **Step 2: Run it and watch it fail**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/unit/results.t
```

Expected: FAIL, `Can't locate object method "map_rows"`.

- [ ] **Step 3: Implement**

In `lib/Async/DBD/Pg/Results.pm`, add immediately after `sub arrays` (which ends around line 143):

```perl
# Hydration. The callback receives the positional row and the shared column
# names, and its return values are collected.
#
# Positional, deliberately, and the only new way to walk rows this
# distribution offers. A hashref-passing version would be
# `map { ... } @{ $r->rows }` with the same allocations and the same croak --
# the map/grep/sort/reduce sugar the result-access design rejected on the
# grounds that the builtins are shorter. What positional access adds is what
# the builtins cannot do: build N objects without building N hashrefs on the
# way and throwing them away.
#
# Nothing here croaks on repeated column names, matching arrays, row_array
# and get_column by index. A caller reaching for positional access has
# already stepped around the problem a hash has.
#
# The iterator position is untouched, matching arrays rather than next:
# hydration is not iteration.
#
# The names arrayref is passed live rather than copied, as arrays hands out
# live rows. A callback that mutates it corrupts every later view.
sub map_rows {
    my ($self, $callback) = @_;

    croak 'map_rows requires a callback' unless ref $callback eq 'CODE';

    my $names = $self->{_names};

    return Async::DBD::Pg::Collection->new(
        map { $callback->($_, $names) } @{ $self->{_rows} }
    );
}
```

- [ ] **Step 4: Run the tests**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && prove -l t/unit/results.t
```

Expected: PASS.

- [ ] **Step 5: Document it**

In `lib/Async/DBD/Pg/Results.pm`, find the POD section for `=head2 arrays` and add after it:

```pod
=head2 map_rows

    my $users = $results->map_rows(sub {
        my ($row, $names) = @_;
        My::User->new(id => $row->[0], name => $row->[1]);
    });

Calls the callback once per row with the row as an arrayref and the column
names as a second arrayref, and returns a
L<Async::DBD::Pg::Collection> of whatever the callback returned.

Positional, which is the point: building objects this way never materialises
the intermediate hashrefs that C<map { ... } @{ $results-E<gt>rows }> would,
and it works on a result with repeated column names, where the hash views
croak.

The iterator position is not touched, so this composes with C<next>. The
names arrayref is the result's own, not a copy -- a callback that modifies it
corrupts every later view, exactly as writing through C<arrays> does.

For hashrefs, no new method is needed: C<map { ... } @{ $results-E<gt>rows }>
already works, and still croaks if a column name repeats.
```

- [ ] **Step 6: Update llms.txt**

In `llms.txt`, in the Results block, add after the `$r->preview` line:

```
    $r->map_rows(sub { my ($row, $names) = @_; ... })  # Collection, positional
```

- [ ] **Step 7: Run the full suite and commit**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" prove -r -l t/
```

```bash
git add lib/Async/DBD/Pg/Results.pm llms.txt t/unit/results.t
git commit -m "Add map_rows, a positional hydration hook"
```

- [ ] **Step 8: Mutation check**

Commit first (done above). Swap the callback's arguments: change `map { $callback->($_, $names) }` to `map { $callback->($names, $_) }`. Expect the first subtest to fail on both the `@seen` and the returned-values assertions, and the second to fail too. Restore with `git checkout lib/Async/DBD/Pg/Results.pm`.

---

### Task 3: Violation predicates, and pinning the diagnostics capture

**Files:**
- Modify: `lib/Async/DBD/Pg/Error.pm`
- Modify: `lib/Async/DBD/Pg/Connection.pm` (comment only)
- Test: `t/integration/error-diagnostics.t` (create)

**Interfaces:**
- Produces: `$err->is_unique_violation`, `$err->is_foreign_key_violation`, `$err->is_not_null_violation` -- each returns 1 or 0, on `Async::DBD::Pg::Error::Query`.
- Consumes: nothing from other tasks.

**Read before starting:** `Async::DBD::Pg::Error` already defines `%STATE_MAP` with `23505 => unique_violation`, `23503 => foreign_key_violation`, `23502 => not_null_violation`, and `state_name` returns those. `Async::DBD::Pg::Error::Query` already exposes `constraint`, `table`, `schema`, `column`, `detail`, `hint`, `severity`, `context`, `position`. Do **not** rename those accessors and do **not** add `_name` aliases.

- [ ] **Step 1: Write the failing test**

Create `t/integration/error-diagnostics.t`:

```perl
use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

use lib 't/lib';
use Test::Async::DBD::Pg qw(skip_without_postgres test_dsn);

my $dsn = skip_without_postgres();

use Future::IO;
BEGIN { Future::IO->load_best_impl; }

use Async::DBD::Pg;

# Driven by real violations rather than constructed errors, because the point
# is that the server's diagnostics reach the caller, not that a hash holds
# what was put in it.
sub with_table {
    my ($cache, $code) = @_;

    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 1,
        statement_cache_size => $cache,
    );
    my $conn = $pg->connection->get;

    $conn->query('SET client_min_messages = warning')->get;
    $conn->query('DROP TABLE IF EXISTS diag_child')->get;
    $conn->query('DROP TABLE IF EXISTS diag_parent')->get;
    $conn->query('CREATE TABLE diag_parent (
        id int PRIMARY KEY,
        email text CONSTRAINT diag_parent_email_key UNIQUE,
        qty int NOT NULL
    )')->get;
    $conn->query('CREATE TABLE diag_child (
        id int PRIMARY KEY,
        parent_id int CONSTRAINT diag_child_parent_fk REFERENCES diag_parent(id)
    )')->get;
    $conn->query('INSERT INTO diag_parent VALUES ($1,$2,$3)', 1, 'a@b.c', 1)->get;

    $code->($conn);

    $conn->query('DROP TABLE diag_child')->get;
    $conn->query('DROP TABLE diag_parent')->get;
    $conn->release;
    $pg->shutdown(timeout => 5)->get;
}

subtest 'each predicate is true only for its own violation' => sub {
    with_table(0, sub {
        my ($conn) = @_;

        my $unique = dies {
            $conn->query('INSERT INTO diag_parent VALUES ($1,$2,$3)', 2, 'a@b.c', 1)->get
        };
        ok $unique->is_unique_violation, 'unique: is_unique_violation';
        ok !$unique->is_foreign_key_violation, 'unique: not foreign key';
        ok !$unique->is_not_null_violation, 'unique: not null violation is false';
        ok !$unique->is_retryable, 'unique: not retryable';
        is $unique->constraint, 'diag_parent_email_key', 'unique: names the constraint';

        my $notnull = dies {
            $conn->query('INSERT INTO diag_parent VALUES ($1,$2,$3)', 3, 'x@y.z', undef)->get
        };
        ok $notnull->is_not_null_violation, 'not null: is_not_null_violation';
        ok !$notnull->is_unique_violation, 'not null: not unique';
        is $notnull->column, 'qty', 'not null: names the column';

        my $fk = dies {
            $conn->query('INSERT INTO diag_child VALUES ($1,$2)', 1, 999)->get
        };
        ok $fk->is_foreign_key_violation, 'fk: is_foreign_key_violation';
        ok !$fk->is_unique_violation, 'fk: not unique';
        is $fk->constraint, 'diag_child_parent_fk', 'fk: names the constraint';
    });
};

subtest 'diagnostics survive with the statement cache on' => sub {
    # The cache is the configuration whose eviction sends DEALLOCATE, which
    # pg_error_field documents as resetting every field. It survives because
    # the statement handle outlives the capture; this asserts that it does.
    with_table(10, sub {
        my ($conn) = @_;

        my $err = dies {
            $conn->query('INSERT INTO diag_parent VALUES ($1,$2,$3)', 2, 'a@b.c', 1)->get
        };

        ok $err->is_unique_violation, 'still classified with the cache on';
        is $err->constraint, 'diag_parent_email_key', 'constraint survives';
        is $err->table, 'diag_parent', 'table survives';
        like $err->detail, qr/already exists/, 'detail survives';
    });
};

done_testing;
```

- [ ] **Step 2: Run it and watch it fail**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
prove -l t/integration/error-diagnostics.t
```

Expected: FAIL, `Can't locate object method "is_unique_violation"`.

- [ ] **Step 3: Implement the predicates**

In `lib/Async/DBD/Pg/Error.pm`, in the `Async::DBD::Pg::Error::Query` package, add immediately after `sub is_retryable`:

```perl
# The three integrity violations a caller routinely branches on, named so the
# branch reads as the domain rather than as a five-character code. Answered
# from the same SQLSTATE the rest of this class is answered from.
#
# Deliberately not a generic ->is($name): that would be a second spelling of
# state_name, which already exists and already covers every code in the map.
sub is_unique_violation      { $_[0]->_state_is('23505') }
sub is_foreign_key_violation { $_[0]->_state_is('23503') }
sub is_not_null_violation    { $_[0]->_state_is('23502') }

sub _state_is {
    my ($self, $code) = @_;
    return ( ($self->{code} // '') eq $code ) ? 1 : 0;
}
```

- [ ] **Step 4: Run the tests**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
prove -l t/integration/error-diagnostics.t
```

Expected: PASS.

- [ ] **Step 5: Record why the capture ordering is safe**

In `lib/Async/DBD/Pg/Connection.pm`, both places that read `$statement->release;` immediately followed by `$self->_throw_query_error($err, $sql);` (in `_execute_once`, one after `execute` and one after `pg_result`), add this comment directly above the `$statement->release;` line:

```perl
        # release evicts the cached entry, and dropping the last reference to
        # a statement handle sends DEALLOCATE -- a statement on this
        # connection, which is what pg_error_field documents as resetting
        # every diagnostic field. _throw_query_error reads those fields on the
        # next line and still gets them, because the $sth lexical above holds
        # the handle until this frame unwinds. Anything that drops that
        # reference earlier, or moves the capture later, silently empties
        # every diagnostic on Error::Query.
```

- [ ] **Step 6: Document the predicates**

In `lib/Async/DBD/Pg/Error.pm`, find the POD `=head2 is_retryable` and add this immediately before it:

```pod
=head2 is_unique_violation, is_foreign_key_violation, is_not_null_violation

    if ($err->is_unique_violation) {
        my $which = $err->constraint;   # 'users_email_key'
    }

True for SQLSTATE C<23505>, C<23503> and C<23502> respectively, false
otherwise.

For a unique violation, PostgreSQL reports C<constraint> but leaves C<column>
undef -- it names the index that was violated, not the columns in it, so
mapping a unique violation back to a field is done through the constraint
name. C<column> is populated for NOT NULL and check violations, where a
single column is at fault.

These are the three worth naming. Every other code is available through
C<state> and C<state_name>.
```

- [ ] **Step 7: Run the full suite and commit**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" prove -r -l t/
```

```bash
git add lib/Async/DBD/Pg/Error.pm lib/Async/DBD/Pg/Connection.pm t/integration/error-diagnostics.t
git commit -m "Name the three integrity violations a caller branches on"
```

- [ ] **Step 8: Mutation check**

Commit first (done above). Change `is_unique_violation` to compare against `'23503'`. Expect the first subtest to fail on both the unique and the fk assertions. Restore with `git checkout lib/Async/DBD/Pg/Error.pm`.

---

### Task 4: Server version and connection identity

**Files:**
- Modify: `lib/Async/DBD/Pg.pm`
- Modify: `lib/Async/DBD/Pg/Connection.pm`
- Modify: `llms.txt`
- Test: `t/integration/connection.t`

**Interfaces:**
- Produces: `$conn->id` -- integer, unique within the pool, stable for the connection's life.
- Produces: `$conn->server_version` and `$pg->server_version` -- the integer PostgreSQL reports, e.g. 160014.
- Produces: `on_query` events gain a `connection` key holding `$conn->id`.
- Consumes: nothing from other tasks.

- [ ] **Step 1: Write the failing test**

Append to `t/integration/connection.t`, before `done_testing`. Follow the file's existing helper for building a pool.

```perl
subtest 'server_version is the integer PostgreSQL reports' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 1);
    my $conn = $pg->connection->get;

    my $v = $conn->server_version;

    like $v, qr/\A[0-9]+\z/, 'an integer, not a string to be parsed';
    ok $v >= 90000, "and a plausible server version ($v)";
    is $pg->server_version, $v, 'the pool reports the same';

    $conn->release;
    $pg->shutdown(timeout => 5)->get;
};

subtest 'on_query attributes each statement to its connection' => sub {
    my @events;
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 2,
        on_query => sub { push @events, $_[0] },
    );

    my $a = $pg->connection->get;
    my $b = $pg->connection->get;

    ok $a->id, 'a connection has an id';
    isnt $a->id, $b->id, 'and two connections differ';

    @events = ();
    $a->query_value('SELECT 1')->get;
    $a->query_value('SELECT 2')->get;
    $b->query_value('SELECT 3')->get;

    is [ map { $_->{connection} } @events ], [ $a->id, $a->id, $b->id ],
        'every event names the connection that ran the statement';

    $a->release;
    $b->release;
    $pg->shutdown(timeout => 5)->get;
};
```

- [ ] **Step 2: Run it and watch it fail**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
prove -l t/integration/connection.t
```

Expected: FAIL, `Can't locate object method "server_version"`.

- [ ] **Step 3: Give the Connection an id and a version**

In `lib/Async/DBD/Pg/Connection.pm`, add `id => $args{id},` to the blessed hash in `sub new`, directly after the `pool => $args{pool},` line.

Add to the accessor block after `sub is_released`:

```perl
sub id { shift->{id} }

# PostgreSQL's own integer form -- 160014 for 16.0.14 -- because every use is
# a comparison, such as >= 150000 to choose MERGE over ON CONFLICT. Rendering
# it as a string only for callers to parse it back would help nobody.
sub server_version {
    my ($self) = @_;
    my $dbh = $self->{dbh} or return undef;
    return $dbh->{pg_server_version};
}
```

- [ ] **Step 4: Assign ids from the pool and expose the version**

In `lib/Async/DBD/Pg.pm`, in `sub new`, add to the blessed hash directly after `_connecting => 0,`:

```perl
        # Monotonic, never reused. A refaddr would be: Perl reuses an address
        # after collection, so two connections could report the same one over
        # a pool's life and any attribution built on it would merge them.
        _next_connection_id => 1,
```

In `_create_connection`, in the `Async::DBD::Pg::Connection->new(...)` call, add:

```perl
        id          => $self->{_next_connection_id}++,
```

Add the pool accessor next to `sub safe_dsn`:

```perl
# The version of the server this pool is connected to, in PostgreSQL's integer
# form. Read from any live connection, since a pool addresses one database.
sub server_version {
    my ($self) = @_;

    for my $conn (@{ $self->{idle} }, @{ $self->{active} }) {
        my $v = $conn->server_version;
        return $v if defined $v;
    }

    return undef;
}
```

- [ ] **Step 5: Put the id in the event**

In `lib/Async/DBD/Pg/Connection.pm`, in `_report_query`, add to the hashref passed to `$hook->`:

```perl
            connection => $self->{id},
```

- [ ] **Step 6: Run the tests**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
prove -l t/integration/connection.t
```

Expected: PASS.

- [ ] **Step 7: Document it**

In `lib/Async/DBD/Pg.pm`, add to the `on_query` POD list, after the `cached` item:

```pod
=item * C<connection> -- the id of the connection that ran it, so statements
can be attributed to a connection across a pool

```

Add a POD section next to `=head2 stats`:

```pod
=head2 server_version

    if ($pg->server_version >= 150000) { ... }

The version of the server this pool is connected to, in PostgreSQL's own
integer form -- C<160014> for 16.0.14. A number rather than a string because
every use is a comparison, typically to gate a feature such as C<MERGE>.

Returns undef if the pool has no connection yet.
```

In `lib/Async/DBD/Pg/Connection.pm`, add POD near the other accessors:

```pod
=head2 id

An integer identifying this connection within its pool, assigned when the
connection is created and never reused. Reported as C<connection> on every
L<Async::DBD::Pg/on_query> event.

=head2 server_version

The version of the server this connection is attached to, in PostgreSQL's
integer form -- C<160014> for 16.0.14.
```

- [ ] **Step 8: Update llms.txt**

In `llms.txt`, update the `on_query` line and the Connection block:

```
    $pg->on_query(sub { my ($e) = @_ })  # {sql, binds, elapsed, rows, error, cached, connection}
    $pg->server_version                  # 160014, integer, for feature gating
```

and add to the Connection block:

```
    $conn->id  $conn->server_version
```

- [ ] **Step 9: Run the full suite and commit**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" prove -r -l t/
```

```bash
git add lib/Async/DBD/Pg.pm lib/Async/DBD/Pg/Connection.pm llms.txt t/integration/connection.t
git commit -m "Expose the server version and give each connection an id"
```

- [ ] **Step 10: Mutation check**

Commit first (done above). Change `id => $self->{_next_connection_id}++,` to `id => 1,`. Expect the `isnt $a->id, $b->id` assertion and the event-attribution assertion to fail. Restore with `git checkout lib/Async/DBD/Pg.pm`.

---

## Flagged deviation from the spec

**D1 -- spec test 3 cannot be written as specified.**

The spec asks for a test that reds if the diagnostics capture moves after
`$statement->release`. No such test can exist today: the capture already runs
after that release and the diagnostics survive, because the `$sth` lexical in
`_execute_once` holds the handle until the frame unwinds. Both orderings
produce identical behaviour, so no behavioural test distinguishes them.

Task 3 delivers what is achievable instead: a test that the diagnostics
survive with the statement cache **on** (the configuration whose eviction
sends `DEALLOCATE`), and a comment at both release sites recording the
requirement and what would break it.

Restructuring `_execute_once` to capture before releasing would make the
ordering structural rather than incidental, but it is three lines that no
test can hold in place, which is why it is not in the plan.

**RESOLVED.** John signed off on the comment-only approach: the test plus the
comment, no restructure. The residual risk is accepted and recorded here --
if a future edit moves the capture past the handle's destruction, the
diagnostics come back empty rather than wrong, and empty reads as "this error
carried no detail", which is a plausible thing for an error to be. The comment
at both release sites is what a reader has to go on.

## Verification

After all four tasks:

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" prove -r -l t/
```

Expected: all pass, output pristine -- no warnings, no NOTICEs, no stray
prints. Then confirm the POD is ASCII and valid:

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
podchecker lib/Async/DBD/Pg.pm lib/Async/DBD/Pg/*.pm && \
LC_ALL=C grep -n '[^[:print:][:space:]]' lib/Async/DBD/Pg.pm lib/Async/DBD/Pg/*.pm
```

Expected: `pod syntax OK` for each, and no output from grep.

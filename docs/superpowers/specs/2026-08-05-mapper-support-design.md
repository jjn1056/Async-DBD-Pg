# Mapper support: error predicates, hydration, binds by type name

Four changes a schema mapper needs from this driver. Three of them are
general-purpose and would be wanted by any application; one, `map_rows`, is a
hydration primitive whose justification rests entirely on the positional row
storage this distribution already has.

## Measured before writing this

DBD::Pg 3.20.2 against PostgreSQL 16, so the design argues from what the stack
does rather than from what it ought to.

- **The error diagnostics are already captured.** `_throw_query_error` reads
  every `pg_error_field` on the list and `Error::Query` already exposes
  `constraint`, `table`, `schema`, `column`, `detail`, `hint`, `severity`,
  `context`, `position` and `state`. `state_name` already returns
  `unique_violation` and `not_null_violation` from a map that also covers
  foreign key, check, exclusion, and the rest.

- **They survive the async path**, where the error surfaces at `pg_result`
  rather than at `execute`:

        unique:  state=23505  constraint='diag_probe_email_key'
                 table='diag_probe'  column=undef
                 detail='Key (email)=(a@b.c) already exists.'
        notnull: state=23502  constraint=undef  column='qty'

  `column` is undef for a unique violation and populated for NOT NULL, exactly
  as PostgreSQL documents. Unique mapping therefore keys off `constraint`,
  which is why constraint naming conventions matter to a mapper.

- **The statement cache does not clobber them**, though the call order looks
  like it should. `_execute_once` calls `$statement->release` *before*
  `_throw_query_error`, and release evicts the cached handle -- whose
  destruction sends `DEALLOCATE`, precisely the kind of statement
  `pg_error_field` documents as resetting everything. It survives because the
  local `$sth` lexical in `_execute_once` still holds a reference, so the
  handle is not destroyed until the frame unwinds, after the capture. That is
  correct by accident, not by design. See change 1.

- **The `PG_*` constants are the catalog OIDs.** `PG_BYTEA` is 17, `PG_JSONB`
  3802, `PG_TIMESTAMPTZ` 1184, `PG_TEXT` 25, and `pg_type` gives the same
  numbers for the same names. A stock database has **629** entries in
  `pg_type`. Any hardcoded table covers the built-ins and misses every
  extension type, enum and user-defined type.

- **`pg_server_version` is an integer**, 160014 on this server, not a string.

## 1. Predicates on Error::Query

Nearly built. What is missing is the vocabulary the retry feature and a
changeset's `unique_constraint('email')` mapping both speak:

    $err->is_unique_violation        # 23505
    $err->is_foreign_key_violation   # 23503
    $err->is_not_null_violation      # 23502

Each is a lookup against the code, alongside the existing `is_retryable`.
`%STATE_MAP` already holds every one of these, so a predicate is a comparison
and not a new table.

**The accessors keep their current names.** `constraint`, `table`, `schema`,
`column` are shipped and documented. Renaming them to `constraint_name` and
friends breaks callers; adding those as aliases leaves two names for one
thing, which is worse than either.

**Pin the capture ordering.** The diagnostics survive only because a lexical
happens to keep the statement handle alive past the capture. A comment at
`$statement->release` stating that `_throw_query_error` must read
`pg_error_field` before the handle is destroyed, plus a test that fails if the
capture moves after the release, converts an accident into an invariant. This
is the third time this distribution has had to grab something before it is
gone -- `pg_type`, `elapsed`, and now the error fields -- and it is the same
argument each time.

## 2. map_rows

    my $users = $r->map_rows(sub {
        my ($row, $names) = @_;
        My::User->new(id => $row->[0], name => $row->[1]);
    });

The callback receives the **positional** row arrayref and the shared column
name arrayref. It returns a `Collection` of whatever the callback returned.

**Positional only, deliberately.** A hashref-passing `map_rows` would be
`map { ... } @{ $r->rows }` with the same allocations and the same croak --
which is the `map`/`grep`/`sort`/`reduce` sugar the result-access spec
explicitly rejected on the grounds that the builtins are shorter and a
`Collection` is already an arrayref. Reversing that for no measurable gain is
not worth a logged deviation. What positional access adds is the thing the
builtins genuinely cannot do: hydrate N objects without materialising N
throwaway hashrefs on the way. That is what positional storage was built for,
and it is the only part of this that earns new API.

Consequences, all consistent with the existing positional methods:

- **It never croaks on repeated column names.** `arrays`, `row_array`,
  `preview` and `get_column` by index do not either. A caller reaching for
  positional access has already stepped around the problem a hash has.
- **It does not touch the iterator position**, matching `arrays` rather than
  `next`/`all`. Hydration is not iteration.
- **The name arrayref is passed, not copied.** A callback that mutates it
  corrupts the result, the same way `arrays` already hands out live internals.
  Documented, as that one is.

Applications wanting hashes need nothing new: `map { ... } @{ $r->rows }`
already works and still croaks on duplicates.

## 3. Binds by type name

    await $pg->query($sql, { type => 'bytea', value => $bytes });

Today `type` must be a `PG_*` constant, so a mapper that has introspected
`pg_catalog` and knows every column's type *as a name* has to translate before
it can bind. `types()` already reports names, so accepting them closes the
loop and lets the mapper auto-type every bind it generates without importing
`:pg_types` at all.

**Resolved from `pg_type`, not a hardcoded table.** The constants are the
catalog OIDs, so the catalog is both the authoritative and the complete
source, covering the 600-plus types a hardcoded map would miss -- extension
types, enums, and anything the application defined itself. The mapper is
reading `pg_catalog` anyway.

**Loaded lazily, cached on the pool.** One `SELECT typname, oid FROM pg_type`
the first time a bind names a type. Nothing is paid by anyone who never uses
the feature, and a pool addresses one database, so one map serves every
connection in it. Restricted to the `pg_catalog` namespace, since `typname` is
not unique across schemas.

**An implementation constraint that decides the shape.** The bind loop runs
inside a synchronous closure passed to `_capture_pg_notices`, inside an
`eval`, with no await available. The map therefore cannot be loaded from
inside it. `_execute_once` must scan the binds for named types and await the
map *before* entering that block -- a scan that costs nothing when no bind
names a type, which is the common case.

**Numeric types keep working.** A `type` that is already a number is passed
through untouched, so every existing caller is unaffected and `:pg_types`
remains a supported spelling.

**An unknown type name croaks**, naming the type and listing nothing. Falling
through to an untyped bind is how a bytea gets truncated at its first NUL with
the write reporting success, which is the failure this whole area exists to
prevent. Lossless or loud.

## 4. Two small additions

**Server version**, on both pool and connection, as the integer PostgreSQL
reports:

    $pg->server_version      # 160014

Exposed as a number because every use is a comparison -- `>= 150000` to choose
`MERGE` over `ON CONFLICT`, and so on. Formatting it into a string only for
callers to parse it back would help nobody.

**A connection identifier in the `on_query` event**, so a caller can attribute
statements to the connection that ran them:

    { sql => ..., binds => ..., elapsed => ..., rows => ...,
      error => ..., cached => ..., connection => 7 }

A **monotonic per-pool counter** assigned at construction, not `refaddr`. A
refaddr is reused after collection, so over a pool's lifetime two different
connections can report the same one and any attribution built on it silently
merges them.

## Order of work

Not the order the mapper consumes them, because change 1 is nearly finished:

1. **Binds by type name** -- the true prerequisite. The mapper cannot emit a
   single correct bind without it.
2. **map_rows** -- hydration, once there is something to hydrate from.
3. **Predicates** -- three one-liners, and the ordering test that pins the
   diagnostics capture. Can land at any point.
4. **Server version and connection id** -- independent of everything.

## Tests

1. Each predicate is true for its own SQLSTATE and false for the others,
   driven by a real violation rather than a constructed error.
2. Diagnostics survive with the statement cache **on**, which is the
   configuration whose eviction sends `DEALLOCATE`.
3. Moving the capture after `$statement->release` reds a test. This is the
   mutation that matters: without it the invariant is only a comment.
4. `map_rows` receives the positional row and the names, in order, and returns
   a `Collection` of the callback's values.
5. `map_rows` works on a result with repeated column names, where `rows`
   croaks -- the case that justifies it being positional.
6. `map_rows` leaves the iterator position untouched.
7. A bind naming a type produces the same bytes as the same bind using the
   constant. Round-tripped through `bytea` with an embedded NUL, since a
   silently truncated write is the failure being prevented.
8. A named type resolves for a type absent from any hardcoded list -- an enum
   created by the test -- which is what distinguishes the catalog from a
   table.
9. The catalog is read at most once per pool, asserted by counting queries
   through `on_query`, and not at all when no bind names a type.
10. An unknown type name croaks and names the type.
11. `server_version` is an integer and matches the server.
12. `on_query` reports a stable connection identifier: two statements on one
    connection agree, two connections differ.

## Out of scope

**Auto-encoding a reference bound to a jsonb column.** Decoding, which
`expand` already does, is unambiguous; encoding is not. It would commit this
distribution to an encoder, an ordering, and an answer for booleans, blessed
objects, and scalars that are ambiguously numeric or string -- the standing
traps of Perl JSON. It would also silently accept a reference passed by
mistake, where a type error today says so. `expand` is opt-in on the way out;
this would be implicit on the way in, which only looks symmetric.

**Renaming the diagnostic accessors** -- see change 1.

**A hashref-passing `map_rows`** -- see change 2.

**Schema-qualified type names.** The catalog map covers `pg_catalog`. A type
in another namespace can still be bound by OID.

## Risk

Change 3 touches the bind path of every query, which is the hot path of
everything, and its scan for named types runs whether or not the feature is
used. That scan must be a `ref eq 'HASH'` test over binds that are already
being walked one at a time, not a second pass.

Change 1's ordering test is the one that protects an invariant currently held
by a lexical's lifetime. If a future edit moves the capture, no other test in
the suite would notice, because the diagnostics would come back empty rather
than wrong -- and empty reads as "this error had no detail", which is a
plausible thing for an error to be.

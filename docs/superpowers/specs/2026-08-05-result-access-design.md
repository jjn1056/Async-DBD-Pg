# Result access design

**Goal:** make getting at query results as direct as the competition's, and
stop losing data when a query's column names repeat.

## Two problems, one cause

`Results` stores what `fetchall_arrayref({})` gives it: an array of hashrefs.
Everything else follows from that.

**A hash cannot hold repeated keys.** Measured on the current code:

    SQL selected 4 columns: id, id, name, name
    the row has 2 keys:     id, name

A self-join, or any `SELECT *` across a join, silently drops columns. The query
succeeds and the data is gone. That is the same class as the `bytea` truncation
fixed in item 51 -- not a missing convenience, a wrong answer.

**Column metadata is discarded.** DBI offers it on the statement handle:

    NAME:      id, name, price, ok, made
    TYPE:      4, -1, 2, 16, 91
    PRECISION: 4, undef, 8, 1, 4
    NULLABLE:  1, 1, 1, 1, 1
    pg_type:   int4, text, numeric, bool, date

`Results::new` keeps `NAME` and calls `finish`. Everything else is
unrecoverable afterwards. Anything generic over a result -- a CSV writer, a
serialiser, an agent reasoning about what came back -- needs types and cannot
obtain them at any price.

Both are fixed by fetching positionally and keeping the metadata.

## Placeholders

The converter's output is not the SQL PostgreSQL receives. `$dbh->prepare`
runs DBD::Pg's own placeholder scanner over it a second time, and no code in
the distribution sets the attributes that govern that scan -- there is exactly
one `prepare` in the dist, at `Connection.pm:279`, carrying only `pg_async`.
So there are two scanners, and each has defects. **This is invisible to unit
tests by construction:** a unit test of `convert_placeholders` asserts what our
scanner emits, and is structurally incapable of seeing what the driver then
does to it.

That is not hypothetical. The rejection paragraph above previously cited
`t/unit/placeholders.t` as covering `arr[:2]`. It does cover it -- it asserts
the converter passes it through untouched, which is correct -- and the
statement still dies one layer down, inside DBD::Pg, at execute. Coverage of
the first scanner vouched for nothing about the second.

### The driver's scan: `pg_placeholder_dollaronly`

Measured against live PostgreSQL 16 with DBD::Pg 3.18.0:

    SELECT '{"a":1}'::jsonb ? 'a'          -- execute called with an unbound placeholder
    ... the same with a $1 bind elsewhere  -- Cannot mix placeholder styles "?" and "$1"
    SELECT arr[:2]                         -- unbound placeholder, despite a correct conversion

Every jsonb `?`, `?|` and `?&` operator is unusable, in positional and named
mode alike. `arr[1:3]`, dollar-quoted strings and comments are handled
correctly by the driver's scanner; those two are the live failures.

**Fix:** set `pg_placeholder_dollaronly => 1` in the prepare attributes. One
call site, and the sweep confirms there are no others.

This costs nothing that was promised. The POD documents exactly two placeholder
forms, `$1` and `:name`; `?` was never one of them. It should be documented as
a feature rather than a workaround -- **`?` is never a placeholder in this
library**, so PostgreSQL's jsonb operators work unescaped, which a DBI-layer
library that leaves the driver's scanner on cannot say.

Typed binds go through `bind_param` with `pg_type`, which is a different
mechanism, so `dollaronly` is expected not to disturb them. Expected is not
verified: a `PG_BYTEA` round trip pins it.

### Our scan: the converter's holes

Reproduced by calling `convert_placeholders` directly. All of these carry a
real `:a` elsewhere in the statement that should convert and bind:

    SELECT $$:id$$ AS x, :a                 died: No value supplied for placeholder ':id'
    SELECT $q$:id$q$ AS x, :a               died: same
    SELECT $q1$:id$q1$, :a                  died: same
    SELECT 1 -- :note\n, :a                 died: No value supplied for placeholder ':note'
    SELECT 1 /* :note */, :a                died: same
    SELECT 1 /* a /* b */ :note */, :a      died: same
    SELECT :a -- :note                      died: same
    SELECT E'it\'s ok', :a                  RETURNED SUCCESSFULLY, :a unconverted, bind []

The dies are spurious but loud, and they break `DO` blocks and function bodies
under named binds. The last one is the serious case: the scanner misreads the
E-string's boundary, returns a statement still containing `:a`, and hands back
an empty bind list. It is the silent-wrong-answer class this whole design
exists to remove, and it compounds -- `Connection::query`'s "converted equals
original and no named binds" test then reclassifies the params hashref as a
single positional bind value.

**Fix the scanner** to pass these through without placeholder interpretation:

- line comments, `--` to end of line, including when the statement ends there
- block comments, `/* ... */`, which **nest** in PostgreSQL: `/* a /* b */ c */`
  is one comment, so this needs a depth counter, not a match on the first `*/`
- dollar-quoted strings, `$$...$$` and `$tag$...$tag$`, where the tag is
  identifier characters and only the *matching* tag closes it
- backslash escapes inside `E'...'` strings **only**, case-insensitive on the
  `E`

That last restriction is load-bearing and easy to over-apply. In a standard
`'...'` string a quote is escaped only by doubling and a backslash is an
ordinary character. `SELECT 'a\', :a` converts correctly today, and a fix that
treats backslash as an escape everywhere would break it. It is a regression
guard, not an edge case.

The identifier-bound slice limitation -- `arr[lo:hi]` dies in named mode -- is
documented POD behaviour and stays.

## The principle

**Positional storage is the truth. Every derived view either represents that
truth losslessly or refuses loudly.** No view may silently drop, collapse, or
invent data.

Refusals are `croak`, never `warn`. A warning scrolls past in production and
the caller proceeds with half their data, which is the failure this design
exists to remove. The one deliberate exception is the `single` / `single_value`
pair, which warn: those report an expectation mismatch about row *count*, not
data loss, and the value returned is complete and correct.

## Storage

    my $names = $sth->{NAME} ? [ @{ $sth->{NAME} } ] : [];
    my $rows  = @$names ? ( $sth->fetchall_arrayref // [] ) : [];
    my $types = $sth->{pg_type} ? [ @{ $sth->{pg_type} } ] : [];

Two constraints found by building it, neither obvious from reading:

**Fetch before reading metadata.** On an async statement handle, touching
`NAME` or `pg_type` first leaves it with `no statement executing` and the fetch
fails. The current code has this order already; it is not incidental.

**Guard non-row statements.** `fetchall_arrayref({})` quietly returns nothing
for an `INSERT` or `CREATE`; the positional form *dies* with `no statement
executing`. An empty `NAME` is what distinguishes them.

Duplicate names are detected once, at construction, by a single pass over
`NAME` -- a flag plus the positions of each repeated name. Nothing croaks at
construction: `arrays` consumers must neither pay for the check twice nor trip
over a problem they do not have. The croak fires lazily, when a hash is about
to be built.

Measured, 20,000 rows x 4 columns:

    fetchall_arrayref({})  -- current      0.050s
    fetchall_arrayref()    -- positional   0.025s
    positional + derive hashes             0.041s

Positional storage is **faster than what we do now**, even after deriving the
hashes that `rows` returns. The fix costs nothing.

## API

### Results: the core

    $r->rows            Collection of hashrefs, derived on demand
    $r->arrays          Collection of arrayrefs, positional
    $r->columns         column names, in order, duplicates intact
    $r->types           PostgreSQL type names: int4, text, numeric
    $r->count  $r->rows_affected  $r->is_empty  $r->elapsed

    $r->first           first row, or undef -- takes what is there
    $r->single          first row, warns if more than one matched
    $r->single_value    first column of the first row, warns if more matched
    $r->row_array($i)   one row, positional

    $r->next  $r->reset  $r->all
    $r->get_column($name_or_index)

`first` versus `single` is the scheme: *take what is there* against *I expected
one, tell me if I was wrong*. It applies to rows and to values alike, which is
why the value getter is `single_value` and not `scalar`. `scalar` named a Perl
context rather than the thing being returned.

**Every path that builds a plain hashref croaks on duplicate column names.**
On `Results` that is `rows`, `first`, `single`, `next`, `all`, `by` and
`groups`; on `Cursor` it is `next`, `each` and `all`, which build their batches
through `Results`. `Collection::each` needs no rule of its own -- by the time a
Collection exists the hashrefs are already built, so the croak has fired.

    Column 'id' appears 2 times at positions 0, 1;
    alias the columns in your SQL, or use ->arrays or ->as

Three groups of methods keep working on that same result. The positional and
metadata views -- `arrays`, `columns`, `types`, `count`, `rows_affected`,
`is_empty`, `row_array`, `elapsed`, `preview`. The renaming view `as`, which is
the fix. And **`multi`, which is explicitly exempt**: a `Hash::MultiValue` row
holds every value of a repeated name, so it represents the result losslessly
and has nothing to refuse. `multi` is the one name-addressable path that a
duplicate-column result supports without renaming, which is its reason to
exist.

### Views

A view is a new Results-like object sharing the original's row arrayref -- no
copy of row data -- with something swapped. Three exist. Each carries **its own
iterator position, starting at 0**, so iterating a view never moves the
original's `next` cursor and vice versa. That is what makes `as` on a
half-iterated result well-defined rather than a mutation.

**`$r->as(...)` -- rename columns.**

    my $v = $r->as(['seller_id', 'buyer_id', 'name']);     # full positional
    my $v = $r->as({ 0 => 'seller_id', 1 => 'buyer_id' }); # sparse, by index

The names array is swapped; `types` stay aligned by position. `$v->columns`
returns the renamed names in order, because introspection on a view must
describe what that view's accessors return. `$r->columns` on the original still
returns the raw names, duplicates intact. `$v->rows`, `$v->first`,
`$v->single`, `$v->get_column('seller_id')`, `$v->multi`, `$v->by` all operate
under the new names.

Renaming is by index, never by current name: the case that needs renaming is
exactly the case where names do not identify a column. Three croaks --
list length not equal to the column count, an index out of range, and a rename
whose result still contains duplicates.

**`$r->multi` -- name-addressable and lossless.** A Collection of
`Hash::MultiValue` objects, one per row, built from the view's names. This is
what a generic consumer uses when it must address by name and cannot alias.

`require`d at call time; missing, it dies with an install hint. Optional
dependency, not a prereq. Derived on every call, never cached, and the POD says
so plainly: N objects per call, measured at 2.8x the plain fetch when this was
tried as default storage. Hold the result if you loop; not a good choice for
large result sets.

**`$r->expand` -- decode json and jsonb columns.**

    $r->expand->rows->[0]{payload}{user}{name};

Which columns to decode comes from the stored `pg_type`, never from sniffing
values -- the direct payoff of keeping types. Non-JSON columns pass through
untouched, and the original's rows are never mutated. Decoding is eager, at
view construction, so the cost is paid once and is visible at the call site
rather than scattered through a loop. A decode failure dies naming the column
and the row index: malformed JSON arriving from PostgreSQL should be
impossible, so it is treated as the serious error it is.

`JSON::MaybeXS` is `require`d at call time -- it selects the fastest installed
backend and falls back to core `JSON::PP` -- and dies with an install hint if
absent. Optional dependency, same pattern as `Hash::MultiValue`.

Views compose: `$r->as({ 1 => 'body' })->expand->by('id')`.

### Lookups

The commonest post-fetch transform is a lookup keyed by a column, and the
hand-rolled `map` version silently keeps the last row when key values repeat --
the same bug class as duplicate columns. So the pair splits along the same
line, lossy-but-checked against lossless:

    my $users = $r->by('id');        # { 42 => $row_hashref, ... }
    my $teams = $r->groups('dept');  # { eng => Collection, ... }

`by` croaks if a key value repeats:

    Value '42' in column 'id' appears 3 times; use ->groups

`groups` never loses a row; its values are Collections, consistent with `rows`.
Both croak on a column name that is not present, listing the available ones,
and both build hashrefs, so the duplicate-column croak fires first. On a
renamed view, the lookup is by renamed column and the rows carry renamed keys.

### Column

    $c->name  $c->index
    $c->all             Collection of values
    $c->first  $c->next  $c->reset

`get_column` takes a name or an index and never guesses. Three croaks:

    No column 'idd'; columns are: id, name, price
    Column 'id' appears 2 times at positions 0, 1; ask for one by index
    Column index 7 out of range; result has 4 columns

Returning `undef` for a typo'd name is the silent-failure class this design
removes. On a renamed view, name lookup is against the renamed set.

### Collection

A blessed arrayref, so `@{ $r->rows }` and `$r->rows->[0]{name}` keep working
for every existing caller.

    $c->size  $c->first  $c->last  $c->each($cb)  $c->compact  $c->join($sep)  $c->to_array

**No `map`, `grep`, `sort` or `reduce`.** Mocked up and rejected: the chained
form is longer than the builtin it replaces, and it invents a callback
convention matching neither Mojo's `$_` nor Perl's own.

    $rs->rows->grep(sub { $_[0]{dept} eq 'eng' })->map(sub { $_[0]{name} })->sort->join('/')
    join '/', sort map { $_->{name} } grep { $_->{dept} eq 'eng' } @{ $rs->rows }

Since it is a blessed arrayref, the second already works.

### Rendering

    $r->preview        # default 5 rows
    $r->preview(20)

A compact string: column names with their PostgreSQL types, the total row
count, and the first N rows as an aligned text table. Bounded by design -- N
rows maximum, cell width capped with an ellipsis. This is the view for
debugging, logging and the REPL, and it is what an agent inspecting a result
needs: shape and a sample, never a flood.

It is positional, so it works on duplicate-column results, on views, and on
results with no rows to show:

    0 rows; 3 columns: id int4, name text, made date
    no columns; rows_affected: 7

### Pool and Connection

    await $pg->query_row($sql, @bind)      one row, or undef; warns if several matched
    await $pg->query_value($sql, @bind)    one value, or undef; same warning

`undef` for no match, because that is an ordinary outcome to branch on rather
than an exception to trap. A warning for several, because asking for one and
getting many usually means the query is wrong.

`query_row` returns a hashref, so the duplicate croak applies. Its signature
takes a bind list and must not grow an options convention, so the message
points one tier down instead:

    Column 'id' appears 2 times at positions 0, 1 in query_row;
    alias the columns, or use query(...)->single (optionally with ->as)

`query_value` is positional -- first column of the first row -- and never
builds a hash, so it succeeds on a duplicate-column query. That is a feature
and the POD says so.

This gives `query` / `query_row` / `query_value` -- asyncpg's
`fetch` / `fetchrow` / `fetchval`, arrived at independently.

### Cursor

    await $cur->next     one row, not a batch

`batch_size` becomes a transport detail: how many rows per round trip, not what
the caller sees. That makes the lazy and eager sides read alike:

    while (my $row = $rs->next)        { ... }
    while (my $row = await $cur->next) { ... }

Cursor batches are `Results` objects already, so a cursor over a
duplicate-column query croaks the same way, on the first `next` that builds a
hash rather than at open time.

**No `reset` on Cursor.** A server-side cursor is consumed; re-running the
query is a different guarantee, not a rewind. This is the one place the two
protocols legitimately diverge, and the POD says so rather than leaving it to
be discovered.

### RETURNING

`INSERT`/`UPDATE`/`DELETE ... RETURNING` populates `NAME` and yields rows
through the same handle machinery as `SELECT`, so the empty-`NAME` guard
already routes it correctly. Required behaviour, established by test rather
than trusted:

- `RETURNING *` and `RETURNING a, b` produce a full `Results` -- `rows`,
  `arrays`, `columns`, `types`, `as`, `multi`, `expand`, the duplicate croak,
  all identical to `SELECT`.
- `RETURNING id, id` is legal SQL and hits the same croak path as a self-join.
- Statements without `RETURNING` keep today's behaviour: empty `columns`,
  `rows_affected` as the payload, `rows` returning an empty Collection. No
  croak -- an empty name list holds no duplicates.
- The fetch-before-metadata ordering constraint is verified to hold for
  `RETURNING` statements. Expected, since it is the same handle machinery, but
  pinned down rather than assumed.

### Observability

`$r->elapsed` is the wall-clock duration of the query in fractional seconds,
captured at execute time from `Time::HiRes::clock_gettime(CLOCK_MONOTONIC)`
(verified present on this platform; `Time::HiRes::time` where the constant is
not exported). Nearly free to capture and impossible to reconstruct afterwards
-- the same argument that keeps `pg_type`.

One callback on the pool:

    $pg->on_query(sub {
        my ($event) = @_;
        warn "slow: $event->{sql}" if $event->{elapsed} > 1;
    });

The event is a hashref: `sql`, `binds`, `elapsed`, `rows`, `error`. It fires on
success and on failure alike; on failure `error` is set and `rows` is `undef`.

This single hook is slow-query logging, tracing, metrics, and the test
assertion "this code path ran two queries" -- without building any of those
four. It stays one hook. It does not grow into an event system.

`binds` carries the values as passed, so a `bytea` insert puts its payload in
the event. The POD warns that a handler which logs `binds` unfiltered will log
whatever was bound.

## Transactions

The distribution already has this, at `Async::DBD::Pg::transaction` and
`Async::DBD::Pg::Connection::transaction`, with `with_connection` for the
non-transactional case:

    my $result = await $pg->transaction(async sub ($conn) { ... });

Commit on success, rollback on exception, exception propagates. The critical
async property is that the connection stays checked out for the whole sub,
across every `await` inside it -- interleaving another query onto a connection
between `BEGIN` and `COMMIT` is the bug hand-rolled versions have. That
property is asserted by test here rather than assumed. No second spelling is
added.

## Documentation as an interface

This library appears in no model's training data, so code generated against it
will reach for Mojo::Pg and DBIC idioms unless the documentation is compact,
canonical and correct. Two deliverables follow from that:

**Verified POD examples.** Every SYNOPSIS and method example is extracted and
run as a test. Documentation that is mechanically guaranteed to run means code
generated from it works.

**A machine-oriented reference.** One `llms.txt`-style file in the dist root:
the whole public API surface with a one-line example each, under roughly 1,500
tokens, so a human or an agent reads it in a single pass. Checked against the
real API by test so it cannot drift.

## When to use which

**`rows` unless the names repeat; alias in SQL if you can, `->as` if you can't,
`arrays` if you don't know the columns, `multi` if you're generic and willing
to pay.**

## Rejected, with the reason

**Hash::MultiValue as default per-row storage.** Measured 0.140s against
0.050s -- **2.8x** on every result set, to solve a problem that arises on some.
It also does nothing for the metadata gap. As the opt-in `->multi` view it
contradicts none of this: the cost falls on the caller who asked for it.

**A `Record`-style hybrid** (asyncpg's tuple/dict row, `$row->[0]` and
`$row->{name}` on one object, via `@{}` and `%{}` overload). Two attempts:

- overloading both put a **17x** penalty on `$row->{name}`, the commonest
  operation in the library
- blessing a hashref and overloading only `@{}` fixed that -- 0.002s against
  0.002s -- but requires inside-out storage for the positional array, and
  `DESTROY` becomes load-bearing

Rejected on fragility rather than speed. The prototype had a silent bug within
minutes: `0 + $self` numified through the `bool` overload, collapsing 20,000
rows onto one key so they shared a single array. It produced plausible output
and only a checksum caught it. Elegant when correct and quietly wrong when not,
with a failure mode that looks like success.

**Row objects with column accessors** (`$row->name`). Collides with `count`,
`can`, `isa`; breaks on non-identifier column names; costs an object per row on
the hot path; and does not fix duplicates, since accessors over a hash have the
same collapse. Possible later precisely because rows are positional underneath.

**Auto-disambiguating duplicate names** (`id`, `id_2`). Invents data the query
did not contain, and the invented name depends on column order, so it changes
under a `SELECT *` when the table changes. Renaming stays explicit, by the
caller, through `as` or through SQL.

**In-memory `min`/`max`/`sum` on a column.** They would look like DBIC's SQL
aggregates and be imposters: `->max` over rows already fetched is not the
maximum of the table.

**`map`/`grep`/`sort`/`reduce` on Collection**, as above. `by` and `groups` do
not reopen this: they are lookup views with croak semantics, not general list
utilities.

**`->to_csv` and `->to_json` on Results.** `arrays` plus `columns` plus `types`
is exactly the interface a serialiser needs. A serialiser that lives outside
the library and requires nothing private from it is the proof that interface is
right.

**Query building, relationships, `update`/`delete`, schema classes.** ORM
territory. DBIC should sit on top of this, not be replaced by it.

**`?` positional placeholders**, an escape syntax of our own (`\?`, `\:`),
identifier-bound slices in named mode, and switching to DBD::Pg's native
`:foo` binding. Each of these hands part of placeholder semantics back to the
driver or to an ad-hoc convention. The converter plus `dollaronly` means this
library owns those semantics end to end, and that is the property worth
keeping.

**Removing named placeholders** was weighed here and rejected; `:name` stays.
The case for removing it is real -- it means our own SQL parser, and it forces
`Connection::query` to decide from the statement text whether a hashref bind is
a name-to-value map or a single positional value such as a JSONB document. But
there is no replacement to remove it in favour of. DBD::Pg does support a
native `:foo` form; it binds only through `bind_param`, and a positional
`execute()` against it dies with `Placeholders must begin with ':' when using
the ":foo" style`. This library's async path does not expose `bind_param`, so a
pass-through cannot serve `query($sql, \%params)` at all. The converter stays,
and with it this library owns placeholder semantics end to end -- which the
next section turns from an accident into the property being defended.

An earlier draft of this paragraph claimed `t/unit/placeholders.t` covers the
collisions that motivate the concern. That claim was wrong, and the way it was
wrong is the reason the next section exists.

## Compatibility

Never released publicly, so breaking changes are free and the better shape wins.

- `scalar` becomes `single_value`
- `rows` returns a blessed arrayref -- `@{ }` and `->[0]` unaffected, but
  `ref($r->rows) eq 'ARRAY'` becomes false. Nothing in-tree does that.
- `Cursor::next` returns a row rather than a batch. `each` and `all` unchanged.
- `rows` on a duplicate-column result croaks where it previously returned
  collapsed data. That is the point of the change, not a side effect of it.

## Known consequences

**`next`/`reset` make `Results` stateful.** Two consumers sharing a result will
interfere. Views do not have this problem with each other, since each carries
its own position. DBIC has the same property; it belongs in the POD rather than
being discovered.

**A duplicate-column result has no usable `first`.** `$r->first` croaks even
when the caller only wants a column whose name is unique. `row_array(0)` and
`get_column` by index are the positional escapes, and `as` is the fix. This is
the deliberate cost of refusing loudly.

**Strictness differs between `$pg->query(...)->first` and `$pg->query_row(...)`**
for the same SQL -- the first is lax by design, the second warns. One sentence
of POD, not a design change.

**A `?` written out of DBI habit is a PostgreSQL syntax error**, not a bind
error, once `pg_placeholder_dollaronly` is set: the server reports the `?`
rather than DBD::Pg reporting an unbound placeholder. One sentence of POD
pointing at `$1` covers it, and the trade is deliberate -- the alternative is
that jsonb's operators stay broken.

**A raw `:name` that reaches PostgreSQL** -- a typo in positional mode, where
the converter never runs -- now surfaces as a PostgreSQL syntax error at the
colon. Also acceptable, also one sentence.

**`Column::first` has no strict counterpart.** Having narrowed to a column,
several values are expected rather than surprising. An asymmetry in an
otherwise consistent scheme, recorded deliberately.

## Testing

Each shown failing first.

1. A self-join's repeated columns are all reachable through `arrays`, and
   `columns` reports every one. Fails today at two keys.
2. `types` reports PostgreSQL type names. Fails today: unobtainable.
3. `rows` is still usable as an arrayref -- `@{ }`, `->[0]{name}`, `scalar @{ }`.
4. `rows`, `first`, `single`, `next`, `each` and `all` croak on a self-join's
   duplicate columns, the message naming the column, the count and the
   positions.
5. `arrays`, `columns`, `types`, `count`, `rows_affected`, `is_empty` and
   `row_array` all work on that same result.
6. `as` full-list form: rename, then `rows`, `single`, `get_column` and
   `columns` all reflect the new names.
7. `as` sparse form: only the named indexes change; the rest keep raw names.
8. `as` validation croaks: wrong list length, out-of-range index, and a rename
   that still leaves duplicates.
9. View independence: iterate a view with `next`, the original's cursor has not
   moved; and the reverse.
10. `get_column` by name, by index, the ambiguity croak naming positions, the
    missing-name croak listing available columns, and the out-of-range croak.
11. `first` silent, `single` and `single_value` warning on multiple rows.
12. `multi` returns Hash::MultiValue rows holding *all* values of a repeated
    name, and works on a renamed view with renamed keys.
13. `query_row` and `query_value`: match, no match returning `undef`, several
    warning. `query_row`'s duplicate croak names the `query(...)->single`
    escape hatch; `query_value` succeeds on the same SQL.
14. `Cursor::next` yields rows, and `batch_size` changes round trips, not
    results.
15. Non-row statements -- `INSERT`, `CREATE` -- still work, which is the trap
    the positional fetch introduces.
16. RETURNING parity in full: `RETURNING *` and `RETURNING a, b` behave as
    `SELECT`; `RETURNING id, id` croaks; a statement without `RETURNING` is
    untouched; the fetch-before-metadata order holds.
17. `by` builds the lookup, croaks on a repeated key value naming the value,
    column and count and suggesting `groups`, and croaks on a missing column
    listing the available ones.
18. `groups` is lossless, one Collection per key value; missing-column croak.
19. `expand` decodes json and jsonb to structures with other columns
    byte-identical; composes with `as`; works on a RETURNING result; dies with
    an install hint when the JSON module is absent; leaves the original's rows
    unmutated.
20. `preview` output contains column names, types and row count; row output
    capped at N; wide values truncated; sensible output for empty and non-row
    results; works on a duplicate-column result.
21. `elapsed` present and greater than zero on every Results including
    RETURNING. `on_query` receives `sql`, `binds`, `elapsed` and `rows` on
    success, and fires with `error` set on a failing query.
22. `transaction` commits on success, rolls back and rethrows on exception, and
    the connection is not shared with another query between `BEGIN` and
    `COMMIT`/`ROLLBACK` even when the sub awaits. Asserted through `on_query`
    or connection identity.
23. POD examples extract and run green, and every method listed in the machine
    reference exists -- a `can` sweep is enough to stop drift.

Placeholder hardening, continuing the same list:

24. Integration: jsonb `?`, `?|` and `?&` through `query`, each with no binds,
    with `$1` positional binds, and with `:name` named binds.
25. Integration: `SELECT arr[:2]` and `SELECT arr[1:3]` through `query`, in
    both bind modes.
26. Integration regression with `pg_placeholder_dollaronly` set: `$1`
    positional binds, `:name` named binds, and a typed `PG_BYTEA` round trip
    -- reusing the bytea suite's pattern -- all still work.
27. Converter: a decoy `:name` inside each of a `$$` string, a `$tag$` string,
    a line comment, a block comment, and a *nested* block comment is left
    untouched, while a real `:name` elsewhere in the same statement still
    converts and binds. The nested case must place the decoy after the inner
    close -- `/* a /* b */ :note */` -- since `/* a /* b */ c */` passes today
    by containing no colon at all, and would pass a naive first-`*/` fix too.
28. Converter: `E'it\'s ok'` followed by a real `:name`. The string passes
    through byte-identical and the `:name` converts. This fails silently
    today, so the assertions are on the converted SQL and the bind list --
    asserting that it does not die would pass against the bug.
29. Converter regression: every existing `t/unit/placeholders.t` case still
    passes after the rewrite, and `SELECT 'a\', :a` still converts, which
    guards against extending backslash escaping beyond `E'...'`.

Mutations. Revert the constructor to `fetchall_arrayref({})`: tests 1, 2 and 4
must red on missing data rather than on setup. Remove
`pg_placeholder_dollaronly` from the prepare: tests 24 and 25 must red. Revert
the scanner's comment handling: test 27 must red on the spurious die, again not
on setup.

## Risk

`Results` is constructed by every query in the distribution. The core change is
one constructor and a set of accessors over the same data, and the existing
suite exercises that path continuously -- but a mistake there affects every
result, not an edge case.

The views, lookups, rendering and observability are additive: they cannot
change what an existing result returns. That difference is the natural seam for
sequencing the work -- storage and croaks first, verified against the whole
suite, then everything built on top of them.

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

Measured, 20,000 rows x 4 columns:

    fetchall_arrayref({})  -- current      0.050s
    fetchall_arrayref()    -- positional   0.025s
    positional + derive hashes             0.041s

Positional storage is **faster than what we do now**, even after deriving the
hashes that `rows` returns. The fix costs nothing.

## API

### Results

    $r->rows            Collection of hashrefs, derived on demand
    $r->arrays          Collection of arrayrefs, positional
    $r->columns         column names, in order, duplicates intact
    $r->types           PostgreSQL type names: int4, text, numeric
    $r->count  $r->rows_affected  $r->is_empty

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

### Column

    $c->name  $c->index
    $c->all             Collection of values
    $c->first  $c->next  $c->reset

`get_column` takes a name or an index. A name that appears more than once is an
error naming the positions, not a silent choice between them:

    Column 'id' appears 2 times at positions 0, 1; ask for one by index

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

### Pool and Connection

    await $pg->query_row($sql, @bind)      one row, or undef; warns if several matched
    await $pg->query_value($sql, @bind)    one value, or undef; same warning

`undef` for no match, because that is an ordinary outcome to branch on rather
than an exception to trap. A warning for several, because asking for one and
getting many usually means the query is wrong.

This gives `query` / `query_row` / `query_value` -- asyncpg's
`fetch` / `fetchrow` / `fetchval`, arrived at independently.

### Cursor

    await $cur->next     one row, not a batch

`batch_size` becomes a transport detail: how many rows per round trip, not what
the caller sees. That makes the lazy and eager sides read alike:

    while (my $row = $rs->next)        { ... }
    while (my $row = await $cur->next) { ... }

**No `reset` on Cursor.** A server-side cursor is consumed; re-running the
query is a different guarantee, not a rewind. This is the one place the two
protocols legitimately diverge, and the POD says so rather than leaving it to
be discovered.

## When to use which

**`rows` unless you have a reason.** Three reasons exist:

- the query repeats a column name, and a hash cannot hold both
- the code does not know the columns ahead of time
- one column is wanted and its name is ambiguous

That rule is the test of whether two views are one concept too many. It fits in
a sentence, so they are not.

## Rejected, with the reason

**Hash::MultiValue per row.** Measured 0.140s against 0.050s -- **2.8x** on
every result set, to solve a problem that arises on some. It also does nothing
for the metadata gap.

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

**In-memory `min`/`max`/`sum` on a column.** They would look like DBIC's SQL
aggregates and be imposters: `->max` over rows already fetched is not the
maximum of the table.

**Query building, relationships, `update`/`delete`, schema classes.** ORM
territory. DBIC should sit on top of this, not be replaced by it.

## Compatibility

Never released publicly, so breaking changes are free and the better shape wins.

- `scalar` becomes `single_value`
- `rows` returns a blessed arrayref -- `@{ }` and `->[0]` unaffected, but
  `ref($r->rows) eq 'ARRAY'` becomes false. Nothing in-tree does that.
- `Cursor::next` returns a row rather than a batch. `each` and `all` unchanged.

## Known consequences

**`next`/`reset` make `Results` stateful.** Two consumers sharing a result will
interfere. DBIC has the same property; it belongs in the POD rather than being
discovered.

**Strictness differs between `$pg->query(...)->first` and `$pg->query_row(...)`**
for the same SQL -- the first is lax by design, the second warns. One sentence
of POD, not a design change.

**`Column::first` has no strict counterpart.** Having narrowed to a column,
several values are expected rather than surprising. An asymmetry in an
otherwise consistent scheme, recorded deliberately.

## Testing

Each shown failing first:

1. A self-join's repeated columns are all reachable through `arrays`, and
   `columns` reports every one. Fails today at two keys.
2. `types` reports PostgreSQL type names. Fails today: unobtainable.
3. `rows` is still usable as an arrayref -- `@{ }`, `->[0]{name}`, `scalar @{ }`.
4. `get_column` by name, by index, and the ambiguity error naming positions.
5. `first` silent, `single` and `single_value` warning on multiple rows.
6. `query_row` and `query_value`: match, no match returning undef, several
   warning.
7. `Cursor::next` yields rows, and `batch_size` changes round trips, not
   results.
8. Non-row statements -- `INSERT`, `CREATE` -- still work, which is the trap
   the positional fetch introduces.

Mutation: revert the constructor to `fetchall_arrayref({})`. Tests 1 and 2 must
red on missing data rather than on setup.

## Risk

`Results` is constructed by every query in the distribution. The change is one
constructor and a set of accessors over the same data, and the existing suite
exercises that path continuously -- but a mistake here affects every result,
not an edge case.

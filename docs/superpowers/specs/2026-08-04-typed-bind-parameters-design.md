# Typed bind parameters design

**Goal:** let a caller state a bind parameter's PostgreSQL type, so binary and
other non-text types are stored correctly instead of silently corrupted.

## The defect

Bind values go straight to `$sth->execute(@$bind)`, with no per-parameter
type. DBD::Pg then sends everything as text, and PostgreSQL's text
representation is not the Perl scalar for several types. For `bytea` the
result is data loss, and the write reports success. Measured:

    plain ascii                in=  5 bytes  stored=5    exact
    NUL in the middle          in=  7 bytes  stored=3    *** DATA LOST ***
    leading NUL (chr 0..255)   in=256 bytes  stored=0    *** DATA LOST ***
    high bytes, no NUL         INSERT FAILED

Three behaviours, and the middle one is the dangerous case: **a value
containing a NUL is truncated at the NUL and the INSERT succeeds.** No error,
no warning. Anything with a zero byte — a serialized structure, an image, a
compressed or encrypted payload — is destroyed on the way in and the
application finds out when it reads back.

Recorded as gaps item 51, whose title ("No type binding control") describes the
mechanism accurately and the consequence not at all.

`bytea` is the urgent case, not the whole case. Any type whose wire form
differs from the Perl scalar has the same exposure, so the fix is a general
one rather than a `bytea` escape hatch.

## Design

A bind **value** that is a hashref carrying `type` and `value` supplies its own
type:

```perl
use DBD::Pg qw(:pg_types);

# untyped -- unchanged, and still the common case
await $conn->query('INSERT INTO t VALUES ($1, $2)', $id, $name);

# typed, positional
await $conn->query('INSERT INTO t VALUES ($1, $2)',
    $id, { type => PG_BYTEA, value => $bytes });

# typed, named placeholders
await $conn->query('INSERT INTO t VALUES (:id, :blob)', {
    id   => $id,
    blob => { type => PG_BYTEA, value => $bytes },
});
```

This is [Mojo::Pg's convention](https://metacpan.org/pod/Mojo::Pg::Database),
verbatim:

    elsif (exists $param->{type} && exists $param->{value}) {
      ($attrs->{pg_type}, $param) = @{$param}{qw(type value)};
    }

Adopting it rather than inventing a shape means anyone arriving from Mojo::Pg
already knows it, and it generalises to every `pg_type` constant without
further API.

This reserves no syntax that currently works. A hashref bind value is refused
today by DBD::Pg's own XS with `Cannot bind a reference` — verified — so
giving it a meaning is purely additive. JSON is passed as a *string* today, so
a document like `{"type":"click","value":42}` never reaches the sentinel check,
which only inspects `ref $value eq 'HASH'`.

## Verified before designing around it

Each of these was run against DBD::Pg 3.20.2 rather than assumed, because the
whole design rests on them:

| question | result |
|---|---|
| `bind_param` + `pg_type` stores binary correctly | 256/256 bytes, byte-exact |
| composes with `pg_async` | yes |
| composes with the `$N` placeholders `convert_placeholders` emits | yes |
| typed and untyped parameters mixed in one statement | yes |
| `undef` through a typed bind | stores NULL, not empty |

`convert_placeholders` pushes values through unchanged (`push @bind,
$params->{$name}`), so a sentinel survives named-placeholder conversion with no
change to that function.

## Disambiguating a lone hashref

`_parse_query_args` already gives a lone hashref a meaning — named binds — so a
single positional typed parameter has the same shape as a named-bind map:

```perl
{ type => PG_BYTEA, value => $bytes }   # one typed value?
{ type => 'click',  value => 42     }   # binds for :type and :value?
```

Identical input, two intentions. The keys cannot settle it: a query with
`:type` and `:value` placeholders against a table with `type` and `value`
columns is entirely ordinary.

**The SQL settles it.** If the statement contains no `:name` placeholders, the
hashref cannot be a named-bind map, so it is a single positional value:

```perl
my ($converted, $named) = convert_placeholders($sql, $bind);
if (@$named || $converted ne $sql) { ($sql, $bind) = ($converted, $named) }
else                               { $bind = [$bind] }
```

This is the principle psycopg uses: its `%s` versus `%(name)s` declares the
style in the statement itself, and the parameter container must match.

Verified against the prototype — all four cases behave:

| call | result |
|---|---|
| two positional, one typed | ok |
| single positional typed | 256/256 bytes |
| named placeholders with a sentinel | 256/256 bytes |
| genuine `:type`/`:value` named binds | `type=click value=42` |

Nothing valid changes meaning. A lone hashref against a statement with no
`:name` placeholders is a hard error today — DBD::Pg reports `execute called
with an unbound placeholder` — so giving it a meaning only turns a failure into
a success.

**One consequence to accept.** A mistyped named-bind call (`:naem` in the SQL,
`naem` absent from the hash) now reports `Cannot bind a reference` from DBD::Pg
rather than a missing-placeholder error. Both are loud; the attribution is
worse. That is the price of the single-parameter form working, and the
single-parameter binary insert is common enough to be worth it.

## How other clients solve this

Checked against source, because the answer determines whether annotation is a
wart or a necessity.

| client | binary parameter | mechanism |
|---|---|---|
| node-postgres | `Buffer` | dispatch on JS type; `toPostgres()` escape hatch |
| psycopg | `bytes` | dispatch on Python type; `%b`/`%t` forces wire format |
| asyncpg | `bytes` | dispatch on Python type, plus server type OIDs |
| Mojo::Pg | `{type => PG_BYTEA, value => $x}` | caller annotates |
| DBI / DBD::Pg | `bind_param($i, $v, {pg_type => ...})` | caller annotates |

node-postgres is explicit — `if (val instanceof Buffer) { return val }`, then
dates, arrays and objects each dispatched on type. Psycopg the same.

**The divide is the language, not the library.** Python, JavaScript and Go each
have a distinct binary type, so their clients can look at a value and know.
Perl has none: a scalar holding an image and a scalar holding a sentence are
the same thing. Annotation is the only mechanism available, which is why both
Perl clients use it, and why the "infer from the value" option was unavailable
rather than merely unattractive — the only signals are "contains a NUL" or
"fails a UTF-8 check", and both misfire on legitimate text.

DBI never meets this ambiguity because it has no bulk-bind API: every parameter
is an explicit `bind_param` call. The ambiguity is a cost of our convenience
layer, and worth naming as ours.

## Implementation

In `_execute_async`, replace `$sth->execute(@$bind)` with a bind loop:

```perl
for my $i (0 .. $#$bind) {
    my $value = $bind->[$i];
    my $attrs;

    if (ref $value eq 'HASH' && exists $value->{type} && exists $value->{value}) {
        $attrs = { pg_type => $value->{type} };
        $value = $value->{value};
    }

    $sth->bind_param($i + 1, $value, $attrs);
}
$sth->execute;
```

And in `query`, the disambiguation shown above, so a lone hashref against a
statement with no `:name` placeholders is treated as one positional value
rather than an empty named-bind map.

Those are the only two changes. The statement handle, the guard, the
`pg_async` dispatch and the result collection are all untouched.

## Scope

**In:** the `type`/`value` sentinel, for positional and named binds, wherever a
bind list reaches `_execute_async` — which includes `query`, and through it
transactions and cursors, since they all route here.

**Out:** Mojo's `{-json => $ref}` shorthand. It needs a JSON encoder this
distribution does not currently depend on, and it is a convenience over a
problem the caller can already solve by encoding themselves. The sentinel is
the mechanism; JSON shorthand can be added later on top of it without changing
anything designed here.

**Out:** inferring types from the value. Considered and rejected — it guesses
from data rather than from code, so a legitimately non-UTF8 text value would be
stored as binary, and behaviour would change with the data. That is the hardest
class of bug to trace.

## Testing

Each must be shown failing first, except where noted:

1. **The defect.** A `bytea` round trip of all 256 byte values, asserting
   byte-exact equality and length 256. Fails today at length 0.
2. **NUL truncation specifically**, since it is the silent case: `"abc\0def"`
   stores 7 bytes, not 3.
3. **Mixed typed and untyped** parameters in one statement, asserting the
   untyped ones are unaffected.
4. **Named placeholders** carrying a sentinel, since that path runs through
   `convert_placeholders`.
5. **`undef` through a typed bind** stores NULL rather than an empty string.
6. **A hashref that is not a sentinel** — one lacking `type` or `value` — is
   left alone rather than being silently unwrapped.
7. **Untyped queries are unchanged.** The existing suite is the evidence; every
   test must pass untouched, since this path carries every query in the
   library.

Mutation-verify by reverting the bind loop to `execute(@$bind)`: tests 1 and 2
must red on stored length rather than on setup.

## Risk

`_execute_async` is on the path of **every query in the distribution** —
queries, transactions, cursors, the pub/sub control statements, the pool's own
liveness checks. The change is a loop that behaves identically to
`execute(@$bind)` for values that are not sentinels, but a mistake affects all
database access rather than the binary case.

The mitigating evidence is that the existing suite exercises that path
continuously: 202 tests, both event loop implementations, and every one of them
binds untyped parameters.

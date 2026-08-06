# A bind type is sticky on a cached statement handle

**Status:** open, not fixed. Found during the mapper-support final review,
reproduced independently before filing.

**Affects:** any pool with `statement_cache_size` set to a non-zero value.
Does not reproduce with the cache off, which is the default.

## What happens

`pg_type` set on a bind persists on the statement handle, so a later untyped
bind of the same statement inherits the earlier type. Two byte-identical calls
store different bytes depending on what ran between them.

Insert a 5-byte value containing a NUL, `"a\0bcd"`, into a `bytea` column
through one statement three times -- untyped, typed, untyped:

    statement_cache_size => 10        statement_cache_size => 0
      n=1  stored 1 byte                n=1  stored 1 byte
      n=2  stored 5 bytes  (typed)      n=2  stored 5 bytes  (typed)
      n=3  stored 5 bytes  <-- LEAK     n=3  stored 1 byte   (correct)

`n=1` and `n=3` are the same call with the same arguments. With the cache on,
the third one silently picks up the type from the second.

Note which way the damage runs. The *untyped* result is the lossy one -- a
`bytea` sent as text truncates at its first NUL and reports success -- so the
leak makes a broken call accidentally work, and its absence is what exposes
the truncation. Either way the stored bytes depend on statement history rather
than on the call, which is the defect.

## Reproduction

    my $pg = Async::DBD::Pg->new(dsn => ..., statement_cache_size => 10);
    my $conn = await $pg->connection;
    my $sql = 'INSERT INTO t VALUES ($1, $2)';
    await $conn->query($sql, 1, "a\0bcd");                              # untyped
    await $conn->query($sql, 2, { type => 'bytea', value => "a\0bcd" }); # typed
    await $conn->query($sql, 3, "a\0bcd");                              # untyped
    # row 3 now holds 5 bytes, row 1 holds 1

## Why it is not a regression from the mapper-support branch

It reproduces identically through the older `{ type => PG_BYTEA }` constant
spelling, which predates that branch, and it vanishes entirely with
`statement_cache_size => 0`. The vector is the statement cache combined with
typed binds, both of which shipped before. What the mapper-support branch
changes is exposure: it makes typed binds a documented, first-class idiom that
a mapper is expected to generate for every bind, so the combination becomes far
more likely to occur.

## Why it was not fixed alongside the branch that found it

The fix belongs in the statement cache's handle-reuse path, not in the bind
resolution the mapper work touched. Folding it into that branch's fix wave
would have mixed an unrelated correctness fix into a reviewed feature diff.

## Where to look

`Async::DBD::Pg::Connection::_execute_once` binds parameters one at a time and
passes `pg_type` only for binds that carry a type. A cached handle keeps the
attributes from its previous execution, so a bind that passes no `pg_type`
does not clear what was set before. Any fix has to make each execution state
the full type intent for every parameter, rather than relying on the handle
being fresh.

The statement cache's design notes are in
`docs/superpowers/specs/2026-08-05-statement-cache-design.md`.

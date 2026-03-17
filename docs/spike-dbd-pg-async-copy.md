# Spike: Async COPY FROM Support in DBD::Pg

## Goal

Determine what it takes to add `pg_putcopydata_async` and `pg_putcopyend_async` to DBD::Pg,
enabling non-blocking COPY FROM STDIN for async Perl libraries.

## Current State

DBD::Pg has async COPY TO (read side) via `pg_getcopydata_async`, but the write side
(`pg_putcopydata`, `pg_putcopyend`) is unconditionally blocking. The stubs for non-blocking
behavior already exist as dead code.

## Key Finding: The Stubs Are Already There

The C implementation of `pg_db_putcopydata` in `dbdimp.c:4508-4548` already has:

```c
copystatus = PQputCopyData(imp_dbh->conn, copydata, copylen);

if (1 == copystatus) {
    // success path (only flushes for COPY_BOTH, not COPY_IN)
}
else if (0 == copystatus) { /* non-blocking mode only */
    // EMPTY -- dead code, never reached because connection is always blocking
}
else {
    // error path
}
```

Similarly, `pg_db_putcopyend` has a `copystatus == 0` stub that returns 0.

The reason these are dead code: DBD::Pg **never calls `PQsetnonblocking()`**. The
connection is always in blocking mode, so `PQputCopyData` will block rather than return 0.

## Architecture Difference from Async Queries

DBD::Pg's existing async query support uses `PQsendQuery`/`PQsendQueryParams` (the "send"
family) which are inherently non-blocking — they queue the query and return immediately.
Polling is then done via `PQconsumeInput` + `PQisBusy`.

COPY has no `PQsend*` equivalent. The **only** way to make `PQputCopyData` non-blocking is
to enable non-blocking mode on the entire connection via `PQsetnonblocking(conn, 1)`. This
is the fundamental architectural gap.

## Proposed Patch

### Approach: Scoped Non-Blocking Mode for COPY

Enable `PQsetnonblocking` when entering COPY FROM, disable it when COPY ends. This is safe
because during COPY state, no other operations are allowed on the connection anyway.

### Changes Required

**1. `dbdimp.c` — Modify `pg_db_putcopydata` to accept an `async` flag**

```c
int pg_db_putcopydata (SV * dbh, SV * dataline, int async)
{
    dTHX;
    D_imp_dbh(dbh);
    int copystatus;

    if (PGRES_COPY_IN != imp_dbh->copystate && PGRES_COPY_BOTH != imp_dbh->copystate)
        croak("pg_putcopydata can only be called directly after issuing a COPY FROM command\n");

    /* Enable non-blocking mode for async callers */
    if (async && !imp_dbh->copy_nonblocking) {
        if (PQsetnonblocking(imp_dbh->conn, 1) != 0) {
            pg_error(aTHX_ dbh, PGRES_FATAL_ERROR, "Failed to set non-blocking mode");
            return -1;
        }
        imp_dbh->copy_nonblocking = 1;
    }

    /* ... existing copydata/copylen setup ... */

    copystatus = PQputCopyData(imp_dbh->conn, copydata, copylen);

    if (1 == copystatus) {
        /* In non-blocking mode, must flush after successful queue */
        if (async || PGRES_COPY_BOTH == imp_dbh->copystate) {
            int flush_status = PQflush(imp_dbh->conn);
            if (flush_status == -1) {
                _fatal_sqlstate(aTHX_ imp_dbh);
                pg_error(aTHX_ dbh, PGRES_FATAL_ERROR, PQerrorMessage(imp_dbh->conn));
                return -1;
            }
            /* flush_status 1 means data pending — caller should poll for write-ready */
            if (async && flush_status == 1)
                return 2; /* new return value: "queued but flush pending" */
        }
        return 1;
    }
    else if (0 == copystatus) {
        /* Non-blocking mode: buffer full, caller should wait for write-ready */
        return 0;
    }
    else {
        _fatal_sqlstate(aTHX_ imp_dbh);
        pg_error(aTHX_ dbh, PGRES_FATAL_ERROR, PQerrorMessage(imp_dbh->conn));
        return -1;
    }
}
```

**Return values for async mode:**
- `1` — data queued and flushed successfully
- `2` — data queued but flush pending (poll socket for write-ready, then call `pg_flush`)
- `0` — buffer full (poll socket for write-ready, then retry)
- `-1` — error

**2. `dbdimp.c` — Add `pg_db_flush` (new function)**

```c
int pg_db_flush (SV * dbh)
{
    dTHX;
    D_imp_dbh(dbh);

    int status = PQflush(imp_dbh->conn);
    if (status == -1) {
        _fatal_sqlstate(aTHX_ imp_dbh);
        pg_error(aTHX_ dbh, PGRES_FATAL_ERROR, PQerrorMessage(imp_dbh->conn));
    }
    /* 0 = fully flushed, 1 = more to send (poll for write-ready and call again) */
    return status;
}
```

**3. `dbdimp.c` — Modify `pg_db_putcopyend` to support async**

The blocking version calls `PQgetResult` in a loop. The async version would:

```c
int pg_db_putcopyend_async (SV * dbh)
{
    dTHX;
    D_imp_dbh(dbh);

    int copystatus = PQputCopyEnd(imp_dbh->conn, NULL);

    if (1 == copystatus) {
        /* Flush but don't block waiting for server response */
        int flush_status = PQflush(imp_dbh->conn);
        if (flush_status == -1) {
            /* ... error ... */
            return -1;
        }
        if (flush_status == 1)
            return 2; /* flush pending */

        /* Restore blocking mode */
        PQsetnonblocking(imp_dbh->conn, 0);
        imp_dbh->copy_nonblocking = 0;

        /* Check if result is ready (non-blocking) */
        if (!PQconsumeInput(imp_dbh->conn)) {
            /* ... error ... */
            return -1;
        }
        if (PQisBusy(imp_dbh->conn))
            return 0; /* result not ready yet — caller should poll */

        /* Result ready — drain it */
        /* ... same PQgetResult drain loop as blocking version ... */
        imp_dbh->copystate = 0;
        return 1;
    }
    else if (0 == copystatus) {
        return 0; /* buffer full */
    }
    /* ... error ... */
}
```

**4. `dbdimp.h` — Add to struct and declarations**

```c
/* Add to imp_dbh_t struct: */
int copy_nonblocking;  /* 1 if PQsetnonblocking was called for async COPY */

/* Add declarations: */
int pg_db_putcopydata (SV *dbh, SV *dataline, int async);
int pg_db_putcopyend_async (SV *dbh);
int pg_db_flush (SV *dbh);
```

**5. `Pg.xs` — Add new XS functions**

Following the exact pattern of `pg_getcopydata` / `pg_getcopydata_async`:

```xs
I32
pg_putcopydata(dbh, dataline)
    CODE:
        RETVAL = pg_db_putcopydata(dbh, dataline, 0);  /* async=0 */

I32
pg_putcopydata_async(dbh, dataline)
    CODE:
        RETVAL = pg_db_putcopydata(dbh, dataline, 1);  /* async=1 */

I32
pg_putcopyend_async(dbh)
    CODE:
        RETVAL = pg_db_putcopyend_async(dbh);

I32
pg_flush(dbh)
    CODE:
        RETVAL = pg_db_flush(dbh);
```

**6. `Pg.pm` — Install methods**

```perl
DBD::Pg::db->install_method('pg_putcopydata_async');
DBD::Pg::db->install_method('pg_putcopyend_async');
DBD::Pg::db->install_method('pg_flush');
```

### Total Change Size

| File | Changes |
|---|---|
| `dbdimp.h` | +3 lines (1 struct field, 2 declarations) |
| `dbdimp.c` | ~60 lines new code (putcopydata_async logic, flush, putcopyend_async) |
| `Pg.xs` | +12 lines (3 new XS functions) |
| `Pg.pm` | +3 lines (install_method calls) |
| `Pg.pm` POD | ~30 lines (document new methods) |
| Tests | ~50-100 lines |

**Estimated total: ~110-210 lines of C/XS/Perl, plus tests and docs.**

## How Async::DBD::Pg Would Use This

With these DBD::Pg methods, the async COPY FROM workflow becomes:

```perl
async sub copy_from {
    my ($self, $table, $data_iterator) = @_;
    my $dbh = $self->{dbh};

    await $self->query("COPY $table FROM STDIN");

    while (my $row = $data_iterator->()) {
        my $status = $dbh->pg_putcopydata_async($row);

        while ($status == 0 || $status == 2) {
            # Buffer full or flush pending — wait for socket writable
            await Future::IO->poll($self->_get_socket, POLLOUT);
            if ($status == 2) {
                $status = $dbh->pg_flush;
                $status = 1 if $status == 0; # flushed, continue
            } else {
                # Retry the put
                $status = $dbh->pg_putcopydata_async($row);
            }
        }

        die "COPY error" if $status == -1;
    }

    # End COPY — async flush and result collection
    my $end_status = $dbh->pg_putcopyend_async;
    while ($end_status != 1) {
        if ($end_status == 2) {
            await Future::IO->poll($self->_get_socket, POLLOUT);
            $end_status = $dbh->pg_flush == 0 ? 0 : 2;
            next;
        }
        # Poll for server result
        await Future::IO->poll($self->_get_socket, POLLIN);
        $end_status = $dbh->pg_putcopyend_async; # retry
    }
}
```

Fully non-blocking. No event loop stalls. The socket polling integrates with any Future::IO
backend.

## Risk Assessment

**Low risk:**
- The pattern follows exactly what DBD::Pg already does for `pg_getcopydata_async`
- `PQsetnonblocking` is scoped to COPY state (no other ops allowed during COPY anyway)
- The blocking `pg_putcopydata` is unchanged (async=0 preserves existing behavior)
- `PQflush` is well-documented and already used in DBD::Pg for COPY_BOTH

**Medium risk:**
- `PQsetnonblocking` affects the entire connection — need to ensure it's reset even on error
  paths (RAII-style cleanup or reset in putcopyend/error handler)
- The `putcopyend_async` polling is more complex than the data path because it needs to
  drain `PQgetResult` non-blockingly

**Minimal backward compatibility risk:**
- Existing `pg_putcopydata` signature changes from `(dbh, dataline)` to
  `(dbh, dataline, async)` in C, but the XS wrapper passes `0` for the existing function
- No behavior change for any existing code

## Recommendation

This is a well-scoped, low-risk patch to DBD::Pg. The stubs are already there, the pattern
is established by `pg_getcopydata_async`, and the change is ~200 lines including tests.

**Next steps:**
1. Fork `bucardo/dbdpg` on GitHub
2. Implement the patch
3. Test with both blocking and non-blocking callers
4. Submit PR with rationale: "Enable non-blocking COPY FROM for async Perl libraries"
5. In parallel, ship Async::DBD::Pg with the "mostly async" COPY FROM (blocking putcopydata
   in small chunks) and upgrade to true async when the DBD::Pg patch lands

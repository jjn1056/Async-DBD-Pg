# 03 Transactions

Atomic operations with commit, rollback, and nested savepoints.

```bash
DATABASE_URL='postgresql://postgres:test@localhost:5432/test' perl -Ilib examples/03-transactions/app.pl
```

This example shows:

- `transaction()` for automatic `BEGIN` / `COMMIT`
- Rollback on exception
- Nested transactions using savepoints

# 05 Parallel Queries

Running independent queries concurrently with pooled connections.

```bash
DATABASE_URL='postgresql://postgres:test@localhost:5432/test' perl -Ilib examples/05-parallel-queries/app.pl
```

This example shows:

- Sequential versus parallel query timing
- Using one pooled connection per concurrent query
- Inspecting pool statistics afterwards

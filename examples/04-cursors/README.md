# 04 Cursors

Streaming large result sets in batches.

```bash
DATABASE_URL='postgresql://postgres:test@localhost:5432/test' perl -Ilib examples/04-cursors/app.pl
```

This example shows:

- Creating cursors with `cursor()`
- Fetching rows one at a time with `next()`, `batch_size` rows per round trip
- Using placeholders with cursors
- Closing cursor resources explicitly

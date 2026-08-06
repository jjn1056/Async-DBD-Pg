# 02 Placeholders

Safe parameterized queries with `Async::DBD::Pg`.

```bash
DATABASE_URL='postgresql://postgres:test@localhost:5432/test' perl -Ilib examples/02-placeholders/app.pl
```

This example shows:

- Positional placeholders using `$1`, `$2`, ...
- Named placeholders using `:name`
- Passing user input without SQL interpolation
- Running queries directly against the pool with `query_value`
- Shutting the pool down

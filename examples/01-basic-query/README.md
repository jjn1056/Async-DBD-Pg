# 01 Basic Query

Your first `Async::DBD::Pg` query.

```bash
DATABASE_URL='postgresql://postgres:test@localhost:5432/test' perl -Ilib examples/01-basic-query/app.pl
```

This example shows:

- Creating a pool with `Async::DBD::Pg->new`
- Running simple queries directly against the pool with `query_value`/`query`
- Accessing result rows
- Shutting the pool down

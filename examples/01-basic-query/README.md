# 01 Basic Query

Your first `Async::DBD::Pg` query.

```bash
DATABASE_URL='postgresql://postgres:test@localhost:5432/test' perl -Ilib examples/01-basic-query/app.pl
```

This example shows:

- Creating a pool with `Async::DBD::Pg->new`
- Getting a pooled connection
- Running simple queries
- Accessing result rows
- Releasing the connection

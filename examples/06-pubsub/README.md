# Pub/Sub

This example shows `LISTEN` / `NOTIFY` support using `Async::DBD::Pg`'s
loop-agnostic pub/sub API.

Run it with:

```bash
DATABASE_URL="postgresql://postgres:test@localhost:5432/test" perl -Ilib examples/06-pubsub/app.pl
```

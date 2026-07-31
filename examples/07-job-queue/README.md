# Job Queue

A simple job queue using transactions, `FOR UPDATE SKIP LOCKED`, and
`LISTEN` / `NOTIFY`.

Run it with:

```bash
DATABASE_URL="postgresql://postgres:test@localhost:5432/test" perl -Ilib examples/07-job-queue/app.pl
```

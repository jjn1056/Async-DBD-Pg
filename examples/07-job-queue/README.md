# Job Queue

A job queue using transactions, `FOR UPDATE SKIP LOCKED`, and
`LISTEN` / `NOTIFY`.

A producer and three workers run at the same time, composed into one tree of
futures with [Future::Selector](https://metacpan.org/pod/Future::Selector).
Each is an ordinary `async sub`; none of them knows about the others.

Points worth borrowing:

- `FOR UPDATE SKIP LOCKED` lets every worker read the same table without two
  of them ever claiming one job.
- Workers park on a future instead of polling, and the `LISTEN` callback wakes
  them. The wait is also given a timeout, so a notification arriving in the
  gap between finding no work and going to sleep cannot strand a worker.
- Each branch is wrapped so a failure is reported and contained rather than
  taking down the whole tree. One job in the run fails deliberately to show
  it: the other workers carry on.
- A failed job is classified with `is_unique_violation`, and the offending
  `->constraint` is captured for reporting rather than just the raw error
  text.

Requires `Future::Selector`, which is not needed by the library itself.

Run it with:

```bash
DATABASE_URL="postgresql://postgres:test@localhost:5432/test" perl -Ilib examples/07-job-queue/app.pl
```

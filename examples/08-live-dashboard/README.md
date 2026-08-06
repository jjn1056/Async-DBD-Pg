# Live Dashboard

Real-time metrics display using `LISTEN` / `NOTIFY`.

Each metric reports on its own interval and the display redraws on its own
beat, composed into one tree of futures with
[Future::Selector](https://metacpan.org/pod/Future::Selector). Written as a
single loop these would have to take turns; as separate branches each simply
runs at its own pace, which the differing update counts in the summary show.

Redrawing on a timer rather than on every notification means a burst of
updates cannot cause a burst of redraws.

The pool's `on_query` hook counts every statement executed, and the running
total is shown in the dashboard header on each redraw.

Requires `Future::Selector`, which is not needed by the library itself.

Run it with:

```bash
DATABASE_URL="postgresql://postgres:test@localhost:5432/test" perl -Ilib examples/08-live-dashboard/app.pl
```

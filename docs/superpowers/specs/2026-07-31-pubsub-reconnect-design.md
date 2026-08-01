# Pub/sub listener reconnect

Design for gaps items 17 and 49: a `LISTEN` connection that dies stays dead, and
every subscription on it is lost.

## Measured behaviour today

Killing the listener's backend with `pg_terminate_backend` from a separate
connection gives:

```
[pool warn] PubSub listener stopped: pg_notifies failed: server closed the
            connection unexpectedly
after kill: cpu=0.00s over wall=1.97s -> idle
listener future: FAILED
is_connected still reports: 1
subscribed_channels: 1
after kill: got=[before]        # a notification sent after the kill never arrived
```

Two claims in the gaps document are wrong and are corrected by this:

- It does **not** spin on end of file. The loop fails cleanly; CPU use is zero.
- It is **not** entirely silent. The failure reaches `on_log`.

What is actually broken is narrower:

- `is_connected` reports true while holding a dead connection.
- Delivery stops permanently, with no recovery.
- `notify` keeps working, because it borrows a pool connection rather than the
  listener.

Two facts make the fix straightforward, and both were verified rather than
assumed:

- The listener future **fails**, so `_start_listener`'s existing `on_fail` is a
  precise trigger. No health checking or polling is needed.
- The channel registry **survives** the failure, so it can be replayed as is.

## Scope

Reconnect belongs in this distribution, not in a companion one. The deciding
precedent is `PAGI::Middleware::Channels`, whose Redis backend constructs its
subscriber with `reconnect => $r->{reconnect} // 0` and delegates connection
resilience wholly to `Async::Redis`. A future `Channels::Backend::Pg` should be
able to do the same, or it will be structurally different from the Redis
backend for no reason.

The layering that follows:

| layer | owns |
| --- | --- |
| `Async::DBD::Pg` | keeping the listener alive, resubscribing, reporting gaps |
| `Channels::Backend::Pg` | presence, patterns, history and replay, delayed delivery |

Notifications emitted while disconnected are lost; PostgreSQL `LISTEN`/`NOTIFY`
has neither persistence nor replay. This design does not pretend otherwise. It
restores the subscription and says when it did so; making delivery reliable is a
messaging concern, and `Channels::Backend::Role::History` already exists to
serve it.

## Public interface

New options on the pool constructor, which is where a Channels backend would
set them:

| option | default | meaning |
| --- | --- | --- |
| `reconnect` | `0` | re-establish the listener after it fails |
| `reconnect_min_interval` | `0.5` | first backoff ceiling, seconds |
| `reconnect_max_interval` | `30` | largest backoff ceiling, seconds |
| `on_reconnect` | none | called after subscriptions are restored |

Off by default, spelled as in the Channels Redis backend, so nothing changes for
current users unless they ask for it.

They are set on the pool because that is the object an application constructs;
`pubsub` takes no arguments. The pool stores them and the pub/sub object reads
them from it, in the same way it already reaches the pool for `_log`.

These govern the loss of a listener that was already running. A `connect` that
fails on its first attempt still fails to its caller, because the caller is
there to be told; reconnect exists for the case where nobody is waiting.

`on_reconnect` is called with the pub/sub object once the channels have been
re-subscribed and the listener is running again. It exists so a consumer can
resync: it means "you may have missed notifications", not merely "we are back".

No `on_disconnect`. Losing the listener, and each failed attempt, is reported
through the existing `_log`, which already reaches the pool's `on_log`. Adding a
second callback for the same event is surface without a use.

`is_connected` returning true while the connection is dead is a bug in its own
right and is fixed regardless of whether `reconnect` is set.

## Reconnect supervisor

One `async sub` held on the pub/sub object so it can be cancelled. Never
retained: the reference on the object is what keeps it alive, and what lets
`disconnect` and shutdown stop it.

Triggered from the `on_fail` already attached in `_start_listener`, when
`reconnect` is set and `_stopping` is not.

1. Report the loss honestly: `connected = 0`, drop `conn`, and `release` the
   dead connection. Release already does the right thing, since its liveness
   check fails and the pool discards it. No special case, no leak.
2. Wait for the backoff interval.
3. Check whether an ordinary `connect`/`listen` already re-established the
   connection while this loop was asleep. If so, skip taking a second
   connection of our own -- taking one anyway would leave the winner's
   connection checked out to nobody -- and go straight to replaying channels
   below.
4. Otherwise, take a fresh connection from the pool by the ordinary
   `connection` path, so async connect, `on_connect` and pool accounting all
   apply unchanged.
5. Issue `LISTEN` for every channel in the registry, through
   `_run_control_query` rather than a direct query, so a connection that dies
   again mid-replay is retried by this loop rather than escaping uncaught.
6. Start the listener loop, then call `on_reconnect`.
7. On failure at any step: log, lengthen the backoff, and repeat.

### Backoff

The ceiling doubles from `reconnect_min_interval` to `reconnect_max_interval`:
0.5, 1, 2, 4, 8, 16, 30, 30, ... The wait actually used is equal jitter, half the
ceiling plus a random half. A predictable floor, but decorrelated, so a server
coming back does not receive every listener's reconnect at the same instant. The
same stampede reasoning as the jitter in item 50.

Split for testability: `_backoff_ceiling($attempt, $min, $max)` is pure and
asserted exactly; the jitter wrapper is asserted to land within
`[ceiling / 2, ceiling]`. Neither test stubs `rand`.

Retries are unbounded. Every attempt is logged, so a listener retrying for an
hour is visible rather than silent.

## Stopping

The supervisor must not outlive its reasons to exist. This is the defect class
that produced items 61 through 64, so each exit is explicit:

- `disconnect` cancels it and does not reconnect.
- `_pool_shutdown` cancels it.
- If the pool shuts down mid-retry, the loop checks the pool's own
  `_shutting_down` state directly rather than matching `$err`'s text against a
  message. A message match was tried and rejected: PostgreSQL raises its own
  `FATAL: the database system is shutting down` on a restart, which the same
  pattern would also catch -- and give up on permanently, for the headline
  scenario this whole feature exists to survive. Shutdown fails a queued
  waiter before it cancels the supervisor, so a loop suspended waiting on a
  connection still learns about the shutdown by exception, then checks the
  flag and stops rather than retrying forever against a closed pool.
- `_stopping` is respected, so reconnect and `_run_control_query` cannot fight
  over the connection.

## Testing

Integration, against a real server:

- Listen, terminate the backend from a separate connection, then assert
  `is_connected` goes false, the listener returns, `on_reconnect` fires, the
  channel is subscribed again, and **a notification sent afterwards is actually
  delivered**. The delivery assertion is the one that matters; every other check
  could pass while delivery stayed broken.
- With `reconnect` unset, behaviour is unchanged: the listener fails and nothing
  retries.
- Killing the backend and then calling `shutdown` mid-backoff completes, and the
  supervisor stops.

Unit:

- `_backoff_ceiling` sequence and cap.
- Jitter within bounds.
- `is_connected` false while down, with reconnect off.

## Out of scope

- Replay of notifications missed while disconnected. Not possible with
  `LISTEN`/`NOTIFY` alone; belongs to a messaging layer with its own storage.
- `on_disconnect`. Covered by `on_log`.
- Reconnecting a pooled connection in place. Rejected: it would duplicate
  connect logic and bypass pool accounting, which is what caused several of the
  defects already fixed.

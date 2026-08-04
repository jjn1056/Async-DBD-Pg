# PubSub terminal phase design

**Goal:** let a caller tell "teardown is in progress, retry shortly" from "this
pub/sub is finished, stop asking" — which today are indistinguishable.

## The defect

`PubSub` refuses work while `{phase}` is `'closing'`, and both `disconnect()`
and `_pool_shutdown()` set that value. Measured on the current `main`:

    during disconnect:   PubSub is disconnecting   -> retrying works
    after pool shutdown: PubSub is disconnecting   -> terminal

Identical error, opposite correct responses. A caller writing retry logic
either spins forever against a dead object or abandons one that was about to
become usable. This is caller-visible behaviour, not internal tidiness.

Recorded as gaps item 72. It was originally noted as "nothing depends on
distinguishing the two today"; stress-testing on 2026-08-04 showed the caller
does.

## Why it is like this

The overloading was deliberate, and the reasoning in `_pool_shutdown` is sound:

> Left at `'closing'` rather than reset to `'disconnected'` afterward ...
> chosen because it is the honest answer — unlike `disconnect()`, a
> pool-shut-down pubsub is not going to reconnect, and `'disconnected'` [would
> wrongly imply it could].

Given only the four existing phases, `'closing'` really was the least
misleading option: `'disconnected'` means "connectable again", which is false.
The mistake was accepting a two-way choice instead of adding the state the
object actually has.

## Design

A fifth phase, `'shut'`, meaning terminally finished. `_pool_shutdown()` ends
there instead of at `'closing'`; `disconnect()` is unchanged and still ends at
`'disconnected'`.

Refusals then carry the message that matches the state, following the pool's
existing vocabulary rather than inventing one:

| situation | phase | message |
|---|---|---|
| `disconnect()` in progress | `closing` | `PubSub is disconnecting` |
| pool shut down, or `DESTROY` | `shut` | `PubSub has been shut down` |

The pool already distinguishes exactly this way — `'Connection pool is shutting
down'` for waiters failed mid-shutdown, `'Connection pool has been shut down'`
for requests arriving afterwards. Matching it keeps one vocabulary across the
library, and a caller who already handles the pool's pair needs no new concept.

Both remain `Async::DBD::Pg::Error::Connection`. No new error class and no new
attribute: this is the smallest change that removes the ambiguity, and it is
consistent with what the pool already does.

## The part that is not a rename

Adding a phase value breaks any test written as "not `closing`". There are two,
both in `_reconnect_loop`, and both would misbehave rather than fail loudly:

    while ($self->{phase} ne 'closing') {   # :415 -- spins forever once 'shut'
    last if $self->{phase} eq 'closing';    # :426 -- never stops on 'shut'

So the supervisor would keep running against a pub/sub whose pool is gone. Both
must become a positive test. Introduce one predicate rather than repeating the
disjunction:

```perl
# True once teardown has begun, whether it will finish in a reconnectable
# state (disconnect) or a terminal one (pool shutdown). Anything that must
# stop working asks this; anything that must distinguish retry-later from
# give-up reads {phase} directly.
sub _tearing_down {
    my $phase = shift->{phase};
    return $phase eq 'closing' || $phase eq 'shut';
}
```

Every site, and what it becomes:

| line | current | becomes | why |
|---|---|---|---|
| `:41` | `is_connected`: `phase eq 'live'` | unchanged | already positive |
| `:89` | `connect` fast path: `eq 'live'` | unchanged | already positive |
| `:105` | `connect` refuses: `eq 'closing'` | `_tearing_down`, message by phase | must refuse in both |
| `:201` | `listen`: `unless eq 'live'` | unchanged | `connect` does the refusing |
| `:319` | `_listener_loop`: `while eq 'live'` | unchanged | already positive |
| `:356` | `_start_listener`: `eq 'live'` | unchanged | already positive |
| `:366` | on_fail: `ne 'live'` | unchanged | positive in effect |
| `:415` | `_reconnect_loop`: `while ne 'closing'` | `while !_tearing_down` | **would spin** |
| `:426` | `_reconnect_loop`: `last if eq 'closing'` | `last if _tearing_down` | **would not stop** |
| `:520` | `_run_control_query` refuses | `_tearing_down`, message by phase | must refuse in both |
| `:621` | `disconnect` early return | see below | **would resurrect** |

## The resurrection hazard

`disconnect()`'s early return is reachable on an already-shut object:

```perl
unless ($self->{phase} eq 'live' || $self->{conn}) {
    $self->{channels} = {};
    $self->{phase}    = 'disconnected';   # <-- from 'shut'
    return $self;
}
```

Calling `disconnect()` after the pool has shut down currently moves the phase
to `'disconnected'`, which claims the object is connectable again. Today that
is merely misleading — the next `connect()` fails at the pool with
`'Connection pool has been shut down'`, so the user still gets a sensible
error, from the wrong layer. Once `'shut'` exists it becomes wrong outright: a
terminal state must not be reversible by a call that does nothing.

`disconnect()` must leave `'shut'` alone. Everything else about it is
unchanged.

## Testing

Each of these must be shown failing before the change:

1. **The defect itself.** Refuse during `disconnect()` and after pool shutdown,
   and assert the two errors differ — specifically that the terminal one says
   "has been shut down" and the transient one does not. This is the test that
   fails on today's code with both messages identical.
2. **Retry actually works after the transient refusal**, and the terminal one
   stays refused. The messages are only worth distinguishing if they predict
   behaviour.
3. **The reconnect supervisor stops on `'shut'`.** Bounded, so a regression
   reports a missed deadline rather than hanging the suite — a spinning
   supervisor is the failure mode, and an unbounded assertion would hang
   instead of failing.
4. **`disconnect()` does not resurrect a shut pub/sub**: phase stays `'shut'`
   and a subsequent `listen()` still reports the terminal message.
5. Both refusal sites — `connect()` and `_run_control_query()` — reach the
   terminal message, not just whichever one a convenience method happens to
   hit.

Mutation-verify by reverting `_pool_shutdown` to set `'closing'`: test 1 must
red on the message comparison rather than on setup.

## Not changing

- **`disconnect()`'s own lifecycle.** Still `closing` → `disconnected`, still
  reconnectable afterwards. It is the terminal case that lacked a state.
- **The error class.** Both stay `Error::Connection`; the message carries the
  distinction, as it already does in the pool.
- **The `{_control_query}` mutex**, the single-reader listener, and the
  teardown ordering. None of them read the distinction being added.

## Risk

Small and contained. The change is one new phase value, one predicate, four
call sites and the `disconnect()` early return, in a file with 51 subtests of
existing coverage. The one way it goes wrong quietly is a missed `ne 'closing'`
site turning into a spin rather than an error, which is why the audit table
above enumerates every phase test in the file rather than the ones that
obviously need editing.

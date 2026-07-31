# Pub/sub Listener Reconnect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a `LISTEN` connection dies, re-establish it, re-subscribe every channel, and tell the application it happened.

**Architecture:** The listener loop's future already fails when the connection dies, so that failure is the trigger; no health checking is added. A supervisor async sub releases the dead connection, waits a jittered exponential backoff, takes a fresh connection from the pool by the ordinary path, re-issues `LISTEN` for every channel in the surviving registry, restarts the listener, and calls `on_reconnect`. It is held on the pub/sub object so `disconnect` and pool shutdown can cancel it.

**Tech Stack:** Perl, Future::AsyncAwait, Future::IO, DBD::Pg, Test2::V0.

## Global Constraints

- Design document: `docs/superpowers/specs/2026-07-31-pubsub-reconnect-design.md`.
- Run all Perl via perlbrew: `source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default`.
- Integration tests need PostgreSQL. This machine runs it on port 5433:
  `TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test"`.
- Set `PERL_FUTURE_IO_IMPL=UV` (or `IOAsync`) when running tests; both must pass.
- Test output must be pristine. A warning printed during a passing run is a failure.
- Never use `->retain`. A future must be owned by something that can cancel it.
- Anything that must be undone cannot be undone by code after an `await`; a caller
  may cancel while the sub is suspended. Use a guard destructor or a callback on
  the future.
- Every new public option or method gets POD in the same commit that adds it.
- `reconnect` defaults to **0** (off). Existing behaviour must not change unless it is set.

---

### Task 1: Report the listener as disconnected when it dies

`is_connected` returns true while holding a dead connection. This is a defect on
its own and is fixed first, independent of reconnect, so later tasks can rely on
it.

**Files:**
- Modify: `lib/Async/DBD/Pg/PubSub.pm` (the `on_fail` handler at lines 227-232)
- Test: `t/integration/pubsub.t`

**Interfaces:**
- Consumes: nothing.
- Produces: after the listener future fails, `$pubsub->is_connected` is false and
  `$pubsub->{conn}` is undef. The channel registry is untouched, so
  `subscribed_channels` keeps its count.

- [ ] **Step 1: Write the failing test**

Add to `t/integration/pubsub.t`, before `done_testing`:

```perl
subtest 'a dead listener reports itself disconnected' => sub {
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 4,
        on_log          => sub { push @logged, $_[1] },
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('death_reporting', sub { })->get;
    ok $pubsub->is_connected, 'connected before the backend dies';

    kill_backends();

    wait_until(sub { !$pubsub->is_connected }, 'listener noticed', 5);

    ok !$pubsub->is_connected, 'reports disconnected once the listener fails';
    is $pubsub->conn, undef, 'dead connection let go';
    is $pubsub->subscribed_channels, 1, 'subscription registry kept for replay';
    ok scalar(grep { /listener stopped/i } @logged), 'loss reported';
};
```

Add this helper near `wait_until` at the top of the same file:

```perl
# Terminate every backend on the test database except this one. The listener
# connection cannot be asked for its own pid: querying it while its loop is
# polling the same socket makes both wait on POLLIN forever.
sub kill_backends {
    my $parsed = Async::DBD::Pg::Util::parse_dsn(test_dsn());
    my $dbh = DBI->connect(
        $parsed->{dbi_dsn}, $parsed->{user}, $parsed->{password},
        { RaiseError => 1, PrintError => 0 },
    );
    $dbh->do(q{
        SELECT pg_terminate_backend(pid) FROM pg_stat_activity
         WHERE datname = current_database() AND pid <> pg_backend_pid()
    });
    $dbh->disconnect;
    return;
}
```

Add these to the `use` statements at the top of `t/integration/pubsub.t` if not
already present:

```perl
use DBI;
use Async::DBD::Pg::Util ();
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
PERL_FUTURE_IO_IMPL=UV TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
prove -l -It/lib -v t/integration/pubsub.t
```
Expected: FAIL on "reports disconnected once the listener fails" — `is_connected`
still returns 1.

- [ ] **Step 3: Write minimal implementation**

In `lib/Async/DBD/Pg/PubSub.pm`, replace the `on_fail` handler in
`_start_listener` (lines 227-232) with:

```perl
    $listener->on_fail(sub {
        my ($err) = @_;
        my $self = $weak_self or return;
        return if $self->{_stopping};

        $self->_log(warn => "PubSub listener stopped: $err");

        # The connection is gone. Say so rather than continuing to report a
        # connection that cannot deliver anything, and hand it back so the
        # pool discards it instead of holding it checked out to nobody.
        $self->{connected} = 0;
        if (my $conn = delete $self->{conn}) {
            $conn->release;
        }
    });
```

- [ ] **Step 4: Run test to verify it passes**

Run the same command as Step 2. Expected: PASS.

Then run the whole suite under both implementations and confirm no warnings leak:
```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
for impl in UV IOAsync; do
  PERL_FUTURE_IO_IMPL=$impl TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
  prove -r -l -It/lib t/ | tail -3
done
```
Expected: PASS for both.

- [ ] **Step 5: Commit**

```bash
git add lib/Async/DBD/Pg/PubSub.pm t/integration/pubsub.t
git commit -m "Report the pub/sub listener as disconnected when it dies

is_connected returned true while holding a connection that had failed,
so an application could not tell a working listener from a dead one. The
failure handler now clears the flag and releases the connection, which
the pool discards because its liveness check fails.

The channel registry is deliberately left alone: it is what a reconnect
replays."
```

---

### Task 2: Backoff schedule

A pure function, so the schedule can be asserted exactly without waiting or
stubbing `rand`.

**Files:**
- Modify: `lib/Async/DBD/Pg/PubSub.pm` (add two subs after `_log`, which ends at line 50)
- Test: `t/unit/pubsub.t`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Async::DBD::Pg::PubSub::_backoff_ceiling($attempt, $min, $max)` — `$attempt`
    counts from 1; returns a number: `$min` doubled `$attempt - 1` times, capped
    at `$max`.
  - `Async::DBD::Pg::PubSub::_backoff_delay($attempt, $min, $max)` — returns a
    number in `[ceiling / 2, ceiling]`.

- [ ] **Step 1: Write the failing test**

Add to `t/unit/pubsub.t`, before `done_testing`:

```perl
subtest 'backoff ceiling doubles and then holds' => sub {
    my @ceilings = map {
        Async::DBD::Pg::PubSub::_backoff_ceiling($_, 0.5, 30)
    } 1 .. 8;

    is \@ceilings, [ 0.5, 1, 2, 4, 8, 16, 30, 30 ],
        'doubles from the minimum and stops at the maximum';

    is Async::DBD::Pg::PubSub::_backoff_ceiling(1, 2, 10), 2,
        'first attempt waits the minimum';
    is Async::DBD::Pg::PubSub::_backoff_ceiling(99, 0.5, 30), 30,
        'never exceeds the maximum';
};

subtest 'backoff delay is jittered within its ceiling' => sub {
    # Equal jitter: half the ceiling, plus a random half. Decorrelates many
    # listeners reconnecting at once while keeping a predictable floor.
    for my $attempt (1 .. 6) {
        my $ceiling = Async::DBD::Pg::PubSub::_backoff_ceiling($attempt, 0.5, 30);

        for (1 .. 20) {
            my $delay = Async::DBD::Pg::PubSub::_backoff_delay($attempt, 0.5, 30);
            ok $delay >= $ceiling / 2, "attempt $attempt delay at or above half the ceiling";
            ok $delay <= $ceiling,     "attempt $attempt delay at or below the ceiling";
        }
    }
};
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
prove -l -It/lib -v t/unit/pubsub.t
```
Expected: FAIL with `Undefined subroutine &Async::DBD::Pg::PubSub::_backoff_ceiling called`.

- [ ] **Step 3: Write minimal implementation**

In `lib/Async/DBD/Pg/PubSub.pm`, insert after `_log` (which ends at line 50):

```perl
# How long to wait before reconnect attempt $attempt, counting from 1. The
# ceiling doubles from the minimum until it reaches the maximum and stays
# there.
sub _backoff_ceiling {
    my ($attempt, $min, $max) = @_;

    my $ceiling = $min * (2 ** ($attempt - 1));

    return $ceiling > $max ? $max : $ceiling;
}

# Equal jitter: half the ceiling plus a random half. Keeps a predictable floor
# while spreading out many listeners reconnecting to the same server, so one
# coming back does not receive every reconnect at the same instant.
sub _backoff_delay {
    my ($attempt, $min, $max) = @_;

    my $ceiling = _backoff_ceiling($attempt, $min, $max);

    return ($ceiling / 2) + rand($ceiling / 2);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/Async/DBD/Pg/PubSub.pm t/unit/pubsub.t
git commit -m "Add the reconnect backoff schedule

A ceiling that doubles from the minimum to the maximum, and an equal
jitter delay of half that ceiling plus a random half. Splitting the two
lets the schedule be asserted exactly without waiting on timers or
stubbing rand, and the jitter keeps many listeners from reconnecting to
a recovering server in lockstep."
```

---

### Task 3: Carry the reconnect options from the pool

The options are set on the pool, because that is what an application constructs;
`pubsub` takes no arguments.

**Files:**
- Modify: `lib/Async/DBD/Pg.pm` (constructor hash starting line 57; POD near the `on_log` entry)
- Modify: `lib/Async/DBD/Pg/PubSub.pm` (`new`, lines 10-25)
- Test: `t/unit/pubsub.t`

**Interfaces:**
- Consumes: nothing.
- Produces: `$pubsub->{reconnect}`, `$pubsub->{reconnect_min_interval}`,
  `$pubsub->{reconnect_max_interval}`, `$pubsub->{on_reconnect}`, read from the
  pool at construction. Defaults `0`, `0.5`, `30`, `undef`.

- [ ] **Step 1: Write the failing test**

Add to `t/unit/pubsub.t`, before `done_testing`:

```perl
subtest 'reconnect settings are taken from the pool' => sub {
    my $off = Async::DBD::Pg->new(
        dsn             => 'postgresql://user:secret@localhost/test',
        min_connections => 0,
        max_connections => 1,
    )->pubsub;

    is $off->{reconnect}, 0, 'reconnect is off unless asked for';
    is $off->{reconnect_min_interval}, 0.5, 'default minimum interval';
    is $off->{reconnect_max_interval}, 30, 'default maximum interval';
    is $off->{on_reconnect}, undef, 'no reconnect callback by default';

    my $cb = sub { };
    my $on = Async::DBD::Pg->new(
        dsn                    => 'postgresql://user:secret@localhost/test',
        min_connections        => 0,
        max_connections        => 1,
        reconnect              => 1,
        reconnect_min_interval => 2,
        reconnect_max_interval => 60,
        on_reconnect           => $cb,
    )->pubsub;

    is $on->{reconnect}, 1, 'reconnect enabled';
    is $on->{reconnect_min_interval}, 2, 'minimum interval carried across';
    is $on->{reconnect_max_interval}, 60, 'maximum interval carried across';
    is $on->{on_reconnect}, $cb, 'callback carried across';
};
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
prove -l -It/lib -v t/unit/pubsub.t
```
Expected: FAIL — `$off->{reconnect}` is undef, not 0.

- [ ] **Step 3: Write minimal implementation**

In `lib/Async/DBD/Pg.pm`, add to the constructor hash immediately after the
`on_log` line (line 70):

```perl
        # Pub/sub reconnect. Set on the pool because that is what an
        # application constructs; pubsub takes no arguments.
        reconnect              => delete $args{reconnect}              // 0,
        reconnect_min_interval => delete $args{reconnect_min_interval} // 0.5,
        reconnect_max_interval => delete $args{reconnect_max_interval} // 30,
        on_reconnect           => delete $args{on_reconnect},
```

In `lib/Async/DBD/Pg/PubSub.pm`, replace `new` (lines 10-25) with:

```perl
sub new {
    my ($class, %args) = @_;

    my $pool = $args{pool};

    my $self = bless {
        pool             => $pool,
        conn             => undef,
        channels         => {},
        connected        => 0,
        _listener_future => undef,
        _stopping        => 0,

        # Read from the pool, which is where an application sets them.
        reconnect              => $pool ? $pool->{reconnect}              : 0,
        reconnect_min_interval => $pool ? $pool->{reconnect_min_interval} : 0.5,
        reconnect_max_interval => $pool ? $pool->{reconnect_max_interval} : 30,
        on_reconnect           => $pool ? $pool->{on_reconnect}           : undef,

        _reconnect_future => undef,
    }, $class;

    weaken($self->{pool}) if $self->{pool};

    return $self;
}
```

Add POD to `lib/Async/DBD/Pg.pm`, immediately after the `=head3 on_log` entry
and before `=head2 connection`:

```pod
=head3 reconnect

Re-establish the pub/sub listener when its connection fails, re-subscribing
every channel that was registered. Off by default.

A listener is long lived, so the connection it holds will eventually be lost to
a network fault, a failover or a server restart. Without this, the subscription
is gone and nothing arrives again.

Notifications sent while the listener was down are not recovered.
C<LISTEN>/C<NOTIFY> keeps no history, so there is nothing to replay. What this
gives you is a listener that comes back and tells you it did; if you need to
know what you missed, resynchronise from your own tables when L</on_reconnect>
fires.

=head3 reconnect_min_interval

Seconds to wait before the first reconnect attempt. Defaults to 0.5.

=head3 reconnect_max_interval

Longest the wait between attempts may grow to. Defaults to 30.

The wait doubles from the minimum towards this ceiling and is then jittered, so
many listeners reconnecting to the same server do not arrive together. Attempts
continue indefinitely; each one is reported through L</on_log>.

=head3 on_reconnect

    on_reconnect => sub {
        my ($pubsub) = @_;
        ...
    },

Called after the listener has been re-established and every channel
re-subscribed. Read it as "you may have missed notifications", and resynchronise
if that matters to you.

```

- [ ] **Step 4: Run test to verify it passes**

Run the same command as Step 2. Expected: PASS.

Check the POD is well formed:
```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
podchecker lib/Async/DBD/Pg.pm
```
Expected: `pod syntax OK`, with no warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/Async/DBD/Pg.pm lib/Async/DBD/Pg/PubSub.pm t/unit/pubsub.t
git commit -m "Carry the reconnect settings from the pool to pub/sub

The options belong on the pool because that is the object an
application constructs; pubsub takes no arguments. The pub/sub object
reads them from the pool the same way it already reaches it for logging.

Off by default and spelled as in the Channels Redis backend, which
passes reconnect through to Async::Redis rather than implementing it."
```

---

### Task 4: The reconnect supervisor

**Files:**
- Modify: `lib/Async/DBD/Pg/PubSub.pm` (the `on_fail` handler from Task 1; add `_reconnect_loop`; `disconnect` at line 274; `_pool_shutdown` at line 293)
- Test: `t/integration/pubsub.t`

**Interfaces:**
- Consumes: `_backoff_delay` from Task 2; the settings from Task 3; the
  disconnect reporting from Task 1.
- Produces: `$pubsub->{_reconnect_future}`, held while a reconnect is in
  progress and cancelled by `disconnect` and `_pool_shutdown`.

- [ ] **Step 1: Write the failing test**

Add to `t/integration/pubsub.t`, before `done_testing`:

```perl
subtest 'the listener comes back after the connection dies' => sub {
    my @reconnected;
    my $pg = Async::DBD::Pg->new(
        dsn                    => test_dsn(),
        min_connections        => 0,
        max_connections        => 4,
        reconnect              => 1,
        reconnect_min_interval => 0.1,
        reconnect_max_interval => 0.5,
        on_reconnect           => sub { push @reconnected, $_[0] },
        on_log                 => sub { },
    );
    my $pubsub = $pg->pubsub;

    my @got;
    $pubsub->listen('revival', sub { push @got, $_[1] })->get;

    $pubsub->notify('revival', 'before')->get;
    wait_until(sub { @got }, 'delivery before the kill', 3);
    is \@got, ['before'], 'delivering before the connection dies';

    kill_backends();

    wait_until(sub { @reconnected }, 'reconnected', 15);
    ok scalar @reconnected, 'on_reconnect fired';
    ok $pubsub->is_connected, 'connected again';
    is $pubsub->subscribed_channels, 1, 'channel still subscribed';

    # The assertion that matters. Everything above could pass while nothing
    # was actually being delivered any more.
    $pubsub->notify('revival', 'after')->get;
    wait_until(sub { @got > 1 }, 'delivery after the reconnect', 5);
    is \@got, ['before', 'after'], 'notifications flow again';

    $pubsub->disconnect->get;
};

subtest 'without reconnect the listener stays down' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 4,
        on_log          => sub { },
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('stays_down', sub { })->get;

    kill_backends();
    wait_until(sub { !$pubsub->is_connected }, 'listener noticed', 5);

    # Give a reconnect long enough to have happened, had one been asked for.
    Future::IO->sleep(1)->get;

    ok !$pubsub->is_connected, 'stays disconnected when reconnect is off';
};
```

- [ ] **Step 2: Run test to verify it fails**

Run:
```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
PERL_FUTURE_IO_IMPL=UV TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
prove -l -It/lib -v t/integration/pubsub.t
```
Expected: FAIL on "on_reconnect fired" — nothing reconnects. The second subtest
passes already; it guards the default.

- [ ] **Step 3: Write minimal implementation**

In `lib/Async/DBD/Pg/PubSub.pm`, replace the `on_fail` handler written in Task 1
with one that also starts the supervisor:

```perl
    $listener->on_fail(sub {
        my ($err) = @_;
        my $self = $weak_self or return;
        return if $self->{_stopping};

        $self->_log(warn => "PubSub listener stopped: $err");

        # The connection is gone. Say so rather than continuing to report a
        # connection that cannot deliver anything, and hand it back so the
        # pool discards it instead of holding it checked out to nobody.
        $self->{connected} = 0;
        if (my $conn = delete $self->{conn}) {
            $conn->release;
        }

        return unless $self->{reconnect};
        return if $self->{_reconnect_future};

        # Held on the object rather than retained, so disconnect and pool
        # shutdown can stop it.
        $self->{_reconnect_future} = $self->_reconnect_loop;
    });
```

Add `_reconnect_loop` immediately after `_start_listener` (which ends at line 237):

```perl
# Re-establish a listener that failed, replaying its subscriptions. Runs until
# it succeeds, or until something cancels it.
async sub _reconnect_loop {
    my ($self) = @_;

    my $attempt = 0;

    while (!$self->{_stopping}) {
        $attempt++;

        my $delay = _backoff_delay(
            $attempt,
            $self->{reconnect_min_interval},
            $self->{reconnect_max_interval},
        );

        await Future::IO->sleep($delay);

        last if $self->{_stopping};

        my $ok = eval {
            my $pool = $self->{pool}
                or die "pool is gone\n";

            $self->{conn}      = await $pool->connection;
            $self->{connected} = 1;

            # Replay every registered channel onto the new connection.
            for my $channel (sort keys %{ $self->{channels} }) {
                await $self->{conn}->query("LISTEN $channel");
            }

            await $self->_start_listener;
            1;
        };
        my $err = $@;

        if ($ok) {
            delete $self->{_reconnect_future};

            # Success is reported through on_reconnect, not through _log. With
            # no on_log configured _log falls back to warn, and a recovery that
            # worked should not print to STDERR.
            if (my $cb = $self->{on_reconnect}) {
                eval { $cb->($self) };
                $self->_log(warn => "on_reconnect callback failed: $@") if $@;
            }

            return $self;
        }

        # Hand back anything acquired before the failure, so a half-built
        # attempt does not keep a connection checked out.
        $self->{connected} = 0;
        if (my $conn = delete $self->{conn}) {
            $conn->release;
        }

        # A pool that has shut down is never going to give us a connection.
        # The pool raises "has been shut down" for a fresh request and "is
        # shutting down" for one already queued; match both.
        if ($err =~ /shut(?:ting)? down/i) {
            $self->_log(warn => "PubSub giving up on reconnect: $err");
            delete $self->{_reconnect_future};
            return $self;
        }

        $self->_log(warn => "PubSub reconnect attempt $attempt failed: $err");
    }

    delete $self->{_reconnect_future};

    return $self;
}
```

In `disconnect` (line 274), stop any reconnect before anything else. Replace its
first lines so the body begins:

```perl
async sub disconnect {
    my ($self) = @_;

    # Stop trying to come back before tearing down; otherwise a reconnect in
    # flight would re-establish the listener behind us.
    $self->{_stopping} = 1;
    if (my $reconnecting = delete $self->{_reconnect_future}) {
        $reconnecting->cancel unless $reconnecting->is_ready;
    }

    return $self unless $self->{connected} || $self->{conn};
```

Leave the rest of `disconnect` unchanged; it already sets `_stopping` back to 0
at the end.

In `_pool_shutdown` (line 293), cancel the supervisor too. Insert immediately
after `$self->{_stopping} = 1;`:

```perl
    if (my $reconnecting = delete $self->{_reconnect_future}) {
        $reconnecting->cancel unless $reconnecting->is_ready;
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run the same command as Step 2. Expected: PASS.

Then the whole suite, both implementations, checking for stray output:
```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
for impl in UV IOAsync; do
  PERL_FUTURE_IO_IMPL=$impl TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
  prove -r -l -It/lib t/ | tail -3
done
PERL_FUTURE_IO_IMPL=UV TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
  prove -r -l -It/lib t/ 2>&1 | grep -vE '^(ok|not ok|1\.\.|#|t/|All tests|Files=|Result:|\s)'
```
Expected: PASS for both, and the grep prints nothing.

- [ ] **Step 5: Commit**

```bash
git add lib/Async/DBD/Pg/PubSub.pm t/integration/pubsub.t
git commit -m "Re-establish the pub/sub listener after it fails

A listener runs for as long as the application does, so its connection
will eventually be lost to a fault, a failover or a restart. Until now
that ended delivery permanently: the subscription was gone and nothing
said so beyond one log line.

The listener future already fails when the connection dies, so that is
the trigger; no health checking is added. The supervisor releases the
dead connection, waits a jittered backoff, takes a fresh connection by
the ordinary pool path, replays every registered channel, restarts the
listener and calls on_reconnect.

It is held on the object rather than retained, so disconnect and pool
shutdown both stop it, and a pool that has shut down ends the attempts
rather than retrying against a closed pool forever."
```

---

### Task 5: Shutting down while reconnecting

The supervisor sleeps between attempts, so shutdown will usually land while it
is suspended. That is the case that has bitten this distribution repeatedly.

**Files:**
- Test: `t/pool/shutdown.t`

**Interfaces:**
- Consumes: everything from Task 4.
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

Add to `t/pool/shutdown.t`, before `done_testing`:

```perl
subtest 'shutdown completes while a listener is trying to reconnect' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn                    => test_dsn(),
        min_connections        => 0,
        max_connections        => 4,
        reconnect              => 1,
        reconnect_min_interval => 0.2,
        reconnect_max_interval => 1,
        on_log                 => sub { },
    );
    my $pubsub = $pg->pubsub;

    $pubsub->listen('shutdown_while_reconnecting', sub { })->get;

    # Kill the listener's connection, then shut down while the supervisor is
    # asleep between attempts.
    my $parsed = Async::DBD::Pg::Util::parse_dsn(test_dsn());
    my $dbh = DBI->connect(
        $parsed->{dbi_dsn}, $parsed->{user}, $parsed->{password},
        { RaiseError => 1, PrintError => 0 },
    );
    $dbh->do(q{
        SELECT pg_terminate_backend(pid) FROM pg_stat_activity
         WHERE datname = current_database() AND pid <> pg_backend_pid()
    });
    $dbh->disconnect;

    Future::IO->sleep(0.3)->get;    # let it fail and start backing off

    settle($pg->shutdown, 10);

    ok $pg->is_shut_down, 'shutdown completed';
    is $pg->total_count, 0, 'pool empty';

    # Nothing may reconnect afterwards and put a connection back.
    Future::IO->sleep(1.5)->get;
    is $pg->total_count, 0, 'still empty once the backoff would have elapsed';
};
```

Add these to the `use` statements at the top of `t/pool/shutdown.t` if not
already present:

```perl
use DBI;
use Async::DBD::Pg::Util ();
```

- [ ] **Step 2: Run test to verify it fails or passes**

Run:
```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
PERL_FUTURE_IO_IMPL=UV TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
prove -l -It/lib -v t/pool/shutdown.t
```

This test may pass immediately, because Task 4 cancels the supervisor in
`_pool_shutdown`. That is a legitimate outcome for a regression test guarding a
known defect class: record it and go on. If it fails, fix it in Step 3 before
continuing.

- [ ] **Step 3: Fix only if Step 2 failed**

If shutdown hung, the supervisor was not cancelled. Confirm the block added to
`_pool_shutdown` in Task 4 is present and runs before the connection is
released:

```perl
    if (my $reconnecting = delete $self->{_reconnect_future}) {
        $reconnecting->cancel unless $reconnecting->is_ready;
    }
```

If a connection reappeared after shutdown, the supervisor acquired one after the
pool closed. `_release_to_idle_or_waiting` already closes connections returned
during shutdown, so check the supervisor is reaching the "shut down" branch and
returning rather than looping.

- [ ] **Step 4: Run the whole suite**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
for impl in UV IOAsync; do
  PERL_FUTURE_IO_IMPL=$impl TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
  prove -r -l -It/lib t/ | tail -3
done
```
Expected: PASS for both.

- [ ] **Step 5: Commit**

```bash
git add t/pool/shutdown.t
git commit -m "Cover shutting down while a listener is reconnecting

The supervisor spends most of its life asleep between attempts, so a
shutdown will usually arrive while it is suspended. That is the shape
that produced several defects here already: state restored after an
await is never restored when the sub is cancelled.

Asserts shutdown completes, and that nothing reconnects afterwards and
puts a connection back into a closed pool."
```

---

### Task 6: Record the outcome in the gaps document

**Files:**
- Modify: `docs/gaps.md` (items 17 and 49)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Update item 17**

Replace the heading `### 17. No PubSub reconnect` with
`### 17. No PubSub reconnect — FIXED`, and append after its existing text:

```markdown
Two claims here were wrong, and testing found it. Terminating the listener's
backend produces no spin on end of file: the loop fails cleanly with zero CPU
use. Nor is the failure silent; it reaches `on_log`. What was actually broken
was narrower: `is_connected` reported true while holding a dead connection, and
delivery stopped for good.

Fixed together with item 49. See
`docs/superpowers/specs/2026-07-31-pubsub-reconnect-design.md`.
```

- [ ] **Step 2: Update item 49**

Replace the heading `### 49. PubSub reconnect with subscription recovery` with
`### 49. PubSub reconnect with subscription recovery — FIXED`, and append:

```markdown
Implemented as `reconnect`, off by default, with `reconnect_min_interval`,
`reconnect_max_interval` and `on_reconnect`. The wait doubles from the minimum
to the maximum and is jittered, so many listeners do not reconnect to a
recovering server in lockstep.

Two measured facts kept this small: the listener future fails when the
connection dies, so it is already a precise trigger and no health check was
needed, and the channel registry survives the failure, so it can be replayed
unchanged.

Scope was settled by `PAGI::Middleware::Channels`, whose Redis backend passes
`reconnect` through to `Async::Redis` rather than implementing it. Reconnect
belongs to the transport client. Replay of notifications missed while
disconnected does not, and cannot be done with `LISTEN`/`NOTIFY` alone; that
belongs to a messaging layer with its own storage, where
`Backend::Role::History` already lives.
```

- [ ] **Step 3: Commit**

```bash
git add docs/gaps.md
git commit -m "Record the pub/sub reconnect work

Note that two claims in item 17 did not survive testing: the listener
does not spin on end of file, and its failure was never silent."
```

---

## Follow-up, not part of this plan

`conn` is a public accessor returning the listener's connection. Querying it
while the listener loop is polling the same socket makes both wait on `POLLIN`
and the application hangs. This was hit while writing the design. It wants its
own gaps entry and its own fix, most likely making the accessor private or
documenting the hazard loudly.

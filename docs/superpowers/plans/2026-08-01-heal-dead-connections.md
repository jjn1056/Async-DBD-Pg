# Healing Dead Connections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a pooled connection died while idle, replace it and run the caller's statement, so the caller never sees a failure the pool caused.

**Architecture:** A statement that fails at `prepare` or `execute` provably never reached the server, because with `pg_async` it is `execute` that dispatches it. If the connection is also dead, the pool builds a replacement handle through its ordinary connect path, transplants it into the `Connection` the caller is holding, discards the other idle connections that the same outage will have killed, and runs the statement once more. Anything after `execute` succeeds is never retried, and neither is anything inside a transaction.

**Tech Stack:** Perl, Future::AsyncAwait, Future::IO, DBD::Pg, Test2::V0.

## Global Constraints

- Design document: `docs/superpowers/specs/2026-08-01-heal-dead-connections-design.md`.
- Run all Perl via perlbrew: `source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default`.
- PostgreSQL for integration tests is on port 5433:
  `TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test"`.
- The suite must pass under both `PERL_FUTURE_IO_IMPL=UV` and `IOAsync`.
- Test output must be pristine. Check stderr by redirecting the streams to
  separate files and reading the stderr file. Never use a grep filter, and
  never one excluding lines that begin with whitespace: that mistake hid a
  real error from this project for a whole session.
- A full-suite run currently produces a **zero byte** stderr file. It must
  still do so when you are done.
- Killing a PostgreSQL backend makes libpq write a FATAL notice straight to
  file descriptor 2, which no Perl-level handler intercepts. Any test that
  kills a backend must capture it at descriptor level and assert it.
  `t/integration/pubsub.t` and `t/pool/shutdown.t` each already have a
  `capture_stderr` helper; `t/pool/basic.t` does not.
- Never `->retain`. A future must be owned by something that can cancel it.
- Anything that must be undone cannot be undone by code after an `await`: a
  caller may cancel while the sub is suspended and nothing after that point
  runs. Use a guard object's destructor or a callback on the future.
- Any new public option or method needs POD in the same commit.
- Module POD in `lib/Async/DBD/Pg.pm` is plain ASCII and has no `=encoding`
  line. Do not introduce non-ASCII characters into it; `podchecker` fails and
  so does `xt/author/pod-syntax.t`.
- `prove -l` prepends the project's real `lib/` ahead of any `-I`. If you run
  a scratch copy of a module to prove a test fails, do not use `-l`, and
  verify `%INC` from inside the process before trusting the result.

---

### Task 1: The `heal_dead_connections` option

Plumbing and documentation only. No behaviour changes; a later task reads this.

**Files:**
- Modify: `lib/Async/DBD/Pg.pm` (constructor hash, after the pub/sub reconnect block that ends with `on_reconnect`; POD under `=head2 new(%args)`)
- Test: `t/unit/pool-lifecycle.t`

**Interfaces:**
- Consumes: nothing.
- Produces: `$pool->{heal_dead_connections}`, defaulting to 1.

- [ ] **Step 1: Write the failing test**

Add to `t/unit/pool-lifecycle.t`, before `done_testing`:

```perl
subtest 'healing dead connections is on unless turned off' => sub {
    my $on = make_pool();
    is $on->{heal_dead_connections}, 1, 'on by default';

    my $off = make_pool(heal_dead_connections => 0);
    is $off->{heal_dead_connections}, 0, 'can be turned off';
};
```

- [ ] **Step 2: Run test to verify it fails**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
prove -l -It/lib -v t/unit/pool-lifecycle.t
```
Expected: FAIL — `heal_dead_connections` is undef, not 1.

- [ ] **Step 3: Write minimal implementation**

In `lib/Async/DBD/Pg.pm`, add to the constructor hash immediately after the
`on_reconnect` line:

```perl
        # A connection that died while idle is replaced and the caller's
        # statement run again, rather than the caller being handed a failure
        # the pool caused.
        heal_dead_connections => delete $args{heal_dead_connections} // 1,
```

Add POD immediately after the `=head3 on_reconnect` entry and before the
`=head2 connection` heading. Keep it ASCII:

```pod
=head3 heal_dead_connections

Replace a pooled connection that turns out to be dead and run the caller's
statement again, instead of failing. On by default; set to 0 to have the
original error propagate untouched.

A connection can die while sitting idle in the pool, most often because the
server restarted or an administrator ended the session. The caller who is
handed it next has done nothing wrong, so the pool repairs itself rather than
reporting a fault of its own making.

The retry is deliberately narrow. It happens only when the statement provably
never reached the server, which is the case when C<prepare> or C<execute>
fails, since it is C<execute> that dispatches a statement. Once a statement has
been sent it is never retried, because it may already have run. A statement
inside a transaction is never retried either: the transaction died with the
connection, and running the statement on a replacement would silently execute
it outside the transaction the caller asked for.

Replacing a connection is reported through L</on_log>, so a database that is
flapping is visible rather than silently absorbed.

```

- [ ] **Step 4: Run test to verify it passes**

Same command as Step 2. Expected: PASS.

Then check the POD:
```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
podchecker lib/Async/DBD/Pg.pm
```
Expected: `pod syntax OK`, no warnings.

- [ ] **Step 5: Commit**

```bash
git add lib/Async/DBD/Pg.pm t/unit/pool-lifecycle.t
git commit -m "Add the heal_dead_connections option

A connection can die while sitting idle, and the caller handed it next
has done nothing wrong. This option governs whether the pool repairs
itself rather than reporting a fault of its own making. On by default;
the behaviour it controls arrives in a later commit."
```

---

### Task 2: Discard the idle connections an outage will also have killed

Whatever killed one connection has usually killed the rest. This is a pool
method on its own, used by the next task.

**Files:**
- Modify: `lib/Async/DBD/Pg.pm` (add after `_discard_connection`)
- Test: `t/unit/pool-lifecycle.t`

**Interfaces:**
- Consumes: nothing.
- Produces: `$pool->_discard_idle_connections` — closes and discards every
  connection in the idle list, leaves the active list untouched, returns the
  number discarded.

- [ ] **Step 1: Write the failing test**

Add to `t/unit/pool-lifecycle.t`, before `done_testing`:

```perl
subtest 'discarding idle connections leaves checked out ones alone' => sub {
    my $pg = make_pool();

    my @idle_dbh = map { add_idle($pg) } 1 .. 3;

    my $busy_dbh = Test::Async::DBD::Pg::FakeDBH->new;
    push @{$pg->{active}},
        Async::DBD::Pg::Connection->new(dbh => $busy_dbh, pool => $pg);

    my $discarded = $pg->_discard_idle_connections;

    is $discarded, 3, 'reports how many it closed';
    is $pg->idle_count, 0, 'idle list emptied';
    is $_->disconnects, 1, 'idle connection closed' for @idle_dbh;

    # Somebody else is using this one. Closing it underneath them would be
    # worse than the outage.
    is $pg->active_count, 1, 'checked out connection still in the pool';
    is $busy_dbh->disconnects, 0, 'and still open';

    is $pg->stats->{discarded}, 3, 'counted as discarded';
};

subtest 'discarding idle connections with none idle is harmless' => sub {
    my $pg = make_pool();
    is $pg->_discard_idle_connections, 0, 'nothing to do, nothing done';
};
```

- [ ] **Step 2: Run test to verify it fails**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
prove -l -It/lib -v t/unit/pool-lifecycle.t
```
Expected: FAIL with `Can't locate object method "_discard_idle_connections"`.

- [ ] **Step 3: Write minimal implementation**

In `lib/Async/DBD/Pg.pm`, add immediately after `_discard_connection`:

```perl
# Whatever killed one connection has usually killed the rest, so finding a
# dead one is reason to drop the whole idle set rather than let each be
# rediscovered by a later caller. Connections that are checked out are left
# alone: their owners are mid-work, and each repairs itself on its next
# statement.
sub _discard_idle_connections {
    my ($self) = @_;

    my @idle = splice @{$self->{idle}};
    $self->_discard_connection($_) for @idle;

    return scalar @idle;
}
```

- [ ] **Step 4: Run test to verify it passes**

Same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/Async/DBD/Pg.pm t/unit/pool-lifecycle.t
git commit -m "Discard the idle connections an outage will also have killed

A server restart kills every pooled connection at once, so finding one
dead is reason to drop the whole idle set rather than have each of them
rediscovered by a later caller, one reconnect at a time. SQLAlchemy does
the same on a disconnect.

Connections that are checked out are left alone. Their owners are
mid-work, the pool cannot know whether they are usable, and closing one
underneath somebody would be worse than the outage."
```

---

### Task 3: Replace a dead connection and run the statement again

The substance of the feature.

**Files:**
- Modify: `lib/Async/DBD/Pg.pm` (add `_replace_dbh` after `_create_connection`)
- Modify: `lib/Async/DBD/Pg/Connection.pm` (add `_heal_if_dead`; change the two send-path failures in `_execute_async` at lines 133-135 and 155-159)
- Test: `t/pool/basic.t`

**Interfaces:**
- Consumes: `heal_dead_connections` from Task 1; `_discard_idle_connections`
  from Task 2.
- Produces:
  - `$pool->_replace_dbh($conn)` — async; builds a handle through
    `_create_connection`, closes the dead one, transplants the new one into
    `$conn`. `$conn` keeps its place in the active list.
  - `$conn->_heal_if_dead` — async; returns true if it replaced the handle,
    false if the caller should fail as normal.

- [ ] **Step 1: Write the failing test**

Add to `t/pool/basic.t`, before `done_testing`. It needs a descriptor-level
stderr capture, which this file does not yet have, so add the helper too —
`t/pool/shutdown.t` has an identical one, copy its structure rather than
importing across test files:

```perl
sub capture_stderr {
    my ($code) = @_;

    my ($fh, $path) = File::Temp::tempfile(UNLINK => 1);
    close $fh;

    open my $saved, '>&', \*STDERR or die "dup stderr: $!";
    open STDERR, '>', $path or die "redirect stderr: $!";

    my $ok = eval { $code->(); 1 };
    my $err = $@;

    open STDERR, '>&', $saved or die "restore stderr: $!";
    close $saved;

    die $err unless $ok;

    open my $read, '<', $path or die "read captured stderr: $!";
    local $/;
    my $captured = <$read>;
    close $read;

    return $captured;
}

sub kill_all_backends {
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

subtest 'a connection that died while idle is repaired, not reported' => sub {
    my @logged;
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 3,
        on_log          => sub { push @logged, $_[1] },
    );

    my $conn = $pg->connection->get;
    $conn->query('SELECT 1')->get;
    $conn->release;

    my $captured = capture_stderr(sub {
        kill_all_backends();
        Future::IO->sleep(0.2)->get;
    });

    my $again = $pg->connection->get;
    my $before = $again->dbh;

    # The caller must not see the pool's problem.
    my $result = $again->query('SELECT 42 AS answer')->get;
    is $result->first->{answer}, 42, 'statement ran despite the dead connection';

    isnt $again->dbh, $before, 'the handle was replaced';
    ok scalar(grep { /dead/i } @logged), 'the replacement was reported';

    $again->release;
};

subtest 'a statement inside a transaction is never retried' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 3,
        on_log          => sub { },
    );

    my $conn = $pg->connection->get;
    $conn->query('SELECT 1')->get;

    my $err = dies {
        $conn->transaction(async sub {
            my ($tx) = @_;
            await $tx->query('SELECT 1');

            capture_stderr(sub {
                kill_all_backends();
                Future::IO->sleep(0.2)->get;
            });

            # The transaction died with the connection. Running this on a
            # replacement would execute it outside the caller's transaction.
            await $tx->query('SELECT 2');
        })->get;
    };

    ok $err, 'the failure reaches the caller rather than being papered over';

    $conn->release;
};

subtest 'a real SQL error is not treated as a dead connection' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 2,
        on_log          => sub { },
    );

    my $conn = $pg->connection->get;
    my $before = $conn->dbh;

    my $err = dies { $conn->query('SELECT * FROM no_such_table_here')->get };

    isa_ok $err, 'Async::DBD::Pg::Error::Query';
    is $conn->dbh, $before, 'the connection was not replaced';

    $conn->release;
};

subtest 'a statement that was already sent is never retried' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 3,
        on_log          => sub { },
    );

    my $conn = $pg->connection->get;
    my $before = $conn->dbh;

    # Kill the backend while the statement is in flight. execute already
    # succeeded, so the statement reached the server and may have run.
    # Repeating it is exactly what must not happen.
    my $slow = $conn->query('SELECT pg_sleep(3)');

    my $err;
    capture_stderr(sub {
        Future::IO->sleep(0.3)->get;
        kill_all_backends();
        $err = dies { $slow->get };
    });

    ok $err, 'the failure reaches the caller';
    is $conn->dbh, $before, 'the connection was not replaced and nothing rerun';

    $conn->release;
};

subtest 'nothing is healed while the pool is shutting down' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn             => test_dsn(),
        min_connections => 0,
        max_connections => 3,
        on_log          => sub { },
    );

    my $conn = $pg->connection->get;
    $conn->query('SELECT 1')->get;

    capture_stderr(sub {
        kill_all_backends();
        Future::IO->sleep(0.2)->get;
    });

    # Shutting down means the pool will not hand out connections, so it must
    # not try to build one to repair this either.
    $pg->{_shutting_down} = 1;

    my $before = $conn->dbh;
    ok dies { $conn->query('SELECT 1')->get },
        'the error propagates rather than being healed';
    is $conn->dbh, $before, 'no replacement was built during shutdown';

    $pg->{_shutting_down} = 0;
    $conn->release;
};

subtest 'healing can be turned off' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn                   => test_dsn(),
        min_connections       => 0,
        max_connections       => 3,
        heal_dead_connections => 0,
        on_log                => sub { },
    );

    my $conn = $pg->connection->get;
    $conn->query('SELECT 1')->get;
    $conn->release;

    capture_stderr(sub {
        kill_all_backends();
        Future::IO->sleep(0.2)->get;
    });

    my $again = $pg->connection->get;
    ok dies { $again->query('SELECT 1')->get },
        'the original error propagates when healing is off';
};
```

Add to the `use` statements at the top of `t/pool/basic.t` if not already
present:

```perl
use DBI;
use File::Temp ();
use Async::DBD::Pg::Util ();
```

- [ ] **Step 2: Run test to verify it fails**

```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
PERL_FUTURE_IO_IMPL=UV TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
prove -l -It/lib -v t/pool/basic.t
```
Expected: the first subtest FAILS, the statement dying rather than running.
The other five should already pass: the transaction, already-sent, shutting
down, SQL-error and healing-off subtests all guard behaviour that must not
change, so their passing now is the point of writing them.

- [ ] **Step 3: Write minimal implementation**

In `lib/Async/DBD/Pg.pm`, add immediately after `_create_connection`:

```perl
# Give a connection a working handle in place of a dead one. The replacement
# is built by the ordinary connect path, so async connect, on_connect and
# statement_timeout all apply and there is no second copy of connect logic to
# drift. The Connection object never leaves the active list, so no pool counts
# move.
async sub _replace_dbh {
    my ($self, $conn) = @_;

    my $fresh = await $self->_create_connection;

    # Take the handle and neutralise the wrapper it arrived in: it was never
    # added to any pool list, and its destructor would otherwise release a
    # connection the pool is not tracking.
    my $dbh = delete $fresh->{dbh};
    $fresh->{released} = 1;
    $fresh->{pool}     = undef;

    $conn->_close_dbh;
    $self->{stats}{discarded}++;

    $conn->{dbh} = $dbh;

    return $conn;
}
```

In `lib/Async/DBD/Pg/Connection.pm`, add `_heal_if_dead` immediately before
`_execute_async`:

```perl
# Decide whether a statement that failed before reaching the server failed
# because the connection was already dead, and if so replace it. Returns true
# when the caller should try the statement again.
async sub _heal_if_dead {
    my ($self) = @_;

    my $pool = $self->{pool} or return 0;

    return 0 unless $pool->{heal_dead_connections};
    return 0 if $pool->{_shutting_down};

    # The transaction died with the connection. Running the statement on a
    # replacement would execute it outside the transaction the caller asked
    # for, which is worse than the failure.
    return 0 if $self->{in_transaction};

    # A live connection means the statement failed on its own merits, not
    # because the connection was gone. ping is a round trip, but this path
    # has already failed, and it is the same check the pool makes on release.
    my $dbh = $self->{dbh};
    return 0 if $dbh && $dbh->ping;

    $pool->_log(warn => 'replacing a pooled connection that was already dead');

    await $pool->_replace_dbh($self);

    # Whatever killed this one has usually killed the rest.
    $pool->_discard_idle_connections;

    return 1;
}
```

Then change `_execute_async` so the two send-path failures can heal. Give it a
fourth parameter recording whether this is already the retry, and replace the
`prepare` failure block at lines 133-135 with:

```perl
    my $sth = eval { $dbh->prepare($sql, { pg_async => PG_ASYNC }) };
    if ($@ || !$sth) {
        my $err = $@ || $dbh->errstr;

        if (!$healed && await $self->_heal_if_dead) {
            return await $self->_execute_async($sql, $bind, 1);
        }

        $self->_throw_query_error($err, $sql);
    }
```

and the `execute` failure block at lines 155-159 with:

```perl
    if ($@ || !defined $rv) {
        my $err = $@ || $sth->errstr || $dbh->errstr;
        $statement->release;

        if (!$healed && await $self->_heal_if_dead) {
            return await $self->_execute_async($sql, $bind, 1);
        }

        $self->_throw_query_error($err, $sql);
    }
```

changing the signature line to:

```perl
async sub _execute_async {
    my ($self, $sql, $bind, $healed) = @_;
```

Leave the `pg_result` failure at lines 164-168 exactly as it is. By that point
`execute` has succeeded, the statement has been dispatched, and it may have
run.

- [ ] **Step 4: Run test to verify it passes**

Same command as Step 2. Expected: PASS, all four subtests.

Then the whole suite under both implementations, with stderr checked properly:
```bash
source ~/perl5/perlbrew/etc/bashrc && perlbrew use perl-5.42.2@default && \
for impl in UV IOAsync; do
  PERL_FUTURE_IO_IMPL=$impl TEST_PG_DSN="postgresql://postgres:test@localhost:5433/test" \
    prove -r -l -It/lib t/ 2>/tmp/err-$impl.txt | tail -2
  echo "stderr bytes: $(wc -c < /tmp/err-$impl.txt)"
done
```
Expected: PASS for both, and zero stderr bytes for both.

- [ ] **Step 5: Commit**

```bash
git add lib/Async/DBD/Pg.pm lib/Async/DBD/Pg/Connection.pm t/pool/basic.t
git commit -m "Replace a dead pooled connection and run the statement again

A connection that died while idle was handed to the next caller, who
discovered it when their first statement failed. The caller had done
nothing wrong, so the pool now repairs itself instead of reporting a
fault of its own making.

The retry is narrow by construction. With pg_async it is execute that
dispatches a statement, so a failure at prepare or execute means nothing
reached the server and running it again is safe. Anything after that
point may already have run and is never retried. A statement inside a
transaction is never retried either: the transaction died with the
connection, and running it on a replacement would execute it outside the
transaction the caller asked for.

A live connection means the statement failed on its own merits, so a
syntax error is reported as one rather than being mistaken for an
outage.

The replacement handle is built by the ordinary connect path, so there
is no second copy of connect logic, and the Connection never leaves the
active list, so no pool counts move."
```

---

### Task 4: Record the outcome in the gaps document

**Files:**
- Modify: `docs/gaps.md` (item 16)

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Update item 16**

Change the heading `### 16. No connection validation on checkout` to
`### 16. No connection validation on checkout — FIXED, DIFFERENTLY`, and
append after its existing body:

```markdown
Fixed, but not as written. The item asks for validation on checkout, which was
considered and rejected: validation is racy by construction, since a connection
that passes a check can die before the caller's first statement, and it costs a
round trip on the pool's hottest path — the round trip item 14 removed from the
far colder `DESTROY`.

Nor is it what comparable pools do. Neither node-postgres nor asyncpg validates
on acquire. SQLAlchemy offers `pool_pre_ping` and leaves it off by default.
HikariCP does validate, but it is a synchronous pool where a blocking probe
costs nothing extra.

Instead the failure is made recoverable at the point of use. A statement that
fails at `prepare` or `execute` provably never reached the server, so if the
connection is also dead the pool replaces its handle and runs the statement
again; the caller never sees it. Anything after `execute` succeeds is never
retried, and neither is anything inside a transaction, where running the
statement on a replacement would execute it outside the caller's transaction.

Finding one dead connection also discards the idle ones, since whatever killed
it has usually killed them too. That part is taken from SQLAlchemy, which
invalidates its whole idle set on a disconnect; without it each later caller
rediscovers the same outage one reconnect at a time.

Controlled by `heal_dead_connections`, on by default. See
`docs/superpowers/specs/2026-08-01-heal-dead-connections-design.md`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/gaps.md
git commit -m "Record how item 16 was resolved

Note that the item's own framing was rejected. It asks for validation on
checkout; recovering at the point of use closes the race a check cannot,
and costs nothing when nothing is wrong."
```

---

## Follow-up, not part of this plan

`_heal_if_dead` calls `ping`, which is a blocking round trip, on a path that
has already failed. That is acceptable and deliberate, but it is the last
blocking call left on a query path in this distribution and worth its own gaps
entry if anyone wants to remove it. Doing so would mean detecting deadness
without a round trip, most plausibly by checking whether the socket has reached
end of file.

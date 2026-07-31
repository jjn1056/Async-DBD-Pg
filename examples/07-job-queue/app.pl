#!/usr/bin/env perl
use strict;
use warnings;

use Future::AsyncAwait;
use Future::IO;
use Future::Selector;
use JSON::PP;

use Async::DBD::Pg;

BEGIN { Future::IO->load_best_impl; }

# A job queue is several things happening at once: work arriving, workers
# taking it, and notifications waking those workers up. Each is written as its
# own async sub, and they are composed into one tree with Future::Selector
# rather than being interleaved by hand.

my $dsn = $ENV{DATABASE_URL} // 'postgresql://postgres:test@localhost:5432/test';

my $pg = Async::DBD::Pg->new(
    dsn             => $dsn,
    min_connections => 2,
    max_connections => 6,
);

my $json = JSON::PP->new->utf8;

use constant {
    WORKERS    => 3,
    TOTAL_JOBS => 8,
};

# ---------------------------------------------------------------- schema

async sub setup_schema {
    my $conn = await $pg->connection;

    await $conn->query('SET client_min_messages TO warning');
    await $conn->query('DROP TABLE IF EXISTS jobs');
    await $conn->query(q{
        CREATE TABLE jobs (
            id           SERIAL PRIMARY KEY,
            type         TEXT NOT NULL,
            payload      JSONB NOT NULL,
            status       TEXT NOT NULL DEFAULT 'pending',
            created_at   TIMESTAMPTZ DEFAULT NOW(),
            completed_at TIMESTAMPTZ,
            result       JSONB
        )
    });
    await $conn->query('CREATE INDEX jobs_status_idx ON jobs(status)');

    $conn->release;
    print "Schema created.\n\n";
}

# ------------------------------------------------------- waking up workers

# Workers should sleep until there is something to do rather than poll the
# table. Each parks on a future; the LISTEN callback completes them all.
my @sleeping;

sub wake_workers {
    my @waking = @sleeping;
    @sleeping = ();
    $_->done for grep { !$_->is_ready } @waking;
}

sub sleep_until_woken {
    my $woken = Future->new;
    push @sleeping, $woken;

    # Time out as well, so a notification arriving between checking the table
    # and parking here cannot leave a worker asleep with work waiting.
    return Future->wait_any($woken, Future::IO->sleep(0.25));
}

# --------------------------------------------------------------- producing

async sub produce_jobs {
    my @jobs = (
        [ email  => { to => 'alice@example.com'   } ],
        [ report => { name => 'Monthly Sales'     } ],
        [ email  => { to => 'bob@example.com'     } ],
        [ report => { name => 'User Activity'     } ],
        [ email  => { to => 'charlie@example.com' } ],
        [ broken => { }                            ],
        [ email  => { to => 'dana@example.com'    } ],
        [ report => { name => 'Retention'         } ],
    );

    for my $job (@jobs) {
        my ($type, $payload) = @$job;

        my $conn = await $pg->connection;
        my $row = await $conn->query(
            'INSERT INTO jobs (type, payload) VALUES ($1, $2::jsonb) RETURNING id',
            $type, $json->encode($payload),
        );
        $conn->release;

        my $id = $row->first->{id};
        print "  queued job #$id ($type)\n";

        await $pg->notify(new_job => $id);
        await Future::IO->sleep(0.05);
    }

    return scalar @jobs;
}

# --------------------------------------------------------------- consuming

# Claiming happens in a transaction with SKIP LOCKED, so several workers can
# take from the same table without ever claiming the same row.
async sub claim_job {
    my ($conn) = @_;

    my $job;

    await $conn->transaction(async sub {
        my ($tx) = @_;

        my $result = await $tx->query(q{
            SELECT id, type, payload
              FROM jobs
             WHERE status = 'pending'
             ORDER BY created_at
             LIMIT 1
            FOR UPDATE SKIP LOCKED
        });

        return unless $result->count;
        $job = $result->first;

        await $tx->query(
            q{UPDATE jobs SET status = 'running' WHERE id = $1}, $job->{id},
        );
    });

    return $job;
}

sub do_the_work {
    my ($job) = @_;

    my $payload = ref $job->{payload} ? $job->{payload} : $json->decode($job->{payload});

    return { sent      => 1, to   => $payload->{to}   } if $job->{type} eq 'email';
    return { generated => 1, name => $payload->{name} } if $job->{type} eq 'report';

    die "unknown job type '$job->{type}'\n";
}

my $completed = 0;
my $finished  = Future->new;

async sub run_worker {
    my ($name) = @_;

    my $conn = await $pg->connection;

    until ($finished->is_ready) {
        my $job = await claim_job($conn);

        if (!$job) {
            await sleep_until_woken();
            next;
        }

        my ($status, $result) = eval { ('completed', do_the_work($job)) };
        ($status, $result) = ('failed', { error => "$@" }) if $@;

        await $conn->query(
            q{UPDATE jobs SET status = $1, completed_at = NOW(), result = $2::jsonb
               WHERE id = $3},
            $status, $json->encode($result), $job->{id},
        );

        printf "  %s %s job #%d (%s)\n",
            $name, ($status eq 'completed' ? 'finished' : 'FAILED'),
            $job->{id}, $job->{type};

        $finished->done if ++$completed >= TOTAL_JOBS && !$finished->is_ready;
    }

    $conn->release;
    return $name;
}

# -------------------------------------------------------------------- main

# One failing branch must not take the whole tree down with it. Conduit wraps
# each client connection it accepts the same way.
sub supervised {
    my ($name, $f) = @_;

    return $f->else(sub {
        my ($err) = @_;
        chomp $err;
        warn "  !! $name failed: $err\n";
        return Future->done;
    });
}

(async sub {
    await setup_schema();

    await $pg->listen(new_job => sub { wake_workers() });

    my $selector = Future::Selector->new;

    $selector->add(data => 'producer', f => supervised(producer => produce_jobs()));

    for my $n (1 .. WORKERS) {
        my $name = "worker $n";
        $selector->add(data => $name, f => supervised($name, run_worker($name)));
    }

    print "=== running ", WORKERS, " workers ===\n\n";

    # Run the tree until every job has been dealt with. Workers see $finished
    # become ready and fall out of their loops on their own.
    await $selector->run_until_ready($finished);

    wake_workers();    # let anyone still parked notice and exit

    print "\n=== results ===\n\n";

    my $conn = await $pg->connection;
    my $rows = await $conn->query(
        'SELECT id, type, status FROM jobs ORDER BY id'
    );

    printf "  #%-3d %-8s %s\n", $_->{id}, $_->{type}, $_->{status}
        for @{ $rows->rows };

    await $conn->query('DROP TABLE jobs');
    $conn->release;

    await $pg->shutdown;
})->()->get;

print "\nDone.\n";

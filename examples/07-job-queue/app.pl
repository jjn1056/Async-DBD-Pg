#!/usr/bin/env perl
use strict;
use warnings;

use Future::AsyncAwait;
use Future::IO;
use JSON::PP;

use Async::DBD::Pg;

BEGIN { Future::IO->load_best_impl; }

my $dsn = $ENV{DATABASE_URL} // 'postgresql://postgres:test@localhost:5432/test';

my $pg = Async::DBD::Pg->new(
    dsn             => $dsn,
    min_connections => 2,
    max_connections => 5,
);

my $json = JSON::PP->new->utf8;

sub setup_schema {
    my $conn = $pg->connection->get;
    $conn->query("SET client_min_messages TO warning")->get;
    $conn->query('DROP TABLE IF EXISTS jobs')->get;
    $conn->query(q{
        CREATE TABLE jobs (
            id SERIAL PRIMARY KEY,
            type TEXT NOT NULL,
            payload JSONB NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            created_at TIMESTAMPTZ DEFAULT NOW(),
            started_at TIMESTAMPTZ,
            completed_at TIMESTAMPTZ,
            result JSONB
        )
    })->get;
    $conn->query('CREATE INDEX jobs_status_idx ON jobs(status)')->get;
    $conn->release;
    print "Schema created.\n\n";
}

async sub enqueue_job {
    my ($type, $payload) = @_;

    my $conn = await $pg->connection;
    my $payload_json = $json->encode($payload);

    my $result = await $conn->query(
        'INSERT INTO jobs (type, payload) VALUES ($1, $2::jsonb) RETURNING id',
        $type, $payload_json,
    );
    my $job_id = $result->first->{id};
    $conn->release;

    await $pg->notify('new_job', "$job_id");

    return $job_id;
}

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
            q{UPDATE jobs SET status = 'running', started_at = NOW() WHERE id = $1},
            $job->{id},
        );
    });

    return $job;
}

async sub complete_job {
    my ($conn, $job_id, $result) = @_;

    await $conn->query(
        q{UPDATE jobs SET status = 'completed', completed_at = NOW(), result = $1::jsonb WHERE id = $2},
        $json->encode($result), $job_id,
    );
}

async sub fail_job {
    my ($conn, $job_id, $error) = @_;

    await $conn->query(
        q{UPDATE jobs SET status = 'failed', completed_at = NOW(), result = $1::jsonb WHERE id = $2},
        $json->encode({ error => $error }), $job_id,
    );
}

sub process_job {
    my ($job) = @_;

    my $payload = ref($job->{payload}) ? $job->{payload} : $json->decode($job->{payload});

    if ($job->{type} eq 'email') {
        print "    Sending email to: $payload->{to}\n";
        return { sent => 1, to => $payload->{to} };
    }
    if ($job->{type} eq 'report') {
        print "    Generating report: $payload->{name}\n";
        return { generated => 1, name => $payload->{name} };
    }

    die "Unknown job type: $job->{type}";
}

eval {
    setup_schema();

    print "=== Waiting for job notifications ===\n\n";
    my @notifications;
    $pg->listen('new_job', sub {
        my ($channel, $payload, $pid) = @_;
        push @notifications, $payload;
        print "  Notification on $channel for job #$payload (PID $pid)\n";
    })->get;

    print "=== Enqueueing Jobs ===\n\n";
    for my $job (
        [ email  => { to => 'alice@example.com',   subject => 'Hello' } ],
        [ email  => { to => 'bob@example.com',     subject => 'Hi' } ],
        [ report => { name => 'Monthly Sales' } ],
        [ email  => { to => 'charlie@example.com', subject => 'Hey' } ],
        [ report => { name => 'User Activity' } ],
    ) {
        my $id = enqueue_job($job->[0], $job->[1])->get;
        print "  Enqueued job #$id: $job->[0]\n";
    }

    my $deadline = time + 2;
    while (@notifications < 5 && time < $deadline) {
        Future::IO->sleep(0.05)->get;
    }

    print "\nReceived ", scalar(@notifications), " job notifications.\n";

    print "\n=== Processing Jobs ===\n\n";

    my $conn = $pg->connection->get;
    my $processed = 0;

    while (my $job = claim_job($conn)->get) {
        print "  Worker claimed job #$job->{id} ($job->{type})\n";

        eval {
            my $result = process_job($job);
            complete_job($conn, $job->{id}, $result)->get;
            print "    Completed!\n";
            $processed++;
            1;
        } or do {
            my $err = $@ || 'Unknown error';
            fail_job($conn, $job->{id}, "$err")->get;
            print "    Failed: $err\n";
        };
    }

    print "\nProcessed $processed jobs.\n";
    print "\n=== Final Job Status ===\n\n";

    my $result = $conn->query(q{
        SELECT id, type, status, result
        FROM jobs
        ORDER BY id
    })->get;

    for my $row (@{$result->rows}) {
        print "  Job #$row->{id}: $row->{type} - $row->{status}\n";
    }

    $conn->query('DROP TABLE jobs')->get;
    $conn->release;

    $pg->unlisten_all->get;
    $pg->pubsub->disconnect->get;

    print "\n=== Pattern Summary ===\n\n";
    print "This pattern provides:\n";
    print "  - Persistent jobs (survive restarts)\n";
    print "  - Atomic claiming (no double-processing)\n";
    print "  - Instant notifications (pub/sub)\n";
    print "  - Status tracking\n";
    print "  - Error handling\n";
};
if (my $e = $@) {
    die "Error: $e\n";
}

print "\nDone!\n";

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
my %current_metrics;
my $update_count = 0;

sub setup_schema {
    my $conn = $pg->connection->get;
    $conn->query("SET client_min_messages TO warning")->get;
    $conn->query('DROP TABLE IF EXISTS metrics')->get;
    $conn->query(q{
        CREATE TABLE metrics (
            id SERIAL PRIMARY KEY,
            name TEXT NOT NULL,
            value NUMERIC NOT NULL,
            recorded_at TIMESTAMPTZ DEFAULT NOW()
        )
    })->get;
    $conn->release;
}

async sub record_metric {
    my ($name, $value) = @_;

    my $conn = await $pg->connection;

    await $conn->query(
        'INSERT INTO metrics (name, value) VALUES ($1, $2)',
        $name, $value,
    );

    $conn->release;

    await $pg->notify('metrics', $json->encode({ name => $name, value => $value }));
}

sub display_dashboard {
    print "\n", "=" x 50, "\n";
    print "        LIVE DASHBOARD (update #$update_count)\n";
    print "=" x 50, "\n\n";

    if (%current_metrics) {
        for my $name (sort keys %current_metrics) {
            my $value = $current_metrics{$name};
            my $bar = "#" x int($value / 5);
            printf "  %-15s %6.1f  %s\n", $name, $value, $bar;
        }
    }
    else {
        print "  Waiting for metrics...\n";
    }

    print "\n", "-" x 50, "\n";
}

eval {
    setup_schema();

    print "Starting Live Dashboard Demo\n";
    print "(Simulating 10 metric updates)\n\n";

    $pg->listen('metrics', sub {
        my ($channel, $payload) = @_;
        my $data = $json->decode($payload);
        $current_metrics{$data->{name}} = $data->{value};
        $update_count++;
        display_dashboard();
    })->get;

    print "Dashboard subscribed to 'metrics' channel.\n";
    display_dashboard();

    my @metric_names = qw(cpu_usage memory_pct requests_sec latency_ms disk_io);

    for my $i (1 .. 10) {
        my $name = $metric_names[int(rand(@metric_names))];
        my $value = 20 + rand(80);

        record_metric($name, $value)->get;
        Future::IO->sleep(0.25)->get;
    }

    print "\n=== Final Metrics Summary ===\n\n";

    my $conn = $pg->connection->get;
    my $result = $conn->query(q{
        SELECT name, COUNT(*) AS updates, ROUND(AVG(value)::numeric, 1) AS avg_value
        FROM metrics
        GROUP BY name
        ORDER BY name
    })->get;

    printf "  %-15s %8s %10s\n", "Metric", "Updates", "Avg Value";
    printf "  %-15s %8s %10s\n", "-" x 15, "-" x 8, "-" x 10;
    for my $row (@{$result->rows}) {
        printf "  %-15s %8d %10.1f\n", $row->{name}, $row->{updates}, $row->{avg_value};
    }

    $conn->query('DROP TABLE metrics')->get;
    $conn->release;

    $pg->unlisten_all->get;
    $pg->pubsub->disconnect->get;

    print "\n=== How It Works ===\n\n";
    print "1. Producer inserts metric data and sends NOTIFY\n";
    print "2. Dashboard receives notification instantly\n";
    print "3. Dashboard updates display in real time\n";
};
if (my $e = $@) {
    die "Error: $e\n";
}

print "\nDone!\n";

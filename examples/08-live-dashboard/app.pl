#!/usr/bin/env perl
use strict;
use warnings;

use Future::AsyncAwait;
use Future::IO;
use Future::Selector;
use JSON::PP;

use Async::DBD::Pg;

BEGIN { Future::IO->load_best_impl; }

# A dashboard is several independent things running at the same time: each
# metric reports on its own schedule, the display redraws on its own, and
# notifications arrive whenever they arrive. Written as one loop these have to
# take turns. Written as separate async subs composed with Future::Selector,
# each simply runs at its own pace.

my $dsn = $ENV{DATABASE_URL} // 'postgresql://postgres:test@localhost:5432/test';

my $queries = 0;    # statement count, kept by the on_query hook below

my $pg = Async::DBD::Pg->new(
    dsn             => $dsn,
    min_connections => 2,
    max_connections => 8,
    on_query        => sub { $queries++ },
);

my $json = JSON::PP->new->utf8;

my %current;         # latest value per metric, kept by the LISTEN callback
my $updates = 0;

use constant RUN_FOR => 4;    # seconds

# ----------------------------------------------------------------- schema

async sub setup_schema {
    await $pg->with_connection(async sub {
        my ($conn) = @_;

        await $conn->query('SET client_min_messages TO warning');
        await $conn->query('DROP TABLE IF EXISTS metrics');
        await $conn->query(q{
            CREATE TABLE metrics (
                id          SERIAL PRIMARY KEY,
                name        TEXT NOT NULL,
                value       NUMERIC NOT NULL,
                recorded_at TIMESTAMPTZ DEFAULT NOW()
            )
        });
    });
}

# --------------------------------------------------------------- producing

async sub record_metric {
    my ($name, $value) = @_;

    await $pg->query(
        'INSERT INTO metrics (name, value) VALUES ($1, $2)', $name, $value,
    );

    await $pg->notify(metrics => $json->encode({ name => $name, value => $value }));
}

# Each metric is its own branch of the tree, reporting at its own interval.
async sub report_metric {
    my ($name, $interval, $until) = @_;

    my $sent = 0;

    until ($until->is_ready) {
        await record_metric($name, 20 + rand 80);
        $sent++;
        await Future->wait_any($until->without_cancel, Future::IO->sleep($interval));
    }

    return "$name sent $sent";
}

# ----------------------------------------------------------------- display

sub draw {
    printf "\n== dashboard (%d updates) %s\n", $updates, '=' x 28;
    printf "   queries run: %d\n", $queries;

    if (!%current) {
        print "   waiting for metrics...\n";
        return;
    }

    for my $name (sort keys %current) {
        my $value = $current{$name};
        printf "   %-14s %6.1f  %s\n", $name, $value, '#' x int($value / 5);
    }
}

# The display is its own branch too, redrawing on a steady beat rather than
# once per notification, so a burst of updates cannot cause a burst of redraws.
async sub run_display {
    my ($until) = @_;

    until ($until->is_ready) {
        draw();
        await Future->wait_any($until->without_cancel, Future::IO->sleep(0.8));
    }

    return 'display';
}

# -------------------------------------------------------------------- main

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

    await $pg->listen(metrics => sub {
        my ($channel, $payload) = @_;
        my $data = $json->decode($payload);
        $current{ $data->{name} } = $data->{value};
        $updates++;
    });

    # Everything below runs until this future is ready.
    my $until = Future::IO->sleep(RUN_FOR);

    my $selector = Future::Selector->new;

    $selector->add(data => 'display', f => supervised(display => run_display($until)));

    my %metrics = (
        cpu_usage    => 0.30,
        memory_pct   => 0.55,
        requests_sec => 0.20,
        latency_ms   => 0.75,
    );

    for my $name (sort keys %metrics) {
        $selector->add(
            data => $name,
            f    => supervised($name, report_metric($name, $metrics{$name}, $until)),
        );
    }

    print "Reporting ", scalar(keys %metrics), " metrics for ", RUN_FOR, "s\n";

    await $selector->run_until_ready($until);

    draw();

    print "\n== summary ", '=' x 38, "\n\n";

    my $rows = await $pg->query(q{
        SELECT name, COUNT(*) AS updates, ROUND(AVG(value)::numeric, 1) AS avg_value
          FROM metrics
         GROUP BY name
         ORDER BY name
    });

    printf "   %-14s %8s %10s\n", 'metric', 'updates', 'average';
    printf "   %-14s %8d %10.1f\n", $_->{name}, $_->{updates}, $_->{avg_value}
        for @{ $rows->rows };

    await $pg->query('DROP TABLE metrics');

    await $pg->shutdown;
})->()->get;

print "\nDone.\n";

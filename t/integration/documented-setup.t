use strict;
use warnings;
use Test2::V0;
use Future;
use Future::AsyncAwait;

use lib 't/lib';
use Test::Async::DBD::Pg qw(skip_without_postgres test_dsn);

my $dsn = skip_without_postgres();

use Future::IO;
BEGIN { Future::IO->load_best_impl; }

use Async::DBD::Pg;

# docs.t checks that a SYNOPSIS parses. Parsing is not the property that
# matters here: the setup this distribution documents either produces real
# concurrency or it does not, and the difference is invisible to a parser.
# Future::IO's default implementation drives one filehandle at a time and
# puts handles into blocking mode, so a pool built without loading a real
# implementation runs serially while looking perfectly correct.

subtest 'the documented setup actually overlaps queries' => sub {
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 4, max_connections => 4);

    my $started = time;
    Future->wait_all(map { $pg->query_value('SELECT pg_sleep(1)') } 1 .. 4)->get;
    my $elapsed = time - $started;

    # Four one-second queries on four connections. Concurrent is ~1s;
    # serialized is ~4s. The threshold is deliberately loose -- this is
    # distinguishing 1 from 4, not benchmarking.
    ok $elapsed < 3,
        "four 1s queries on four connections took ${elapsed}s, so they overlapped";

    $pg->shutdown(timeout => 10)->get;
};

subtest 'every module SYNOPSIS names the setup it needs' => sub {
    my @modules = glob 'lib/Async/DBD/Pg.pm lib/Async/DBD/Pg/*.pm';

    for my $file (@modules) {
        open my $fh, '<', $file or die "cannot read $file: $!";
        my (@block, $in);
        while (my $line = <$fh>) {
            if ($line =~ /^=head1 SYNOPSIS/)     { $in = 1; next }
            if ($in && $line =~ /^=(head1|cut)/) { last }
            push @block, $line if $in;
        }
        close $fh;
        my $synopsis = join '', @block;

        next unless $synopsis =~ /\bawait\b/;

        # Either it shows the setup, or it says where the setup lives. A
        # synopsis that awaits and mentions neither is one a reader can copy
        # into a program that silently never runs concurrently.
        if ($file eq 'lib/Async/DBD/Pg.pm') {
            # The canonical example must carry the setup as code, not as a
            # mention of it. A commented-out BEGIN with the word still
            # present nearby would otherwise satisfy a substring match.
            my $live = join "\n",
                grep { !/^\s*#/ } split /\n/, $synopsis;
            like $live, qr/BEGIN\s*\{\s*Future::IO->load_best_impl/,
                "$file SYNOPSIS loads an implementation in live code";
        }
        else {
            like $synopsis, qr/load_best_impl|Async::DBD::Pg\/SYNOPSIS|SEE ALSO/,
                "$file SYNOPSIS points at the async setup";
        }
    }
};

subtest 'a connection checked out by hand is lost if it is not released' => sub {
    # The behaviour the documentation has to warn about, pinned so the
    # warning cannot quietly stop being true. DESTROY does release, but the
    # enclosing async sub's frame holds the reference, so it never runs.
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 0, max_connections => 2);

    (async sub {
        my $conn = await $pg->connection;
        await $conn->query_value('SELECT 1');
    })->()->get;

    is $pg->active_count, 1,
        'still checked out after the sub that took it has ended';
    is $pg->idle_count, 0, 'and the pool does not have it back';

    # with_connection returns it even when the body dies.
    my $err = dies {
        $pg->with_connection(async sub {
            my ($conn) = @_;
            await $conn->query('SELECT * FROM no_such_table_at_all');
        })->get
    };
    ok $err, 'the failure still reaches the caller';
    is $pg->idle_count, 1, 'and with_connection gave the connection back anyway';

    $pg->shutdown(timeout => 10)->get;
};

subtest 'the README synopsis runs against a real database' => sub {
    # docs.t proves the examples parse and name real methods. It cannot
    # prove they work, which is the class of bug that put a serialized
    # example in front of every new reader for months.
    # The guard DROP below always finds nothing to drop -- the last statement
    # in this subtest is an unconditional DROP TABLE, so the table never
    # survives between runs -- and the resulting NOTICE would otherwise reach
    # this suite's default on_log, which warns to stderr. Captured and
    # asserted rather than silently discarded, so a log line this subtest
    # does not expect still fails it instead of vanishing.
    my @logs;
    my $pg = Async::DBD::Pg->new(
        dsn => test_dsn(), min_connections => 2, max_connections => 10,
        on_log => sub { push @logs, "$_[0]: $_[1]" },
    );

    (async sub {
        await $pg->query('DROP TABLE IF EXISTS readme_users');
        await $pg->query('CREATE TABLE readme_users (id int, name text, active bool)');
        await $pg->query("INSERT INTO readme_users VALUES (1, 'Ada', true)");

        my $user  = await $pg->query_row('SELECT * FROM readme_users WHERE id = $1', 1);
        my $total = await $pg->query_value('SELECT count(*) FROM readme_users');
        my ($id, $name) = await $pg->query_list('SELECT id, name FROM readme_users LIMIT 1');

        is $user->{name}, 'Ada',  'query_row returns the row';
        is $total, 1,             'query_value returns the count';
        is [$id, $name], [1, 'Ada'], 'query_list returns the row as a list';

        my $rs = await $pg->query('SELECT id, name FROM readme_users WHERE active');
        is scalar(@{ $rs->rows }), 1, 'the result iterates';

        await $pg->query('DROP TABLE readme_users');
    })->()->get;

    is [ grep { !/does not exist, skipping/ } @logs ], [],
        'no unexpected log output';

    $pg->shutdown(timeout => 10)->get;
};

done_testing;

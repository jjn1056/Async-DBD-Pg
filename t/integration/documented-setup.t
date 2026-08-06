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
        like $synopsis, qr/load_best_impl|Async::DBD::Pg\/SYNOPSIS|SEE ALSO/,
            "$file SYNOPSIS points at the async setup";
    }
};

done_testing;

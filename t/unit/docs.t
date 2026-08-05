use strict;
use warnings;
use Test2::V0;

# Documentation this library ships is the only description of it that exists:
# it appears in no model's training data, so code written against it -- by a
# person or by a generator -- comes from these files. A method named here that
# does not exist produces code that cannot run, and nothing else would catch
# it, because prose is not compiled.
#
# So both the POD examples and the machine reference are checked against the
# real API rather than trusted.

use Async::DBD::Pg;
use Async::DBD::Pg::Collection;
use Async::DBD::Pg::Column;
use Async::DBD::Pg::Connection;
use Async::DBD::Pg::Cursor;
use Async::DBD::Pg::PubSub;
use Async::DBD::Pg::Results;

# The variable names the documentation uses, and what they hold. A method
# called on one of these in an example has to exist on that class.
my %CLASS_OF = (
    pg         => 'Async::DBD::Pg',
    pool       => 'Async::DBD::Pg',
    conn       => 'Async::DBD::Pg::Connection',
    c          => 'Async::DBD::Pg::Connection',
    result     => 'Async::DBD::Pg::Results',
    r          => 'Async::DBD::Pg::Results',
    results    => 'Async::DBD::Pg::Results',
    view       => 'Async::DBD::Pg::Results',
    v          => 'Async::DBD::Pg::Results',
    cursor     => 'Async::DBD::Pg::Cursor',
    cur        => 'Async::DBD::Pg::Cursor',
    collection => 'Async::DBD::Pg::Collection',
    column     => 'Async::DBD::Pg::Column',
    col        => 'Async::DBD::Pg::Column',
    ps         => 'Async::DBD::Pg::PubSub',
    pubsub     => 'Async::DBD::Pg::PubSub',
);

# Methods a documented object might be shown calling that belong to something
# else entirely, so an example is not marked broken for using them.
my %NOT_OURS = map { $_ => 1 } qw(
    get_all get new decode encode
);

sub verbatim_blocks {
    my ($file) = @_;

    open my $fh, '<', $file or die "cannot read $file: $!";
    my @blocks;
    my $in_pod = 0;

    while (my $line = <$fh>) {
        $in_pod = 1 if $line =~ /^=\w/;
        $in_pod = 0 if $line =~ /^=cut/;
        next unless $in_pod;

        push @blocks, $line if $line =~ /^\s+\S/;
    }
    close $fh;

    return \@blocks;
}

# $var->method, restricted to the variables the map above knows about.
sub calls_in {
    my ($lines) = @_;

    my @calls;
    for my $line (@$lines) {
        while ($line =~ /\$(\w+)\s*->\s*([a-z_][a-z_0-9]*)\s*(?:\(|;|$|\s)/g) {
            my ($var, $method) = ($1, $2);
            next unless $CLASS_OF{$var};
            next if $NOT_OURS{$method};
            push @calls, [$var, $method];
        }
    }

    return \@calls;
}

my @MODULES = qw(
    lib/Async/DBD/Pg.pm
    lib/Async/DBD/Pg/Collection.pm
    lib/Async/DBD/Pg/Column.pm
    lib/Async/DBD/Pg/Connection.pm
    lib/Async/DBD/Pg/Cursor.pm
    lib/Async/DBD/Pg/PubSub.pm
    lib/Async/DBD/Pg/Results.pm
);

subtest 'every method shown in a POD example exists' => sub {
    my $checked = 0;

    for my $file (@MODULES) {
        my $calls = calls_in(verbatim_blocks($file));

        for my $call (@$calls) {
            my ($var, $method) = @$call;
            my $class = $CLASS_OF{$var};

            ok $class->can($method),
                "$file: $class->$method (shown as \$$var->$method)";
            $checked++;
        }
    }

    # A pattern that silently matches nothing would make every assertion
    # above vacuous, so the count is asserted rather than assumed.
    ok $checked > 40, "checked a real number of documented calls ($checked)";
};

subtest 'the machine reference lists only methods that exist' => sub {
    ok -f 'llms.txt', 'llms.txt is present in the distribution root';

    open my $fh, '<', 'llms.txt' or die "cannot read llms.txt: $!";
    my @lines = <$fh>;
    close $fh;

    my $calls = calls_in(\@lines);
    ok scalar @$calls > 40, 'it describes a real amount of the API';

    for my $call (@$calls) {
        my ($var, $method) = @$call;
        my $class = $CLASS_OF{$var};

        ok $class->can($method), "llms.txt: $class->$method";
    }
};

subtest 'the machine reference stays short enough to read in one pass' => sub {
    open my $fh, '<', 'llms.txt' or die "cannot read llms.txt: $!";
    my $text = do { local $/; <$fh> };
    close $fh;

    # Its whole purpose is being read entire, by a person skimming or by an
    # agent with a context budget. Roughly four characters to a token.
    my $tokens = length($text) / 4;

    ok $tokens < 2000, sprintf('roughly %d tokens, under the 2000 budget', $tokens);
    like $text, qr/^# Async::DBD::Pg/, 'names what it describes on the first line';
};

subtest 'the public API is covered by the machine reference' => sub {
    open my $fh, '<', 'llms.txt' or die "cannot read llms.txt: $!";
    my $text = do { local $/; <$fh> };
    close $fh;

    # Anything added to Results without being written down here is invisible
    # to everyone reading the reference, which is the drift this catches.
    my @results_api = qw(
        rows arrays columns types count rows_affected is_empty elapsed
        first single first_value single_value row_array next reset all get_column
        preview as multi expand by groups
    );

    my @missing = grep { $text !~ /\b\Q$_\E\b/ } @results_api;
    is \@missing, [], 'every Results method appears in llms.txt';

    my @pool_api = qw(
        query query_row query_value connection with_connection transaction
        shutdown on_query stats
    );

    my @missing_pool = grep { $text !~ /\b\Q$_\E\b/ } @pool_api;
    is \@missing_pool, [], 'and every pool entry point';
};

done_testing;

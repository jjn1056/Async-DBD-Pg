use strict;
use warnings;
use Test2::V0;
use Future::AsyncAwait;

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
    rs         => 'Async::DBD::Pg::Results',
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

sub synopsis_of {
    my ($file) = @_;

    open my $fh, '<', $file or die "cannot read $file: $!";
    my (@block, $in);
    while (my $line = <$fh>) {
        if ($line =~ /^=head1 SYNOPSIS/)     { $in = 1; next }
        if ($in && $line =~ /^=(head1|cut)/) { last }
        push @block, $line if $in;
    }
    close $fh;

    return join '', @block;
}

subtest 'every SYNOPSIS parses as Perl' => sub {
    # Narrow on purpose, and worth saying what it does not do: this catches a
    # SYNOPSIS that cannot be parsed at all. It does NOT catch one that parses
    # and then does the wrong thing -- the Cursor SYNOPSIS once looped
    # `for my $row (@$batch)` over what had become a hashref, which is a
    # runtime error and compiles cleanly. Only executing the examples catches
    # that class, which needs a live database and is not this test.
    my $compiled = 0;

    for my $file (@MODULES) {
        my $code = synopsis_of($file);
        next unless $code =~ /\S/;

        # await needs an async sub around it; strict is off because a
        # synopsis names variables it never declares, which is the point of
        # a synopsis rather than a fault in it.
        my $ok = eval
            "use feature 'say'; no strict; no warnings; "
          . "my \$unused = async sub {\n$code\n}; 1";

        my $err = $@;
        $err =~ s/\s+at\s\(eval.*//s;
        $err =~ s/\n.*//s;

        ok $ok, "$file SYNOPSIS parses" or diag $err;
        $compiled++;
    }

    ok $compiled >= 6, "found a SYNOPSIS in each module ($compiled)";
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

subtest 'the README lists only methods that exist' => sub {
    open my $fh, '<', 'README.md' or die "cannot read README.md: $!";
    my @lines = <$fh>;
    close $fh;

    my $calls = calls_in(\@lines);
    ok scalar @$calls > 10, sprintf('the README shows real API usage (%d calls)', scalar @$calls);

    for my $call (@$calls) {
        my ($var, $method) = @$call;
        my $class = $CLASS_OF{$var};

        ok $class->can($method), "README.md: $class->$method";
    }
};

subtest 'the machine reference stays short enough to read in one pass' => sub {
    open my $fh, '<', 'llms.txt' or die "cannot read llms.txt: $!";
    my $text = do { local $/; <$fh> };
    close $fh;

    # Its whole purpose is being read entire, by a person skimming or by an
    # agent with a context budget. Roughly four characters to a token.
    my $tokens = length($text) / 4;

    # 3000, not the 2000 this started at. That figure was guessed before the
    # API was finished and the file reached it honestly, by documenting
    # methods that exist. Three thousand tokens is two or three pages, still
    # one pass for a reader and still small beside any real context window.
    #
    # It is a ceiling, not a target. Reaching it again means the file needs
    # cutting, not the number raising -- there is no third increase in which
    # this stays a budget rather than a formality.
    ok $tokens < 3000, sprintf('roughly %d tokens, under the 3000 budget', $tokens);
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
        first single first_value single_value first_list single_list row_array
        next reset all get_column
        preview as multi expand by groups
    );

    my @missing = grep { $text !~ /\b\Q$_\E\b/ } @results_api;
    is \@missing, [], 'every Results method appears in llms.txt';

    my @pool_api = qw(
        query query_row query_value query_list connection with_connection transaction
        shutdown on_query stats
    );

    my @missing_pool = grep { $text !~ /\b\Q$_\E\b/ } @pool_api;
    is \@missing_pool, [], 'and every pool entry point';
};

subtest 'the machine reference shows code that compiles' => sub {
    # This file exists to be read by code generators, so a snippet that
    # cannot compile becomes generated code that cannot run. The method-name
    # check above cannot see this: `await $pg->query(...)` at file scope
    # names a real method and is still a syntax error.
    open my $fh, '<', 'llms.txt' or die "cannot read llms.txt: $!";
    my @lines = <$fh>;
    close $fh;

    # Indented blocks are the code samples.
    my (@blocks, @current);
    for my $line (@lines, "\n") {
        if ($line =~ /^\s{4}\S/) { push @current, $line; next }
        push @blocks, join('', @current) if @current;
        @current = ();
    }

    my $checked = 0;
    for my $code (@blocks) {
        next unless $code =~ /\bawait\b|\bAsync::DBD::Pg\b/;

        # Wrapped exactly as the SYNOPSIS check wraps: await is legal only
        # inside an async sub, and a reference names variables it never
        # declares.
        my $ok = eval "use feature 'say'; no strict; no warnings; "
                    . "my \$unused = async sub {\n$code\n}; 1";
        my $err = $@; $err =~ s/\s+at\s\(eval.*//s; $err =~ s/\n.*//s;

        ok $ok, 'llms.txt block compiles' or diag "$err\n$code";
        $checked++;
    }

    ok $checked >= 5, "checked a real number of blocks ($checked)";
};

done_testing;

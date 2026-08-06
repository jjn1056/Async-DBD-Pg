use strict;
use warnings;
use Test2::V0;

# The examples are documentation that happens to be executable. Nothing else
# in this suite looks at them, so a rename in lib/ can break all eight and
# every test still passes. This checks the two properties that can be checked
# without a database: they compile, and they follow the idiom the
# documentation now teaches.

my @examples = sort glob 'examples/*/app.pl';

ok scalar @examples >= 8, 'found the examples' or diag "found: @examples";

for my $file (@examples) {
    my $out = qx{$^X -Ilib -c \Q$file\E 2>&1};
    like $out, qr/syntax OK/, "$file compiles" or diag $out;

    open my $fh, '<', $file or die "cannot read $file: $!";
    my $src = do { local $/; <$fh> };
    close $fh;

    # Without a real Future::IO implementation the pool runs serially, with
    # no error and no warning. Every example must load one.
    like $src, qr/Future::IO->load_best_impl/,
        "$file loads a Future::IO implementation";

    # A connection taken by hand is lost to the pool if anything between the
    # checkout and the release dies. The examples should demonstrate the
    # scoped forms instead.
    unlike $src, qr/->connection\b/,
        "$file does not check a connection out by hand";

    like $src, qr/\bshutdown\b/, "$file shuts the pool down";
}

done_testing;

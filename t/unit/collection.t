use strict;
use warnings;
use Test2::V0;

use Async::DBD::Pg::Collection;

sub collection { Async::DBD::Pg::Collection->new(@_) }

subtest 'a Collection is a blessed arrayref' => sub {
    # Every caller that treats a result's rows as a plain arrayref has to keep
    # working, which is the whole reason this is an arrayref and not a class
    # wrapping one.
    my $c = collection('a', 'b', 'c');

    isa_ok $c, 'Async::DBD::Pg::Collection';
    is scalar @$c, 3, 'dereferences as an array';
    is $c->[0], 'a', 'indexes directly';
    is [ @$c ], ['a', 'b', 'c'], 'flattens';
};

subtest 'size, first and last' => sub {
    my $c = collection('a', 'b', 'c');

    is $c->size, 3, 'size';
    is $c->first, 'a', 'first';
    is $c->last, 'c', 'last';

    my $empty = collection();
    is $empty->size, 0, 'size of an empty collection';
    is $empty->first, undef, 'first of an empty collection is undef';
    is $empty->last, undef, 'last of an empty collection is undef';
};

subtest 'each calls back once per element and returns the count' => sub {
    my $c = collection('a', 'b', 'c');

    my @seen;
    my $n = $c->each(sub { push @seen, $_[0] });

    is \@seen, ['a', 'b', 'c'], 'called once per element, in order';
    is $n, 3, 'returns the number of elements';

    # Trailing arguments are forwarded, matching Cursor::each, so a callback
    # can take what it needs without closing over it.
    my @with_args;
    $c->each(sub { push @with_args, [@_] }, 'x', 'y');
    is $with_args[0], ['a', 'x', 'y'], 'arguments trail the element';

    is collection()->each(sub { die 'must not run' }), 0,
        'an empty collection calls back never and returns 0';
};

subtest 'compact removes undef and nothing else' => sub {
    # A NULL arrives as undef and is usually noise. An empty string is a real
    # value a column can hold, so dropping it would lose data.
    my $c = collection('a', undef, 'b', '', 0, undef);
    my $compact = $c->compact;

    is [ @$compact ], ['a', 'b', '', 0], 'undef removed, empty string and zero kept';
    isa_ok $compact, 'Async::DBD::Pg::Collection';
    is [ @$c ], ['a', undef, 'b', '', 0, undef], 'the original is unchanged';
};

subtest 'join' => sub {
    my $c = collection('a', 'b', 'c');

    is $c->join('-'), 'a-b-c', 'joins with the given separator';
    is $c->join, 'abc', 'separator defaults to empty';
    is collection()->join('-'), '', 'an empty collection joins to an empty string';
};

subtest 'to_array returns a plain unblessed arrayref' => sub {
    my $c = collection('a', 'b');
    my $plain = $c->to_array;

    is ref $plain, 'ARRAY', 'a plain arrayref, not a Collection';
    is $plain, ['a', 'b'], 'same elements';

    push @$plain, 'c';
    is $c->size, 2, 'a copy, so changing it leaves the collection alone';
};

done_testing;

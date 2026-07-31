use strict;
use warnings;
use Test2::V0;

use Async::DBD::Pg::Cursor;

# Cursor names and fetch counts are part of the SQL text rather than bind
# parameters, because PostgreSQL does not allow either to be parameterised.
# They therefore have to be validated before they reach a statement.

subtest 'accepts ordinary cursor names' => sub {
    for my $name (qw(c cursor_1 _private CUR123 a_b_c)) {
        ok lives { Async::DBD::Pg::Cursor::_validate_name($name) }, "accepts '$name'";
    }

    # The generated names must satisfy our own rule.
    my $generated = Async::DBD::Pg::Cursor::_generate_name();
    ok lives { Async::DBD::Pg::Cursor::_validate_name($generated) },
        "accepts generated name '$generated'";
};

subtest 'rejects cursor names that would alter the statement' => sub {
    my @hostile = (
        'c; DROP TABLE users',
        'c;SELECT 1',
        'c--comment',
        'c/*comment*/',
        'c"quoted"',
        "c'quoted'",
        'c d',
        'c)',
        '1leading_digit',
        '',
    );

    for my $name (@hostile) {
        ok dies { Async::DBD::Pg::Cursor::_validate_name($name) },
            "rejects '$name'";
    }

    ok dies { Async::DBD::Pg::Cursor::_validate_name(undef) }, 'rejects undef';

    # PostgreSQL truncates identifiers beyond NAMEDATALEN-1.
    ok dies { Async::DBD::Pg::Cursor::_validate_name('c' x 64) },
        'rejects an over-long identifier';
    ok lives { Async::DBD::Pg::Cursor::_validate_name('c' x 63) },
        'accepts an identifier at the limit';
};

subtest 'accepts positive integer batch sizes' => sub {
    for my $size (1, 10, 1000, '500') {
        ok lives { Async::DBD::Pg::Cursor::_validate_batch_size($size) },
            "accepts '$size'";
    }
};

subtest 'rejects batch sizes that are not positive integers' => sub {
    my @bad = ('0', '-1', '1; DROP TABLE users', 'abc', '1.5', '', ' 1', '1 ');

    for my $size (@bad) {
        ok dies { Async::DBD::Pg::Cursor::_validate_batch_size($size) },
            "rejects '$size'";
    }

    ok dies { Async::DBD::Pg::Cursor::_validate_batch_size(undef) }, 'rejects undef';
};

done_testing;

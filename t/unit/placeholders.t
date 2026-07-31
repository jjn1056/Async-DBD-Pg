use strict;
use warnings;
use Test2::V0;

use Async::DBD::Pg::Util qw(convert_placeholders);

subtest 'no placeholders' => sub {
    my ($sql, $bind) = convert_placeholders('SELECT * FROM users', {});
    is $sql, 'SELECT * FROM users', 'SQL unchanged';
    is $bind, [], 'no bind values';
};

subtest 'single named placeholder' => sub {
    my ($sql, $bind) = convert_placeholders(
        'SELECT * FROM users WHERE id = :id',
        { id => 42 }
    );
    is $sql, 'SELECT * FROM users WHERE id = $1', 'placeholder converted';
    is $bind, [42], 'bind value extracted';
};

subtest 'multiple named placeholders' => sub {
    my ($sql, $bind) = convert_placeholders(
        'SELECT * FROM users WHERE name = :name AND age > :age',
        { name => 'Alice', age => 21 }
    );
    is $sql, 'SELECT * FROM users WHERE name = $1 AND age > $2', 'placeholders converted';
    is $bind, ['Alice', 21], 'bind values in order of appearance';
};

subtest 'repeated placeholder' => sub {
    my ($sql, $bind) = convert_placeholders(
        'SELECT * FROM t WHERE a = :foo AND b = :bar AND c = :foo',
        { foo => 1, bar => 2 }
    );
    is $sql, 'SELECT * FROM t WHERE a = $1 AND b = $2 AND c = $1', 'repeated placeholder reuses number';
    is $bind, [1, 2], 'only unique values in bind array';
};

subtest 'placeholder with underscore' => sub {
    my ($sql, $bind) = convert_placeholders(
        'SELECT * FROM users WHERE user_id = :user_id',
        { user_id => 123 }
    );
    is $sql, 'SELECT * FROM users WHERE user_id = $1', 'underscore in placeholder name';
    is $bind, [123], 'bind value';
};

subtest 'placeholder at end of statement' => sub {
    my ($sql, $bind) = convert_placeholders(
        'UPDATE users SET active = :active',
        { active => 1 }
    );
    is $sql, 'UPDATE users SET active = $1', 'placeholder at end';
    is $bind, [1], 'bind value';
};

subtest 'numeric placeholder values' => sub {
    my ($sql, $bind) = convert_placeholders(
        'INSERT INTO t (a, b, c) VALUES (:a, :b, :c)',
        { a => 1, b => 2.5, c => 0 }
    );
    is $sql, 'INSERT INTO t (a, b, c) VALUES ($1, $2, $3)', 'placeholders converted';
    is $bind, [1, 2.5, 0], 'numeric values preserved';
};

subtest 'undef value' => sub {
    my ($sql, $bind) = convert_placeholders(
        'UPDATE users SET name = :name WHERE id = :id',
        { name => undef, id => 1 }
    );
    is $sql, 'UPDATE users SET name = $1 WHERE id = $2', 'placeholders converted';
    is $bind, [undef, 1], 'undef preserved in bind array';
};

subtest 'string with colon that is not a placeholder' => sub {
    my ($sql, $bind) = convert_placeholders(
        q{SELECT '10:30' AS time, id FROM t WHERE name = :name},
        { name => 'test' }
    );
    is $sql, q{SELECT '10:30' AS time, id FROM t WHERE name = $1}, 'colon in string preserved';
    is $bind, ['test'], 'only actual placeholder extracted';
};

subtest 'cast syntax preserved' => sub {
    my ($sql, $bind) = convert_placeholders(
        'SELECT :val::integer',
        { val => 42 }
    );
    is $sql, 'SELECT $1::integer', 'PostgreSQL cast syntax preserved';
    is $bind, [42], 'bind value';
};

subtest 'empty hash' => sub {
    my ($sql, $bind) = convert_placeholders(
        'SELECT 1',
        {}
    );
    is $sql, 'SELECT 1', 'SQL unchanged';
    is $bind, [], 'empty bind array';
};

subtest 'positional placeholders pass through' => sub {
    my ($sql, $bind) = convert_placeholders(
        'SELECT * FROM users WHERE id = $1',
        {}
    );
    is $sql, 'SELECT * FROM users WHERE id = $1', 'positional placeholder unchanged';
    is $bind, [], 'no bind values';
};

subtest 'named placeholder with no matching parameter is rejected' => sub {
    # Passing the literal ':name' through produces SQL that PostgreSQL
    # rejects with a syntax error pointing at the wrong thing, so the
    # mistake is reported here instead.
    my $err = dies {
        convert_placeholders('SELECT * FROM users WHERE id = :id', {})
    };

    ok $err, 'missing placeholder is an error';
    like $err, qr/\bid\b/, 'error names the placeholder';

    my $partial = dies {
        convert_placeholders(
            'SELECT * FROM users WHERE id = :id AND name = :name',
            { id => 1 }
        )
    };
    like $partial, qr/\bname\b/, 'error names the placeholder that is missing';

    ok lives {
        convert_placeholders(
            'SELECT * FROM users WHERE id = :id AND name = :name',
            { id => 1, name => 'x' }
        )
    }, 'no error when every placeholder is supplied';
};

subtest 'colons that are not placeholders are left alone' => sub {
    # An array slice bound is a bare integer, not an identifier, so it must
    # not be mistaken for a placeholder name.
    my ($slice) = convert_placeholders('SELECT arr[1:3] FROM t', {});
    is $slice, 'SELECT arr[1:3] FROM t', 'array slice preserved';

    my ($open_slice) = convert_placeholders('SELECT arr[:2] FROM t', {});
    is $open_slice, 'SELECT arr[:2] FROM t', 'slice with omitted lower bound preserved';

    my ($cast) = convert_placeholders('SELECT 1::integer', {});
    is $cast, 'SELECT 1::integer', 'cast preserved';

    my ($quoted) = convert_placeholders("SELECT ':id' AS literal", {});
    is $quoted, "SELECT ':id' AS literal", 'colon inside a string literal preserved';
};

done_testing;

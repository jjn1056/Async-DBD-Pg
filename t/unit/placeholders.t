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

# Everything below guards regions of a statement where a colon must not be
# read as a placeholder. Each case carries a real :a elsewhere, so a scanner
# that bails out early fails the same way a scanner that over-matches does.

subtest 'decoy in a dollar-quoted string is not a placeholder' => sub {
    my ($plain, $plain_bind) = convert_placeholders(
        'SELECT $$:id$$ AS body, :a', { a => 1 }
    );
    is $plain, 'SELECT $$:id$$ AS body, $1', 'untagged dollar-quoted body preserved';
    is $plain_bind, [1], 'the real placeholder still binds';

    my ($tagged, $tagged_bind) = convert_placeholders(
        'SELECT $q$:id$q$ AS body, :a', { a => 1 }
    );
    is $tagged, 'SELECT $q$:id$q$ AS body, $1', 'tagged dollar-quoted body preserved';
    is $tagged_bind, [1], 'the real placeholder still binds';

    my ($digits) = convert_placeholders('SELECT $q1$:id$q1$, :a', { a => 1 });
    is $digits, 'SELECT $q1$:id$q1$, $1', 'tag containing digits preserved';

    # Only the matching tag closes the string, so the $$ inside is body text.
    my ($nested_tag) = convert_placeholders('SELECT $q$ a $$ :id $q$, :a', { a => 1 });
    is $nested_tag, 'SELECT $q$ a $$ :id $q$, $1',
        'a different dollar delimiter inside does not close the string';

    my ($two) = convert_placeholders('SELECT $$:x$$, $$:y$$, :a', { a => 1 });
    is $two, 'SELECT $$:x$$, $$:y$$, $1', 'two dollar-quoted strings in one statement';
};

subtest 'decoy in a comment is not a placeholder' => sub {
    my ($line, $line_bind) = convert_placeholders(
        "SELECT 1 -- :note\n, :a", { a => 1 }
    );
    is $line, "SELECT 1 -- :note\n, \$1", 'line comment preserved';
    is $line_bind, [1], 'the real placeholder still binds';

    my ($block) = convert_placeholders('SELECT 1 /* :note */, :a', { a => 1 });
    is $block, 'SELECT 1 /* :note */, $1', 'block comment preserved';

    # PostgreSQL block comments nest, so the decoy sits after the inner close
    # where a first-*/ scanner would wrongly treat it as live SQL.
    my ($nested) = convert_placeholders(
        'SELECT 1 /* a /* b */ :note */, :a', { a => 1 }
    );
    is $nested, 'SELECT 1 /* a /* b */ :note */, $1', 'nested block comment preserved';

    my ($trailing) = convert_placeholders('SELECT :a -- :note', { a => 1 });
    is $trailing, 'SELECT $1 -- :note', 'line comment running to end of statement';

    my ($unterminated) = convert_placeholders('SELECT :a /* :note', { a => 1 });
    is $unterminated, 'SELECT $1 /* :note', 'unterminated block comment swallows the rest';
};

subtest 'backslash escapes apply inside E-strings only' => sub {
    # The scanner previously ended the string at the escaped quote, so the
    # rest of the statement was read as string content: :a came back
    # unconverted with an empty bind list, and nothing died. Asserting on the
    # output rather than on survival is what catches that.
    my ($upper, $upper_bind) = convert_placeholders("SELECT E'it\\'s ok', :a", { a => 1 });
    is $upper, "SELECT E'it\\'s ok', \$1", 'E-string with an escaped quote preserved';
    is $upper_bind, [1], 'the real placeholder still binds';

    my ($lower, $lower_bind) = convert_placeholders("SELECT e'it\\'s ok', :a", { a => 1 });
    is $lower, "SELECT e'it\\'s ok', \$1", 'lower-case e prefix recognised';
    is $lower_bind, [1], 'the real placeholder still binds';

    my ($decoy) = convert_placeholders("SELECT E'\\' :id ', :a", { a => 1 });
    is $decoy, "SELECT E'\\' :id ', \$1", 'a decoy after an escaped quote stays inside the string';

    # In a standard string a backslash is an ordinary character and the
    # string ends at the next quote. Treating it as an escape here would
    # swallow the rest of the statement.
    my ($std, $std_bind) = convert_placeholders("SELECT 'a\\', :a", { a => 1 });
    is $std, "SELECT 'a\\', \$1", 'trailing backslash in a standard string is literal';
    is $std_bind, [1], 'the real placeholder still binds';

    # A doubled quote is the standard escape and must keep working in both.
    my ($doubled) = convert_placeholders("SELECT 'it''s ok', :a", { a => 1 });
    is $doubled, "SELECT 'it''s ok', \$1", 'doubled quote in a standard string';

    my ($e_doubled) = convert_placeholders("SELECT E'it''s ok', :a", { a => 1 });
    is $e_doubled, "SELECT E'it''s ok', \$1", 'doubled quote in an E-string';
};

done_testing;

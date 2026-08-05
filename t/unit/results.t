use strict;
use warnings;
use Test2::V0;

use Async::DBD::Pg::Results;

# Results stores rows positionally and derives hashes on demand, so these
# build from arrayrefs plus a name list -- the same shape the constructor
# takes from a statement handle.
sub results {
    my (%args) = @_;
    return Async::DBD::Pg::Results->new_from_data(
        rows          => $args{rows}    // [],
        columns       => $args{columns} // [],
        types         => $args{types},
        rows_affected => $args{rows_affected},
    );
}

sub people {
    results(
        columns => ['id', 'name'],
        types   => ['int4', 'text'],
        rows    => [ [1, 'Alice'], [2, 'Bob'], [3, 'Charlie'] ],
    );
}

# A self-join selecting the same column twice. A hash cannot hold both, which
# is what every duplicate-column assertion below is about.
sub duplicated {
    results(
        columns => ['id', 'id', 'name', 'name'],
        types   => ['int4', 'int4', 'text', 'text'],
        rows    => [ [1, 2, 'Alice', 'Bob'] ],
    );
}

subtest 'metadata' => sub {
    my $r = people();

    is $r->columns, ['id', 'name'], 'columns in order';
    is $r->types, ['int4', 'text'], 'PostgreSQL type names, aligned by position';
    is $r->count, 3, 'count';
    ok !$r->is_empty, 'not empty';

    my $none = results(columns => ['id'], types => ['int4']);
    ok $none->is_empty, 'a result with no rows is empty';
    is $none->count, 0, 'count is 0';
};

subtest 'rows are hashrefs in a Collection' => sub {
    my $r = people();
    my $rows = $r->rows;

    isa_ok $rows, 'Async::DBD::Pg::Collection';
    is $rows->size, 3, 'size';

    # The arrayref forms every existing caller uses have to keep working.
    is scalar @$rows, 3, 'dereferences as an array';
    is $rows->[0]{name}, 'Alice', 'indexes and keys through';
    is [ map { $_->{name} } @$rows ], ['Alice', 'Bob', 'Charlie'], 'maps';
};

subtest 'arrays are arrayrefs in a Collection' => sub {
    my $r = people();
    my $arrays = $r->arrays;

    isa_ok $arrays, 'Async::DBD::Pg::Collection';
    is $arrays->[0], [1, 'Alice'], 'positional row';
    is [ map { $_->[1] } @$arrays ], ['Alice', 'Bob', 'Charlie'], 'column by index';
};

subtest 'row_array returns one row positionally' => sub {
    my $r = people();

    is $r->row_array(0), [1, 'Alice'], 'first row';
    is $r->row_array(2), [3, 'Charlie'], 'last row';
    is $r->row_array(3), undef, 'past the end is undef';
};

subtest 'duplicate column names reach every positional view' => sub {
    # This is the data loss the design exists to remove: four columns were
    # selected, and a hash could only ever have held two.
    my $r = duplicated();

    is $r->columns, ['id', 'id', 'name', 'name'], 'columns reports all four';
    is $r->types, ['int4', 'int4', 'text', 'text'], 'types reports all four';
    is $r->count, 1, 'count';
    ok !$r->is_empty, 'not empty';
    is $r->arrays->[0], [1, 2, 'Alice', 'Bob'], 'every value is reachable';
    is $r->row_array(0), [1, 2, 'Alice', 'Bob'], 'row_array too';
};

subtest 'duplicate column names make every hash view croak' => sub {
    my $r = duplicated();

    my $expected = qr/Column 'id' appears 2 times at positions 0, 1/;

    like dies { $r->rows },   $expected, 'rows croaks';
    like dies { $r->first },  $expected, 'first croaks';
    like dies { $r->single }, $expected, 'single croaks';
    like dies { $r->next },   $expected, 'next croaks';
    like dies { $r->all },    $expected, 'all croaks';

    like dies { $r->rows }, qr/->arrays or ->as/,
        'the message names the ways out';
};

subtest 'first takes what is there, single expects exactly one' => sub {
    my $r = people();

    is $r->first, { id => 1, name => 'Alice' }, 'first is the first row';
    is $r->first->{name}, 'Alice', 'and is an ordinary hashref';

    my $warning;
    {
        local $SIG{__WARN__} = sub { $warning = shift };
        is $r->single, { id => 1, name => 'Alice' }, 'single returns the first row';
    }
    like $warning, qr/3 rows/, 'single warns when more than one row matched';

    # first is lax by design, so it must stay silent on the same data.
    my $quiet;
    {
        local $SIG{__WARN__} = sub { $quiet = shift };
        $r->first;
    }
    is $quiet, undef, 'first does not warn';
};

subtest 'first and single on an empty result' => sub {
    my $r = results(columns => ['id'], types => ['int4']);

    is $r->first, undef, 'first is undef';

    my $warning;
    {
        local $SIG{__WARN__} = sub { $warning = shift };
        is $r->single, undef, 'single is undef';
    }
    is $warning, undef, 'no match is an ordinary outcome, not a warning';
};

subtest 'single_value takes the first column of the first row' => sub {
    my $r = results(columns => ['total'], types => ['int8'], rows => [[42]]);
    is $r->single_value, 42, 'the value';

    my $none = results(columns => ['total'], types => ['int8']);
    is $none->single_value, undef, 'undef when there are no rows';

    my $several = results(
        columns => ['id'], types => ['int4'], rows => [[1], [2]],
    );
    my $warning;
    {
        local $SIG{__WARN__} = sub { $warning = shift };
        is $several->single_value, 1, 'the first value';
    }
    like $warning, qr/2 rows/, 'warns when more than one row matched';

    # Positional, so it never builds a hash and duplicates cannot stop it.
    is duplicated()->single_value, 1, 'works on a duplicate-column result';
};

subtest 'first_value is the lax counterpart to single_value' => sub {
    my $several = results(
        columns => ['id'], types => ['int4'], rows => [[1], [2], [3]],
    );

    # The pair matches first/single for rows: take what is there, against
    # I expected one and want telling if I was wrong.
    my $warning;
    {
        local $SIG{__WARN__} = sub { $warning = shift };
        is $several->first_value, 1, 'the first value';
    }
    is $warning, undef, 'and no complaint about the other two';

    my $none = results(columns => ['id'], types => ['int4']);
    is $none->first_value, undef, 'undef when there are no rows';

    # Positional, like single_value, so duplicates cannot stop it.
    is duplicated()->first_value, 1, 'works on a duplicate-column result';
};

subtest 'first_list gives one row as a list of values' => sub {
    my $r = people();

    my ($id, $name) = $r->first_list;
    is $id, 1, 'first column';
    is $name, 'Alice', 'second column';

    # Scalar context returns the arrayref rather than a count, because a
    # count is a plausible-looking wrong number and an arrayref is not.
    my $aref = $r->first_list;
    is $aref, [1, 'Alice'], 'scalar context gives an arrayref';

    my $none = results(columns => ['id'], types => ['int4']);
    is [ $none->first_list ], [], 'no rows is an empty list';
    is scalar($none->first_list), undef, 'and undef in scalar context';

    # Positional, so a repeated column name cannot stop it. This is the
    # escape hatch from query_row's croak, alongside query_value.
    is [ duplicated()->first_list ], [1, 2, 'Alice', 'Bob'],
        'every value of a duplicate-column row';

    my $quiet;
    {
        local $SIG{__WARN__} = sub { $quiet = shift };
        $r->first_list;
    }
    is $quiet, undef, 'first_list takes what is there without complaint';
};

subtest 'single_list is the strict counterpart' => sub {
    my $r = people();

    my ($id, $name, $warning);
    {
        local $SIG{__WARN__} = sub { $warning = shift };
        ($id, $name) = $r->single_list;
    }

    is [$id, $name], [1, 'Alice'], 'the first row is still returned';
    like $warning, qr/single_list/, 'the warning names the method';
    like $warning, qr/3 rows/, 'and how many matched';

    my $one = results(
        columns => ['id', 'name'], types => ['int4', 'text'], rows => [[9, 'Zoe']],
    );
    my $silent;
    {
        local $SIG{__WARN__} = sub { $silent = shift };
        is [ $one->single_list ], [9, 'Zoe'], 'exactly one row';
    }
    is $silent, undef, 'is not warned about';
};

subtest 'next and reset walk the rows' => sub {
    my $r = people();

    is $r->next, { id => 1, name => 'Alice' }, 'first call';
    is $r->next, { id => 2, name => 'Bob' }, 'second call';
    is $r->next, { id => 3, name => 'Charlie' }, 'third call';
    is $r->next, undef, 'exhausted';
    is $r->next, undef, 'and stays exhausted';

    $r->reset;
    is $r->next, { id => 1, name => 'Alice' }, 'reset returns to the start';
};

subtest 'all returns the remaining rows' => sub {
    my $r = people();

    my $everything = $r->all;
    isa_ok $everything, 'Async::DBD::Pg::Collection';
    is $everything->size, 3, 'every row';

    my $partial = people();
    $partial->next;
    is $partial->all->size, 2, 'from the current position';
};

subtest 'get_column by name and by index' => sub {
    my $r = people();

    my $by_name = $r->get_column('name');
    is $by_name->name, 'name', 'name';
    is $by_name->index, 1, 'index';
    is [ @{ $by_name->all } ], ['Alice', 'Bob', 'Charlie'], 'values';
    is $by_name->first, 'Alice', 'first value';

    my $by_index = $r->get_column(0);
    is $by_index->name, 'id', 'looked up by index';
    is [ @{ $by_index->all } ], [1, 2, 3], 'values';
};

subtest 'a Column walks its values' => sub {
    my $col = people()->get_column('name');

    is $col->next, 'Alice', 'first';
    is $col->next, 'Bob', 'second';
    is $col->next, 'Charlie', 'third';
    is $col->next, undef, 'exhausted';

    $col->reset;
    is $col->next, 'Alice', 'reset returns to the start';
};

subtest 'get_column never guesses' => sub {
    my $r = people();

    # Returning undef for a typo is the silent failure this design removes.
    my $missing = dies { $r->get_column('idd') };
    like $missing, qr/No column 'idd'/, 'names what was asked for';
    like $missing, qr/columns are: id, name/, 'lists what is available';

    like dies { $r->get_column(7) },
        qr/Column index 7 out of range; result has 2 columns/,
        'an out-of-range index says how many there are';

    like dies { duplicated()->get_column('id') },
        qr/Column 'id' appears 2 times at positions 0, 1; ask for one by index/,
        'an ambiguous name names the positions instead of choosing';

    # Asking by index is how the ambiguity is resolved.
    is duplicated()->get_column(1)->first, 2, 'by index on a duplicate name';
};

subtest 'as renames every column from a list' => sub {
    my $r = duplicated();
    my $v = $r->as(['a_id', 'b_id', 'a_name', 'b_name']);

    is $v->columns, ['a_id', 'b_id', 'a_name', 'b_name'], 'the view reports the new names';
    is $r->columns, ['id', 'id', 'name', 'name'],
        'the original still reports the raw ones, duplicates intact';

    # Renaming is the way out of the croak, so the hash views must now work.
    is $v->rows->[0], { a_id => 1, b_id => 2, a_name => 'Alice', b_name => 'Bob' },
        'rows under the new names, with nothing lost';
    is $v->first->{b_name}, 'Bob', 'first';
    is $v->get_column('b_id')->first, 2, 'get_column by new name';
    is $v->types, ['int4', 'int4', 'text', 'text'], 'types stay aligned by position';
    is $v->count, 1, 'count';
};

subtest 'as renames selected columns by index' => sub {
    my $r = duplicated();
    my $v = $r->as({ 0 => 'a_id', 2 => 'a_name' });

    is $v->columns, ['a_id', 'id', 'a_name', 'name'],
        'only the named indexes change; the rest keep their raw names';
    is $v->rows->[0], { a_id => 1, id => 2, a_name => 'Alice', name => 'Bob' },
        'and the result is addressable by name again';
};

subtest 'as refuses a rename it cannot honour' => sub {
    my $r = duplicated();

    like dies { $r->as(['only', 'three', 'names']) },
        qr/as expects 4 names for 4 columns, got 3/,
        'a short list is an error rather than a partial rename';

    like dies { $r->as({ 9 => 'nope' }) },
        qr/Column index 9 out of range; result has 4 columns/,
        'an index that names no column is an error';

    # Renaming that leaves a collision has not solved anything, and finding
    # out at the next ->rows would point at the wrong line.
    like dies { $r->as({ 0 => 'name' }) },
        qr/leaves 'name' at positions 0, 2, 3/,
        'a rename that still collides is refused here, not later';
};

subtest 'a view iterates independently of the result it came from' => sub {
    my $r = people();
    my $v = $r->as(['n', 'who']);

    # Sharing the rows but not the position is what makes as safe to call on
    # a half-read result.
    is $v->next, { n => 1, who => 'Alice' }, 'the view starts at the beginning';
    is $v->next, { n => 2, who => 'Bob' }, 'and advances';
    is $r->next, { id => 1, name => 'Alice' },
        'the original has not moved';

    $r->next;
    is $v->next, { n => 3, who => 'Charlie' },
        'and moving the original does not move the view';

    my $half = people();
    $half->next;
    is $half->as(['n', 'who'])->next, { n => 1, who => 'Alice' },
        'a view of a half-read result starts from the top';
};

subtest 'multi addresses a duplicate-column result by name, losslessly' => sub {
    skip_all 'Hash::MultiValue is not installed'
        unless eval { require Hash::MultiValue; 1 };

    my $r = duplicated();
    my $multi = $r->multi;

    isa_ok $multi, 'Async::DBD::Pg::Collection';
    is $multi->size, 1, 'one row';

    my $row = $multi->first;
    isa_ok $row, 'Hash::MultiValue';

    # This is the point of it: a repeated name keeps every value, so unlike
    # rows it has nothing to refuse and does not croak.
    is [ $row->get_all('id') ], [1, 2], 'both values of the repeated name';
    is [ $row->get_all('name') ], ['Alice', 'Bob'], 'and of the other one';
    # Scalar access keeps the last, which is what assigning a repeated key
    # into a plain Perl hash would have done as well.
    is $row->{id}, 2, 'hash access gives the last value';
    is $row->get('id'), 2, 'and so does get';

    my $renamed = $r->as(['a_id', 'b_id', 'a_name', 'b_name'])->multi;
    is $renamed->first->{b_id}, 2, 'a view multi uses the renamed columns';
};

sub staff {
    results(
        columns => ['id', 'name', 'dept'],
        types   => ['int4', 'text', 'text'],
        rows    => [
            [1, 'Alice', 'eng'],
            [2, 'Bob',   'eng'],
            [3, 'Carol', 'sales'],
        ],
    );
}

subtest 'by builds a lookup and refuses to lose a row' => sub {
    my $lookup = staff()->by('id');

    is [ sort keys %$lookup ], [1, 2, 3], 'keyed by the column value';
    is $lookup->{2}, { id => 2, name => 'Bob', dept => 'eng' }, 'values are rows';

    # The hand-rolled map version keeps the last row silently. This is the
    # same data loss as a collapsed column, so it gets the same treatment.
    my $err = dies { staff()->by('dept') };
    like $err, qr/Value 'eng' in column 'dept' appears 2 times/,
        'names the value, the column and the count';
    like $err, qr/use ->groups/, 'and points at the lossless one';

    like dies { staff()->by('nope') },
        qr/No column 'nope'; columns are: id, name, dept/,
        'a missing column lists what is available';

    # The advice has to be one by can take. get_column says "ask for one by
    # index", which is no use to a method that keys on a name.
    my $dup = dies { duplicated()->by('id') };
    like $dup, qr/Column 'id' appears 2 times at positions 0, 1/,
        'a repeated column name croaks before the lookup is built';
    like $dup, qr/->arrays or ->as/, 'and points at a fix by can actually use';

    # A hash key is a string, so a NULL would silently become the empty
    # string and merge with a row that genuinely holds one.
    my $nullable = results(
        columns => ['id', 'tag'],
        types   => ['int4', 'text'],
        rows    => [ [1, 'a'], [2, undef] ],
    );
    like dies { $nullable->by('tag') },
        qr/Column 'tag' holds NULL, which cannot key a lookup/,
        'a NULL key is refused rather than folded into the empty string';
    like dies { $nullable->groups('tag') },
        qr/holds NULL/, 'groups refuses it too';
};

subtest 'groups keeps every row' => sub {
    my $groups = staff()->groups('dept');

    is [ sort keys %$groups ], ['eng', 'sales'], 'one key per distinct value';
    isa_ok $groups->{eng}, 'Async::DBD::Pg::Collection';
    is $groups->{eng}->size, 2, 'both rows in the group';
    is [ map { $_->{name} } @{ $groups->{eng} } ], ['Alice', 'Bob'],
        'in the order they arrived';
    is $groups->{sales}->size, 1, 'and the single-row group';

    like dies { staff()->groups('nope') },
        qr/No column 'nope'; columns are: id, name, dept/,
        'a missing column lists what is available';
};

subtest 'lookups follow a renamed view' => sub {
    my $v = duplicated()->as(['a_id', 'b_id', 'a_name', 'b_name']);

    my $lookup = $v->by('b_id');
    is [ keys %$lookup ], [2], 'keyed by the renamed column';
    is $lookup->{2}{a_name}, 'Alice', 'and the rows carry the renamed keys';
};

subtest 'expand decodes the json columns and leaves the rest alone' => sub {
    skip_all 'JSON::MaybeXS is not installed'
        unless eval { require JSON::MaybeXS; 1 };

    my $r = results(
        columns => ['id', 'payload', 'doc', 'note'],
        types   => ['int4', 'jsonb', 'json', 'text'],
        rows    => [
            [1, '{"user":{"name":"Alice"}}', '[1,2,3]', '{"not":"json"}'],
        ],
    );

    my $e = $r->expand;
    my $row = $e->rows->[0];

    is $row->{payload}{user}{name}, 'Alice', 'jsonb decoded to a structure';
    is $row->{doc}, [1, 2, 3], 'json decoded too';

    # A text column that happens to hold JSON is text. Choosing by pg_type
    # rather than by looking at the value is what makes that reliable.
    is $row->{note}, '{"not":"json"}', 'a text column is left byte-identical';
    is $row->{id}, 1, 'and so is everything else';

    is $r->rows->[0]{payload}, '{"user":{"name":"Alice"}}',
        'the original is not mutated';
    is $e->types, ['int4', 'jsonb', 'json', 'text'], 'the view keeps the types';

    # Views compose, which is what makes them worth being views.
    my $composed = $r->as({ 1 => 'body' })->expand;
    is $composed->rows->[0]{body}{user}{name}, 'Alice',
        'as then expand: renamed keys, decoded values';

    my $lookup = $r->as({ 1 => 'body' })->expand->by('id');
    is $lookup->{1}{body}{user}{name}, 'Alice', 'and on through by';

    my $none = people()->expand;
    is $none->rows->[0], { id => 1, name => 'Alice' },
        'a result with no json columns passes straight through';
};

subtest 'expand reports a column it cannot decode' => sub {
    skip_all 'JSON::MaybeXS is not installed'
        unless eval { require JSON::MaybeXS; 1 };

    my $r = results(
        columns => ['id', 'payload'],
        types   => ['int4', 'jsonb'],
        rows    => [ [1, '{"ok":1}'], [2, 'not json at all'] ],
    );

    # PostgreSQL cannot return malformed jsonb, so this means something is
    # badly wrong and it is treated as the serious error it is.
    like dies { $r->expand },
        qr/Could not decode column 'payload' of row 1 as jsonb/,
        'names the column and which row';

    my $nullable = results(
        columns => ['id', 'payload'],
        types   => ['int4', 'jsonb'],
        rows    => [ [1, undef] ],
    );
    is $nullable->expand->rows->[0]{payload}, undef, 'a NULL json column stays undef';
};

subtest 'preview renders shape and a sample, bounded' => sub {
    my $out = people()->preview;

    like $out, qr/\bid\b/, 'names the columns';
    like $out, qr/\bint4\b/, 'with their types';
    like $out, qr/\btext\b/, 'all of them';
    like $out, qr/\b3 rows\b/, 'and the total row count';
    like $out, qr/Alice/, 'shows the data';
    unlike $out, qr/\n\n/, 'no blank lines to scroll past';
};

subtest 'preview never floods' => sub {
    my $many = results(
        columns => ['n'],
        types   => ['int4'],
        rows    => [ map { [$_] } 1 .. 100 ],
    );

    my $default = $many->preview;
    like $default, qr/100 rows/, 'reports the true total';
    is scalar(grep { /^\s*\d+\s*$/ } split /\n/, $default), 5,
        'but renders only the default five';
    like $default, qr/95 more/, 'and says how many it held back';

    is scalar(grep { /^\s*\d+\s*$/ } split /\n/, $many->preview(2)), 2,
        'the count is adjustable';

    # A single wide value must not blow the line out either.
    my $wide = results(
        columns => ['blob'],
        types   => ['text'],
        rows    => [ ['x' x 500] ],
    );
    my $capped = $wide->preview;
    ok length($_) < 200, 'every line is bounded'
        for grep { length } split /\n/, $capped;
    like $capped, qr/\.\.\./, 'a truncated value is marked as truncated';
};

subtest 'preview works where the hash views cannot' => sub {
    # Positional, so this is usable on exactly the result that most needs
    # inspecting: the one whose column names collide.
    my $out = duplicated()->preview;

    like $out, qr/Alice/, 'shows values';
    like $out, qr/Bob/, 'including the ones a hash would have dropped';
    like $out, qr/1 row\b/, 'row count';

    like people()->as(['n', 'who'])->preview, qr/\bwho\b/,
        'a view previews under its own names';
};

subtest 'preview on results with nothing to show' => sub {
    my $no_rows = results(columns => ['id', 'name'], types => ['int4', 'text']);
    my $out = $no_rows->preview;
    like $out, qr/0 rows/, 'says there are none';
    like $out, qr/\bid\b.*\bint4\b/, 'and still describes the shape';

    my $no_columns = results(rows_affected => 7);
    like $no_columns->preview, qr/no columns/, 'a non-row statement says so';
    like $no_columns->preview, qr/rows_affected: 7/, 'and reports its payload';
};

subtest 'rows_affected is the payload for a statement returning none' => sub {
    my $r = results(rows_affected => 5);

    is $r->rows_affected, 5, 'rows_affected';
    is $r->count, 0, 'no rows in hand';
    is $r->columns, [], 'no columns';
    is $r->types, [], 'no types';
    ok $r->is_empty, 'empty';

    # No columns means no duplicates, so nothing croaks.
    is $r->rows->size, 0, 'rows is an empty collection';
    is $r->first, undef, 'first is undef';
};

done_testing;

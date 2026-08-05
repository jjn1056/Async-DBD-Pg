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

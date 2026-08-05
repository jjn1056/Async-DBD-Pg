package Async::DBD::Pg::Results;

use strict;
use warnings;
use Carp qw(croak carp);

use Async::DBD::Pg::Collection;
use Async::DBD::Pg::Column;

# Rows are stored positionally and hashes are derived on demand. A hash
# cannot hold a repeated column name, so storing hashes loses data on any
# self-join; storing arrays loses nothing and measures faster besides.
sub new {
    my ($class, $sth) = @_;

    # Order matters, and not for style. On an async statement handle, reading
    # NAME or pg_type before the fetch leaves the handle with "no statement
    # executing" and the fetch then fails.
    my $names = $sth->{NAME} ? [ @{ $sth->{NAME} } ] : [];

    # An empty NAME is what distinguishes an INSERT or CREATE from a SELECT.
    # The positional fetch dies on such a statement, where the hash form used
    # to return nothing quietly.
    my $rows = @$names ? ( $sth->fetchall_arrayref // [] ) : [];

    my $types = $sth->{pg_type} ? [ @{ $sth->{pg_type} } ] : [];

    my $rows_affected = $sth->rows;
    $sth->finish;

    return $class->_build($rows, $names, $types, $rows_affected);
}

# Build a result from data already in hand, without a statement handle.
sub new_from_data {
    my ($class, %args) = @_;

    return $class->_build(
        $args{rows}    // [],
        $args{columns} // [],
        $args{types}   // [],
        $args{rows_affected} // 0,
    );
}

sub _build {
    my ($class, $rows, $names, $types, $rows_affected) = @_;

    return bless {
        _rows          => $rows,
        _names         => $names,
        _types         => $types,
        _rows_affected => $rows_affected,
        _position      => 0,
        # One pass now so that no hash-producing call has to scan for this,
        # and so arrays consumers never pay for a problem they do not have.
        _positions     => _index_names($names),
    }, $class;
}

# name => [positions], for the duplicate check and for get_column.
sub _index_names {
    my ($names) = @_;

    my %positions;
    push @{ $positions{ $names->[$_] } }, $_ for 0 .. $#$names;

    return \%positions;
}

sub columns       { $_[0]{_names} }
sub types         { $_[0]{_types} }
sub count         { scalar @{ $_[0]{_rows} } }
sub rows_affected { $_[0]{_rows_affected} }
sub is_empty      { !@{ $_[0]{_rows} } }

# Croak before building any hash from a result whose names repeat. Returning
# a hash with the duplicates collapsed is a wrong answer that reports success,
# which is the failure this class is shaped to prevent.
sub _assert_addressable_by_name {
    my ($self) = @_;

    for my $name (@{ $self->{_names} }) {
        my $at = $self->{_positions}{$name};
        next if @$at == 1;

        croak sprintf(
            "Column '%s' appears %d times at positions %s; "
          . "alias the columns in your SQL, or use ->arrays or ->as",
            $name, scalar @$at, join(', ', @$at),
        );
    }

    return;
}

sub _hash_row {
    my ($self, $row) = @_;

    my $names = $self->{_names};
    my %hash;
    @hash{@$names} = @$row;

    return \%hash;
}

sub rows {
    my ($self) = @_;
    $self->_assert_addressable_by_name;

    return Async::DBD::Pg::Collection->new(
        map { $self->_hash_row($_) } @{ $self->{_rows} }
    );
}

sub arrays {
    my ($self) = @_;
    return Async::DBD::Pg::Collection->new(@{ $self->{_rows} });
}

sub row_array {
    my ($self, $i) = @_;
    return $self->{_rows}[$i];
}

sub first {
    my ($self) = @_;

    my $row = $self->{_rows}[0] or return undef;
    $self->_assert_addressable_by_name;

    return $self->_hash_row($row);
}

sub single {
    my ($self) = @_;

    $self->_warn_if_several('single');

    return $self->first;
}

sub single_value {
    my ($self) = @_;

    $self->_warn_if_several('single_value');

    # Positional, so a duplicate column name cannot stop it.
    my $row = $self->{_rows}[0] or return undef;

    return $row->[0];
}

sub _warn_if_several {
    my ($self, $method) = @_;

    my $n = @{ $self->{_rows} };
    return if $n < 2;

    carp "$method expected one row but $n rows matched";

    return;
}

sub next {
    my ($self) = @_;

    my $row = $self->{_rows}[ $self->{_position} ] or return undef;
    $self->_assert_addressable_by_name;
    $self->{_position}++;

    return $self->_hash_row($row);
}

sub reset {
    my ($self) = @_;
    $self->{_position} = 0;
    return $self;
}

sub all {
    my ($self) = @_;
    $self->_assert_addressable_by_name;

    my @remaining = @{ $self->{_rows} }[ $self->{_position} .. $#{ $self->{_rows} } ];
    $self->{_position} = @{ $self->{_rows} };

    return Async::DBD::Pg::Collection->new(
        map { $self->_hash_row($_) } grep { defined } @remaining
    );
}

# Take a name or an index, and never choose on the caller's behalf.
sub get_column {
    my ($self, $wanted) = @_;

    my $index = $wanted =~ /\A[0-9]+\z/ ? $wanted : $self->_index_of($wanted);

    croak sprintf(
        'Column index %s out of range; result has %d columns',
        $index, scalar @{ $self->{_names} },
    ) if $index > $#{ $self->{_names} };

    return Async::DBD::Pg::Column->new(
        name   => $self->{_names}[$index],
        index  => $index,
        values => [ map { $_->[$index] } @{ $self->{_rows} } ],
    );
}

sub _index_of {
    my ($self, $name) = @_;

    my $at = $self->{_positions}{$name}
        or croak sprintf(
            "No column '%s'; columns are: %s",
            $name, join(', ', @{ $self->{_names} }),
        );

    croak sprintf(
        "Column '%s' appears %d times at positions %s; ask for one by index",
        $name, scalar @$at, join(', ', @$at),
    ) if @$at > 1;

    return $at->[0];
}

1;

__END__

=head1 NAME

Async::DBD::Pg::Results - Query result wrapper

=head1 SYNOPSIS

    my $result = await $conn->query('SELECT id, name FROM users');

    say $result->count, ' rows';

    for my $row (@{ $result->rows }) {
        say $row->{name};
    }

    while (my $row = $result->next) {
        say $row->{name};
    }

    my $total = await $conn->query('SELECT count(*) FROM users');
    say $total->single_value;

=head1 DESCRIPTION

Wraps the outcome of a query. Rows are fetched in full when the object is
built and the statement handle is finished, so a result can be held and read
at leisure without tying up the connection. Use L<Async::DBD::Pg::Cursor> for
result sets too large to sit in memory.

Rows are stored positionally, and the hashrefs L</rows> hands back are
derived from them on demand. That is what lets a result carry a repeated
column name, which a hash cannot: a self-join selecting C<id> twice keeps
both values, reachable through L</arrays> or after renaming with C<as>.

Asking for a hash view of such a result is an error rather than a quiet
collapse. See L</"Repeated column names">.

=head2 Repeated column names

C<SELECT * FROM a JOIN b USING (id)> can return two columns called C<id>. A
Perl hash holds one value per key, so a hashref row can only carry one of
them, and which one it keeps depends on column order.

Rather than lose a value silently, every method that builds a hashref croaks:

    Column 'id' appears 2 times at positions 0, 1;
    alias the columns in your SQL, or use ->arrays or ->as

That is L</rows>, L</first>, L</single>, L</next> and L</all>.

Everything positional keeps working on the same result: L</arrays>,
L</row_array>, L</columns>, L</types>, L</count>, L</rows_affected>,
L</is_empty> and L</single_value>. So does L</get_column> by index.

The fix is usually to alias in SQL:

    SELECT a.id AS a_id, b.id AS b_id FROM a JOIN b ON ...

=head1 METHODS

=head2 rows

    my $rows = $result->rows;

Rows as hashrefs keyed by column name, in an L<Async::DBD::Pg::Collection> --
a blessed arrayref, so C<@{ $result-E<gt>rows }>, C<$result-E<gt>rows-E<gt>[0]>
and C<scalar @{ $result-E<gt>rows }> all work as before.

Derived on each call. Hold the result if you use it more than once.

Croaks if the column names repeat; see L</"Repeated column names">.

=head2 arrays

    my $arrays = $result->arrays;

Rows as arrayrefs, in column order, in a collection. This is the lossless
view: it works whatever the column names are, and it is what to use when the
query's columns are not known ahead of time.

=head2 columns

    my $names = $result->columns;

Arrayref of column names, in the order the query returned them. Duplicates
are reported as they came back, not deduplicated.

=head2 types

    my $types = $result->types;

Arrayref of PostgreSQL type names -- C<int4>, C<text>, C<numeric>, C<jsonb>
-- aligned by position with L</columns>. Anything generic over a result needs
these, and they cannot be recovered once the statement handle is finished.

=head2 count

    my $n = $result->count;

Number of rows returned. This counts rows in hand, so it is 0 for an C<INSERT>
or C<UPDATE> without a C<RETURNING> clause; see L</rows_affected>.

=head2 rows_affected

    my $n = $result->rows_affected;

Number of rows the statement affected, as reported by the driver. This is the
useful count for C<INSERT>, C<UPDATE> and C<DELETE>. A statement that matched
nothing reports 0 and is not an error.

=head2 is_empty

    if ($result->is_empty) { ... }

True when no rows were returned.

=head2 first

    my $row = $result->first;

The first row as a hashref, or C<undef> when there are none. Takes what is
there: several rows is not a complaint. Use L</single> to be told.

Croaks if the column names repeat.

=head2 single

    my $row = $result->single;

The first row, warning if more than one matched. For a query expected to
identify one row, where several usually means the query is wrong.

No match is C<undef> and is not warned about: that is an ordinary outcome to
branch on.

Croaks if the column names repeat.

=head2 single_value

    my $value = $result->single_value;

First column of the first row, for a query selecting one value such as a
C<count(*)>. C<undef> when there are no rows, and warns when more than one
matched, matching L</single>.

Positional, so it never builds a hash and works whatever the column names
are.

=head2 row_array

    my $row = $result->row_array(0);

One row as an arrayref, by index, or C<undef> past the end. Positional, so it
works whatever the column names are.

=head2 next

    while (my $row = $result->next) { ... }

The next row as a hashref, advancing an internal position, or C<undef> once
the rows are exhausted. Reads the same way as
L<Async::DBD::Pg::Cursor/next>, so an eager and a lazy loop look alike.

This makes a result stateful: two pieces of code walking the same object
share one position. Call L</reset> to start again.

Croaks if the column names repeat.

=head2 reset

    $result->reset;

Returns the position used by L</next> to the start, and returns the result so
it can be chained.

=head2 all

    my $rows = $result->all;

The rows from the current position onwards, as a collection of hashrefs, and
leaves the position at the end. On an untouched result this is every row, the
same as L</rows>.

Croaks if the column names repeat.

=head2 get_column

    my $col = $result->get_column('name');
    my $col = $result->get_column(1);

One column, as an L<Async::DBD::Pg::Column>, by name or by index.

Never guesses. Three things are errors rather than an C<undef> to trip over
later:

    No column 'idd'; columns are: id, name, price
    Column 'id' appears 2 times at positions 0, 1; ask for one by index
    Column index 7 out of range; result has 4 columns

A repeated name is resolved by asking for the position instead.

=head1 CONSTRUCTORS

These are called by L<Async::DBD::Pg::Connection> rather than directly.

=head2 new

    my $result = Async::DBD::Pg::Results->new($sth);

Builds a result from an executed DBI statement handle, fetching every row,
keeping the column names and types, and finishing the handle.

=head2 new_from_data

    my $result = Async::DBD::Pg::Results->new_from_data(
        rows          => [ [1, 'Alice'], [2, 'Bob'] ],
        columns       => ['id', 'name'],
        types         => ['int4', 'text'],
        rows_affected => 0,
    );

Builds a result from data already in hand, without a statement handle. Rows
are arrayrefs in column order, matching how a result stores them. Useful in
tests.

=head1 AUTHOR

John Napiorkowski E<lt>jjn1056@yahoo.comE<gt>

=cut

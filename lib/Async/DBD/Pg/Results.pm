package Async::DBD::Pg::Results;

use strict;
use warnings;

# Constructor from DBI statement handle (eager fetch)
sub new {
    my ($class, $sth) = @_;

    my $rows = $sth->fetchall_arrayref({}) // [];
    my $columns = $sth->{NAME} ? [ @{$sth->{NAME}} ] : [];
    my $rows_affected = $sth->rows;
    $sth->finish;

    return bless {
        rows          => $rows,
        columns       => $columns,
        count         => scalar @$rows,
        rows_affected => $rows_affected,
    }, $class;
}

# Constructor from data (for testing without DBI)
sub new_from_data {
    my ($class, %args) = @_;

    my $rows = $args{rows} // [];
    my $columns = $args{columns} // [];

    return bless {
        rows          => $rows,
        columns       => $columns,
        count         => scalar @$rows,
        rows_affected => $args{rows_affected} // 0,
    }, $class;
}

sub rows          { shift->{rows} }
sub columns       { shift->{columns} }
sub count         { shift->{count} }
sub rows_affected { shift->{rows_affected} }

sub first {
    my $self = shift;
    return $self->{rows}[0];
}

sub scalar {
    my $self = shift;
    my $first = $self->first;
    return undef unless $first;

    my $col = $self->{columns}[0];
    return $first->{$col} if defined $col;

    my @values = values %$first;
    return $values[0];
}

sub is_empty {
    my $self = shift;
    return $self->{count} == 0;
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

    my $one = await $conn->query('SELECT name FROM users WHERE id = $1', 1);
    say $one->scalar;

=head1 DESCRIPTION

Wraps the outcome of a query. Rows are fetched in full when the object is
built and the statement handle is finished, so a result can be held and read
at leisure without tying up the connection. Use L<Async::DBD::Pg::Cursor> for
result sets too large to sit in memory.

Rows are hashrefs keyed by column name.

=head1 METHODS

=head2 rows

    my $rows = $result->rows;

Arrayref of rows, each a hashref keyed by column name. Empty for statements
that return no rows.

=head2 columns

    my $names = $result->columns;

Arrayref of column names, in the order the query returned them.

=head2 count

    my $n = $result->count;

Number of rows returned. This counts rows in hand, so it is 0 for an C<INSERT>
or C<UPDATE>, which return none; see L</rows_affected>.

=head2 rows_affected

    my $n = $result->rows_affected;

Number of rows the statement affected, as reported by the driver. This is the
useful count for C<INSERT>, C<UPDATE> and C<DELETE>. A statement that matched
nothing reports 0 and is not an error.

=head2 first

    my $row = $result->first;

The first row, or C<undef> when there are none. Convenient for queries
expected to match at most one row.

=head2 scalar

    my $value = $result->scalar;

Value of the first column of the first row, for queries selecting a single
value such as a C<COUNT>. Returns C<undef> when there are no rows.

=head2 is_empty

    if ($result->is_empty) { ... }

True when no rows were returned.

=head1 CONSTRUCTORS

These are called by L<Async::DBD::Pg::Connection> rather than directly.

=head2 new

    my $result = Async::DBD::Pg::Results->new($sth);

Builds a result from an executed DBI statement handle, fetching every row and
finishing the handle.

=head2 new_from_data

    my $result = Async::DBD::Pg::Results->new_from_data(
        rows          => \@rows,
        columns       => \@names,
        rows_affected => 0,
    );

Builds a result from data already in hand, without a statement handle. Useful
in tests.

=head1 AUTHOR

John Napiorkowski E<lt>jjn1056@yahoo.comE<gt>

=cut

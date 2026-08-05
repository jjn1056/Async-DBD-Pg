package Async::DBD::Pg::Column;

use strict;
use warnings;

use Async::DBD::Pg::Collection;

sub new {
    my ($class, %args) = @_;

    return bless {
        name      => $args{name},
        index     => $args{index},
        values    => $args{values} // [],
        _position => 0,
    }, $class;
}

sub name  { $_[0]{name} }
sub index { $_[0]{index} }

sub all { Async::DBD::Pg::Collection->new(@{ $_[0]{values} }) }

sub first { $_[0]{values}[0] }

sub next {
    my ($self) = @_;

    return undef if $self->{_position} > $#{ $self->{values} };

    return $self->{values}[ $self->{_position}++ ];
}

sub reset {
    my ($self) = @_;
    $self->{_position} = 0;
    return $self;
}

1;

__END__

=head1 NAME

Async::DBD::Pg::Column - One column of a result

=head1 SYNOPSIS

    my $names = $result->get_column('name');

    say $names->first;
    say join ', ', @{ $names->all };

    while (defined(my $name = $names->next)) {
        say $name;
    }

=head1 DESCRIPTION

A single column's values, in row order, produced by
L<Async::DBD::Pg::Results/get_column>. Useful for the common case of wanting
one column out of a result without writing a C<map> over the rows, and for
reaching a column whose name is repeated, which is addressable only by
position.

=head1 METHODS

=head2 name

    my $name = $column->name;

The column's name. On a column obtained by index from a result whose names
repeat, this is the shared name.

=head2 index

    my $i = $column->index;

The column's position in the result, counting from zero.

=head2 all

    my $values = $column->all;

Every value, in row order, as an L<Async::DBD::Pg::Collection>. SQL NULLs
arrive as C<undef>; C<< $column->all->compact >> drops them.

=head2 first

    my $value = $column->first;

The first value, or C<undef> when the result has no rows.

There is no strict counterpart to this, unlike
L<Async::DBD::Pg::Results/single>. Having narrowed to a column, several
values is what one expects rather than a sign the query is wrong.

=head2 next

    while (defined(my $value = $column->next)) { ... }

The next value, advancing an internal position, or C<undef> once they are
exhausted.

A column holding SQL NULLs returns C<undef> for them too, so a C<while (my
$v = ...)> loop stops early on a NULL, an empty string or a zero. Test with
C<defined>, or use L</all> instead.

=head2 reset

    $column->reset;

Returns the position used by L</next> to the start, and returns the column so
it can be chained.

=head1 AUTHOR

John Napiorkowski E<lt>jjn1056@yahoo.comE<gt>

=cut

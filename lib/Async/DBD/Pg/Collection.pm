package Async::DBD::Pg::Collection;

use strict;
use warnings;

# A blessed arrayref rather than an object wrapping one, so that every caller
# treating a result's rows as a plain arrayref -- @{ $r->rows }, $r->rows->[0],
# scalar @{ $r->rows } -- keeps working unchanged.
sub new {
    my $class = shift;
    return bless [@_], $class;
}

sub size  { scalar @{ $_[0] } }
sub first { $_[0][0] }
sub last  { $_[0][-1] }

# Arguments trail the element, matching Async::DBD::Pg::Cursor's each, so a
# callback can be handed what it needs instead of closing over it.
sub each {
    my ($self, $callback, @args) = @_;

    $callback->($_, @args) for @$self;

    return scalar @$self;
}

# Only undef is dropped. An empty string is a value a column can hold, so
# removing it would be the silent data loss this library exists to avoid.
sub compact {
    my ($self) = @_;
    return ref($self)->new(grep { defined } @$self);
}

sub join {
    my ($self, $sep) = @_;
    $sep //= '';
    return CORE::join($sep, @$self);
}

# A copy, so a caller cannot reach through it and change the collection.
sub to_array { [ @{ $_[0] } ] }

1;

__END__

=head1 NAME

Async::DBD::Pg::Collection - A list of rows or values

=head1 SYNOPSIS

    my $rows = $result->rows;

    say $rows->size, ' rows';
    say $rows->first->{name};

    # It is a blessed arrayref, so the ordinary forms work too
    for my $row (@$rows) { say $row->{name} }
    my $second = $rows->[1];

    say join ', ', map { $_->{name} } @$rows;

=head1 DESCRIPTION

Returned by L<Async::DBD::Pg::Results> wherever a list of rows or values is
handed back. It is a blessed arrayref, so anything that works on an arrayref
works here: dereferencing, indexing, C<map>, C<grep>, C<sort>, C<scalar>.

The methods below are the ones that read better than their builtin
equivalents. There is deliberately no C<map>, C<grep>, C<sort> or C<reduce>:
the chained form is longer than the builtin it would replace, and it would
invent a callback convention matching neither Perl's nor anyone else's.

    # this, which already works
    join '/', sort map { $_->{name} } grep { $_->{dept} eq 'eng' } @$rows;

    # rather than this, which does not exist
    $rows->grep(sub {...})->map(sub {...})->sort->join('/');

=head1 METHODS

=head2 size

    my $n = $collection->size;

Number of elements. C<scalar @$collection> is the same thing.

=head2 first

    my $item = $collection->first;

First element, or C<undef> when there are none.

=head2 last

    my $item = $collection->last;

Last element, or C<undef> when there are none.

=head2 each

    my $n = $collection->each(sub { my ($item) = @_; ... });
    my $n = $collection->each(\&handler, $context);

Calls the callback once per element, in order, and returns the number of
elements. Any further arguments are passed after the element, so a callback
can be given what it needs rather than closing over it. This matches
L<Async::DBD::Pg::Cursor/each>.

=head2 compact

    my $present = $collection->compact;

A new collection with the C<undef> elements removed, which is what a column
of values holding SQL NULLs comes back as.

Only C<undef> is removed. An empty string and a zero are values a column can
hold and are kept.

=head2 join

    my $csv = $collection->join(', ');
    my $run = $collection->join;

Joins the elements into a string. The separator defaults to the empty string.

=head2 to_array

    my $plain = $collection->to_array;

A plain unblessed arrayref holding the same elements. A copy, so changing it
does not change the collection. Rarely needed, since a collection already is
an arrayref; useful when handing data to something that checks C<ref> for
exactly C<ARRAY>.

=head1 AUTHOR

John Napiorkowski E<lt>jjn1056@yahoo.comE<gt>

=cut

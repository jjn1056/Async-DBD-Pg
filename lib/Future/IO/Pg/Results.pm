package Future::IO::Pg::Results;

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

Future::IO::Pg::Results - Query result wrapper

=head1 AUTHOR

John Napiorkowski E<lt>jjn1056@yahoo.comE<gt>

=cut

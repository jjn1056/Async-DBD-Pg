package Async::DBD::Pg::Cursor;

use strict;
use warnings;

use Future::AsyncAwait;
use Async::DBD::Pg::Collection;
use Async::DBD::Pg::Results;

my $cursor_counter = 0;

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        name              => _validate_name($args{name} // _generate_name()),
        batch_size        => _validate_batch_size($args{batch_size} // 1000),
        conn              => $args{conn},
        _owns_transaction => $args{_owns_transaction} // 0,
        exhausted         => 0,
        closed            => 0,
        buffer            => [],
    }, $class;

    return $self;
}

sub _generate_name {
    return "cursor_" . ++$cursor_counter;
}

# PostgreSQL will not accept a bind parameter for a cursor name or a fetch
# count, so both are written into the statement text and must be checked
# first. Anything outside a plain identifier or a positive integer is
# rejected rather than quoted, since neither has a legitimate reason to
# contain anything else.

# Longest identifier PostgreSQL keeps before truncating (NAMEDATALEN - 1).
my $MAX_IDENTIFIER_LENGTH = 63;

sub _validate_name {
    my ($name) = @_;

    die "Cursor name must be defined\n"
        unless defined $name;

    die "Invalid cursor name '$name': expected a letter or underscore "
      . "followed by letters, digits or underscores\n"
        unless $name =~ /\A[A-Za-z_][A-Za-z0-9_]*\z/;

    die "Invalid cursor name '$name': longer than $MAX_IDENTIFIER_LENGTH characters\n"
        if length($name) > $MAX_IDENTIFIER_LENGTH;

    return $name;
}

sub _validate_batch_size {
    my ($size) = @_;

    die "Cursor batch_size must be defined\n"
        unless defined $size;

    die "Invalid cursor batch_size '$size': expected a positive integer\n"
        unless $size =~ /\A[1-9][0-9]*\z/;

    return $size;
}

# Accessors
sub name        { shift->{name} }
sub batch_size  { shift->{batch_size} }
sub is_exhausted { shift->{exhausted} }
sub is_closed   { shift->{closed} }

# One row at a time, so a cursor loop reads the way an eager one does:
#
#     while (my $row = $rs->next)        { ... }
#     while (my $row = await $cur->next) { ... }
#
# batch_size stays what it always was underneath -- how many rows come back
# per round trip -- but it is now a transport detail rather than the shape
# the caller has to iterate.
async sub next {
    my ($self) = @_;

    if (!@{ $self->{buffer} }) {
        return undef if $self->{exhausted} || $self->{closed};
        await $self->_fetch_batch;
    }

    return shift @{ $self->{buffer} };
}

async sub _fetch_batch {
    my ($self) = @_;

    my $batch_size = $self->{batch_size};

    my $result = await $self->{conn}->query("FETCH $batch_size FROM $self->{name}");
    my $rows = $result->rows;

    # Close before buffering, not after: close empties the buffer so that a
    # caller who closes part-way through stops getting rows, and the final
    # short batch would be thrown away if it were already sitting there.
    if (@$rows < $batch_size) {
        $self->{exhausted} = 1;
        await $self->close;
    }

    push @{ $self->{buffer} }, @$rows;

    return;
}

# Iterate over all rows, calling callback for each
async sub each {
    my ($self, $callback, @args) = @_;

    my $count = 0;
    while (defined(my $row = await $self->next)) {
        $callback->($row, @args);
        $count++;
    }

    return $count;
}

# Collect all remaining rows. A Collection, matching Results::all: both mean
# "the rows from here on", and a caller switching a query between the eager
# and the lazy form should not have to switch what it does with them.
async sub all {
    my ($self) = @_;

    my @all_rows;
    while (defined(my $row = await $self->next)) {
        push @all_rows, $row;
    }

    return Async::DBD::Pg::Collection->new(@all_rows);
}

# Close the cursor
async sub close {
    my ($self) = @_;

    return if $self->{closed};
    $self->{closed} = 1;

    # A caller who closes part-way through has said they are done, so rows
    # already fetched but not yet handed over go no further. _fetch_batch
    # buffers after calling this, so the final short batch is unaffected.
    @{ $self->{buffer} } = ();

    if (my $conn = $self->{conn}) {
        eval { await $conn->query("CLOSE " . $self->{name}) };

        # If we started a transaction for this cursor, commit it
        if ($self->{_owns_transaction}) {
            eval { await $conn->query('COMMIT') };
            $conn->{in_transaction} = 0;
        }
    }
}

sub DESTROY {
    my ($self) = @_;

    # During global destruction, don't try to close
    return if ${^GLOBAL_PHASE} eq 'DESTRUCT';

    return if $self->{closed};

    # Closing needs to await, which DESTROY cannot do, so the cursor is left
    # for the connection to clean up. It was declared without WITH HOLD, so
    # the server drops it when the surrounding transaction ends, and the pool
    # ends that transaction when the connection is released. Say so, because
    # until then the cursor holds server resources and the transaction holds
    # its locks.
    warn "Cursor '$self->{name}' was discarded without close(); "
       . "it stays open until its connection is released\n";
}

1;

__END__

=head1 NAME

Async::DBD::Pg::Cursor - Streaming cursor for large result sets

=head1 SYNOPSIS

    my $cursor = await $conn->cursor(
        'SELECT * FROM large_table WHERE status = $1',
        'active',
        { batch_size => 100 }
    );

    # Iterate over batches
    while (my $batch = await $cursor->next) {
        for my $row (@$batch) {
            process($row);
        }
    }

    # Or use each() for row-by-row processing
    await $cursor->each(sub {
        my ($row) = @_;
        process($row);
    });

    # Draining a cursor closes it automatically; close it yourself only if
    # you stop before reaching the end.
    await $cursor->close;

=head1 METHODS

=head2 next

    while (my $row = await $cursor->next) {
        say $row->{name};
    }

The next row as a hashref, or C<undef> once the cursor is exhausted. This
reads the same as walking an eager result with
L<Async::DBD::Pg::Results/next>, so switching a query between the two does
not change the shape of the loop.

Rows are fetched C<batch_size> at a time and handed out one by one, so most
calls cost nothing and only every C<batch_size>th is a round trip.
C<batch_size> tunes that traffic; it does not change what this returns. The
fetch that empties the cursor closes it, the same as calling L</close>
explicitly.

There is no C<reset>. A server-side cursor is consumed as it is read, and
re-running the query is a different guarantee rather than a rewind, so it is
not offered under a name that would suggest otherwise.

A row that is false in boolean context is not possible here, since every row
is a hashref, so C<while (my $row = ...)> is safe. That is not true of
L<Async::DBD::Pg::Column/next>, which yields values.

=head2 each

    await $cursor->each(sub {
        my ($row) = @_;
        ...
    });

    await $cursor->each($callback, @args);

Walks every remaining row, calling the callback once per row, fetching a batch
at a time. This keeps only one batch in memory however large the result is.
Returns the number of rows visited. A callback that runs to completion drains
the cursor and, by way of L</next>, closes it.

Any arguments after the callback are forwarded to it as
C<< $callback->($row, @args) >>, letting a caller pass values in rather than
close over them.

=head2 all

    my $rows = await $cursor->all;

Collects every remaining row into an L<Async::DBD::Pg::Collection>, the same
as L<Async::DBD::Pg::Results/all> returns, so a query can move between the
eager and the lazy form without its caller changing. A collection is a
blessed arrayref, so C<@$rows> and C<< $rows->[0] >> work as before.

This defeats the point of a cursor on a large result, since the whole set
ends up in memory; prefer L</each> or L</next> unless the result is known to
be small. Draining the cursor this way closes it too.

=head2 close

    await $cursor->close;

Closes the cursor on the server and commits the transaction if the cursor
started one. Calling it again is harmless.

A cursor that is read to exhaustion through L</next> or L</each> closes
itself; there is nothing to do after that. A cursor abandoned before then
still needs an explicit close: one left to be garbage collected cannot close
itself, because closing has to await and destruction cannot. It warns
instead, and stays open, holding its transaction, until its connection is
released.

=head1 ACCESSORS

=head2 name

The cursor's name on the server.

=head2 batch_size

Rows fetched per round trip.

=head2 is_exhausted

True once a fetch has returned fewer rows than C<batch_size>, meaning there
are no more.

=head2 is_closed

True once the cursor has been closed.

=head1 AUTHOR

John Napiorkowski E<lt>jjn1056@yahoo.comE<gt>

=cut

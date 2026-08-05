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

    # Not a constructor argument: the duration covers the timeout race around
    # the execute, which happens a layer above whoever builds this. The
    # connection stamps it with _record_elapsed once it knows.
    return $class->_build($rows, $names, $types, $rows_affected, undef);
}

# Called by Async::DBD::Pg::Connection once the query it timed has finished.
sub _record_elapsed {
    my ($self, $seconds) = @_;

    $self->{_elapsed} = $seconds;

    return $self;
}

# Build a result from data already in hand, without a statement handle.
sub new_from_data {
    my ($class, %args) = @_;

    return $class->_build(
        $args{rows}    // [],
        $args{columns} // [],
        $args{types}   // [],
        $args{rows_affected} // 0,
        $args{elapsed},
    );
}

sub _build {
    my ($class, $rows, $names, $types, $rows_affected, $elapsed) = @_;

    return bless {
        _rows          => $rows,
        _names         => $names,
        _types         => $types,
        _rows_affected => $rows_affected,
        _elapsed       => $elapsed,
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
sub elapsed       { $_[0]{_elapsed} }
sub is_empty      { !@{ $_[0]{_rows} } }

# The first repeated column name and where it appears, or nothing. Callers
# that build their own message -- Connection::query_row points one tier down
# rather than at ->arrays -- ask for this instead of catching a croak.
sub _repeated_column {
    my ($self) = @_;

    for my $name (@{ $self->{_names} }) {
        my $at = $self->{_positions}{$name};
        return ($name, $at) if @$at > 1;
    }

    return;
}

# Croak before building any hash from a result whose names repeat. Returning
# a hash with the duplicates collapsed is a wrong answer that reports success,
# which is the failure this class is shaped to prevent.
sub _assert_addressable_by_name {
    my ($self) = @_;

    my ($name, $at) = $self->_repeated_column or return;

    croak sprintf(
        "Column '%s' appears %d times at positions %s; "
      . "alias the columns in your SQL, or use ->arrays or ->as",
        $name, scalar @$at, join(', ', @$at),
    );
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

# Addressable by name and lossless, so this is the one name-keyed view a
# result with repeated column names supports without renaming. It has nothing
# to refuse and so is exempt from the croak the other hash views make.
#
# Built on every call and never cached: a Hash::MultiValue per row is real
# work, and hiding that behind a cache would only move the cost somewhere
# harder to see.
sub multi {
    my ($self) = @_;

    eval { require Hash::MultiValue; 1 }
        or croak 'multi needs Hash::MultiValue, which is not installed. '
               . 'Install it, or use ->arrays for a lossless view with no dependency';

    my $names = $self->{_names};

    return Async::DBD::Pg::Collection->new(
        map {
            my $row = $_;
            Hash::MultiValue->new(
                map { ( $names->[$_] => $row->[$_] ) } 0 .. $#$names
            );
        } @{ $self->{_rows} }
    );
}

sub row_array {
    my ($self, $i) = @_;
    return $self->{_rows}[$i];
}

sub first {
    my ($self) = @_;

    # Before looking at the rows, not after: a query whose column names
    # collide is wrong however many rows it happened to match, and the
    # zero-row day is exactly when that would ship unnoticed.
    $self->_assert_addressable_by_name;

    my $row = $self->{_rows}[0] or return undef;

    return $self->_hash_row($row);
}

sub single {
    my ($self) = @_;

    $self->_warn_if_several('single');

    return $self->first;
}

# Positional, so a duplicate column name cannot stop either of these.
sub first_value {
    my ($self) = @_;

    my $row = $self->{_rows}[0] or return undef;

    return $row->[0];
}

sub single_value {
    my ($self) = @_;

    $self->_warn_if_several('single_value');

    return $self->first_value;
}

# The whole row as a list, for the "my ($id, $name) = ..." idiom. Scalar
# context gives the arrayref rather than a count: a count is a
# plausible-looking wrong number, which is the failure this library is
# built to refuse.
sub first_list {
    my ($self) = @_;

    my $row = $self->{_rows}[0]
        or return wantarray ? () : undef;

    return wantarray ? @$row : [@$row];
}

sub single_list {
    my ($self) = @_;

    $self->_warn_if_several('single_list');

    # return propagates the caller's context, so this stays a list for a
    # list-context caller and an arrayref for a scalar-context one.
    return $self->first_list;
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

    $self->_assert_addressable_by_name;

    my $row = $self->{_rows}[ $self->{_position} ] or return undef;
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

# Lookup keyed by a column's value. The hand-rolled map version of this keeps
# the last row when key values repeat, which is the same silent loss as a
# collapsed column, so it is refused the same way and points at groups.
sub by {
    my ($self, $column) = @_;

    # Before _index_of, so a repeated column name is reported as something
    # ->as can fix rather than with get_column's "ask for one by index",
    # which is advice by cannot take: it keys on a name.
    $self->_assert_addressable_by_name;
    my $index = $self->_index_of($column);

    my %seen;
    for my $row (@{ $self->{_rows} }) {
        $seen{ $self->_key_of($row, $index, $column) }++;
    }

    for my $row (@{ $self->{_rows} }) {
        my $value = $row->[$index];
        next if $seen{$value} == 1;

        croak sprintf(
            "Value '%s' in column '%s' appears %d times; use ->groups",
            $value, $column, $seen{$value},
        );
    }

    return { map { ( $_->[$index] => $self->_hash_row($_) ) } @{ $self->{_rows} } };
}

# A hash key is a string, so a NULL would become the empty string and merge
# with a row that genuinely holds one. Refuse instead of choosing for them.
sub _key_of {
    my ($self, $row, $index, $column) = @_;

    my $value = $row->[$index];

    croak "Column '$column' holds NULL, which cannot key a lookup; "
        . 'filter the NULLs out in your SQL, or key on a NOT NULL column'
        unless defined $value;

    return $value;
}

# The lossless half of the pair: every row survives, gathered under its key.
sub groups {
    my ($self, $column) = @_;

    $self->_assert_addressable_by_name;
    my $index = $self->_index_of($column);

    my %grouped;
    for my $row (@{ $self->{_rows} }) {
        push @{ $grouped{ $self->_key_of($row, $index, $column) } },
            $self->_hash_row($row);
    }

    return {
        map { ( $_ => Async::DBD::Pg::Collection->new(@{ $grouped{$_} }) ) }
        keys %grouped
    };
}

# A view: a fresh result over the same rows, with the names swapped. The rows
# arrayref is shared rather than copied, and the view carries its own
# position, so iterating one does not move the other and calling this on a
# half-read result is well defined.
sub as {
    my ($self, $spec) = @_;

    my $names = ref $spec eq 'HASH'  ? $self->_renamed_by_index($spec)
              : ref $spec eq 'ARRAY' ? $self->_renamed_from_list($spec)
              : croak 'as expects an arrayref of names or a hashref of index => name';

    # Refuse here rather than at the next ->rows: a rename that still
    # collides has not solved the problem it was called to solve, and
    # reporting it later would point at the wrong line.
    my $positions = _index_names($names);
    for my $name (@$names) {
        my $at = $positions->{$name};
        next if @$at == 1;

        croak sprintf(
            "Renaming leaves '%s' at positions %s; every column needs a distinct name",
            $name, join(', ', @$at),
        );
    }

    return ref($self)->_build(
        $self->{_rows}, $names, $self->{_types}, $self->{_rows_affected}, $self->{_elapsed},
    );
}

# Decode the json and jsonb columns, chosen by the stored pg_type rather than
# by sniffing values -- which is the direct payoff of keeping the types. A
# view like as: a fresh result over new rows, leaving the original untouched.
#
# Decoding happens here rather than per row on access, so the cost is paid
# once and is visible at the call site instead of scattered through a loop.
sub expand {
    my ($self) = @_;

    my $types = $self->{_types};
    my @json = grep { ($types->[$_] // '') =~ /\A jsonb? \z/x } 0 .. $#$types;

    return ref($self)->_build(
        [ @{ $self->{_rows} } ], $self->{_names}, $types, $self->{_rows_affected}, $self->{_elapsed},
    ) unless @json;

    my $decoder = _json_decoder();

    my @rows;
    for my $i (0 .. $#{ $self->{_rows} }) {
        my @row = @{ $self->{_rows}[$i] };

        for my $col (@json) {
            next unless defined $row[$col];

            $row[$col] = eval { $decoder->decode($row[$col]) };
            croak sprintf(
                "Could not decode column '%s' of row %d as %s: %s",
                $self->{_names}[$col], $i, $types->[$col], $@,
            ) if $@;
        }

        push @rows, \@row;
    }

    return ref($self)->_build(
        \@rows, $self->{_names}, $types, $self->{_rows_affected}, $self->{_elapsed},
    );
}

sub _json_decoder {
    eval { require JSON::MaybeXS; 1 }
        or croak 'expand needs JSON::MaybeXS, which is not installed. '
               . 'Install it, or decode the column yourself';

    return JSON::MaybeXS->new(utf8 => 0);
}

sub _renamed_from_list {
    my ($self, $list) = @_;

    my $wanted = @{ $self->{_names} };

    croak sprintf(
        'as expects %d names for %d columns, got %d',
        $wanted, $wanted, scalar @$list,
    ) if @$list != $wanted;

    return [@$list];
}

sub _renamed_by_index {
    my ($self, $map) = @_;

    my @names = @{ $self->{_names} };

    for my $index (sort { $a <=> $b } keys %$map) {
        croak sprintf(
            'Column index %s out of range; result has %d columns',
            $index, scalar @names,
        ) if $index !~ /\A[0-9]+\z/ || $index > $#names;

        $names[$index] = $map->{$index};
    }

    return \@names;
}

# Shape and a sample, never a flood. Bounded in both directions by design:
# this is what gets printed into a log, a REPL, or an agent's context, and
# any of those is worse off with the whole result set in it.
sub preview {
    my ($self, $limit) = @_;
    $limit = 5 unless defined $limit;

    my $names = $self->{_names};
    my $total = @{ $self->{_rows} };

    return "no columns; rows_affected: $self->{_rows_affected}" unless @$names;

    my @header = map {
        my $type = $self->{_types}[$_];
        defined $type ? "$names->[$_] $type" : $names->[$_];
    } 0 .. $#$names;

    my $summary = sprintf '%d row%s; %d column%s: %s',
        $total, ($total == 1 ? '' : 's'),
        scalar @$names, (@$names == 1 ? '' : 's'),
        join(', ', @header);

    return $summary unless $total;

    # Positional, so this works on the result that most needs inspecting:
    # the one whose column names collide and whose hash views refuse.
    my @shown = map { [ map { _cell($_) } @$_ ] }
                @{ $self->{_rows} }[ 0 .. ($total < $limit ? $total : $limit) - 1 ];

    my @width = map {
        my $col = $_;
        my $w = length $names->[$col];
        for my $row (@shown) {
            $w = length $row->[$col] if length $row->[$col] > $w;
        }
        $w;
    } 0 .. $#$names;

    # Padding the final column would leave trailing spaces on every line,
    # which is noise in a log and a diff.
    my $line = sub {
        my ($cells) = @_;
        my $out = join ' | ',
            map { sprintf '%-*s', $width[$_], $cells->[$_] } 0 .. $#$names;
        $out =~ s/\s+\z//;
        return $out;
    };

    my @lines = ($summary, $line->($names));
    push @lines, $line->($_) for @shown;

    push @lines, sprintf '... %d more', $total - @shown if $total > @shown;

    return join "\n", @lines;
}

# NULL has to be distinguishable from an empty string here, and a single wide
# value must not blow the line out.
sub _cell {
    my ($value) = @_;

    return 'NULL' unless defined $value;
    return "\x7b...\x7d" if ref $value;

    $value =~ s/\s+/ /g;

    return length $value > 30 ? substr($value, 0, 27) . '...' : $value;
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

C<SELECT * FROM a JOIN b ON a.id = b.id> returns two columns called C<id>
and, if both tables have one, two called C<name>. A Perl hash holds one value
per key, so a hashref row can only carry one of each, and which one it keeps
depends on column order.

(C<JOIN ... USING (id)> merges the join column, so that form yields one
C<id> -- but any other name the two tables share still comes back twice.)

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

The arrayrefs are the result's own, not copies, which is what makes this the
cheap view. Writing through one changes the result itself, and so changes
what L</rows>, L</row_array> and every view built with L</as> report:

    $result->arrays->[0][1] = 'x';   # $result->rows->[0]{name} is now 'x'

Copy first if you mean to modify -- C<< [ @$row ] >> per row, or
L<Async::DBD::Pg::Collection/to_array> for the outer list. The same applies
to L</row_array>.

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

=head2 elapsed

    say sprintf '%.3fs', $result->elapsed;

How long the query took, in fractional seconds, measured on a monotonic
clock so a clock adjustment mid-query cannot distort it. Present on every
result, including statements that return no rows.

Captured because it cannot be recovered afterwards. For a hook that sees
this for every query rather than one at a time, see
L<Async::DBD::Pg/on_query>.

A view reports the same figure as the result it came from, being the same
query.

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

=head2 first_value

    my $value = $result->first_value;

First column of the first row, or C<undef> when there are none. Takes what
is there without complaint, exactly as L</first> does for rows.

Positional, so it never builds a hash and works whatever the column names
are.

=head2 single_value

    my $value = $result->single_value;

First column of the first row, for a query selecting one value such as a
C<count(*)>. C<undef> when there are no rows, and warns when more than one
matched, matching L</single>.

Positional, so it never builds a hash and works whatever the column names
are.

=head2 first_list

    my ($id, $name) = $result->first_list;

The first row as a list of values, in column order. An empty list when there
are no rows. Takes what is there without complaint; see L</single_list> to
be told when more than one matched.

In scalar context it returns an arrayref, not a count. A count is a
plausible-looking wrong number, which is the failure mode this library is
built to refuse:

    my $values = $result->first_list;   # [1, 'Alice']

Positional, so it never builds a hash and works whatever the column names
are.

=head2 single_list

    my ($id, $name) = $result->single_list;

As L</first_list>, but warns when more than one row matched. The first row is
still returned.

=head2 row_array

    my $row = $result->row_array(0);

One row as an arrayref, by index, or C<undef> past the end. Positional, so it
works whatever the column names are.

As with L</arrays>, this is the result's own arrayref rather than a copy;
writing through it changes the result.

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

An argument made only of digits is read as an index, so a column deliberately
aliased to a number -- C<SELECT x AS "2"> -- cannot be reached by its name
here. Find its position in L</columns> and ask for that, or read it from
L</rows>, where the key is an ordinary string.

=head2 multi

    my $rows = $result->multi;
    my @ids  = $rows->first->get_all('id');

Rows as L<Hash::MultiValue> objects, in a collection. Addressable by name
B<and> lossless, so this is the one name-keyed view that works on a result
whose column names repeat, and the only one exempt from the croak.

Scalar access keeps the last value of a repeated name, the same as assigning
a repeated key into a plain hash would; C<get_all> returns every one.

L<Hash::MultiValue> is an optional dependency, loaded when this is called.

Built on every call and never cached: an object per row is real work. Hold
the result if you loop over it, and prefer L</arrays> for large result sets.

=head2 expand

    my $rows = $result->expand->rows;
    say $rows->[0]{payload}{user}{name};

A view with the C<json> and C<jsonb> columns decoded into Perl structures.
Which columns those are comes from L</types>, never from looking at the
values, so a C<text> column that happens to contain JSON is left alone.

Decoding happens once, when this is called, rather than per access. The
original result is not modified. A column that cannot be decoded is an error
naming the column and the row: PostgreSQL cannot return malformed C<jsonb>,
so it means something is badly wrong.

L<JSON::MaybeXS> is an optional dependency, loaded when this is called.

Composes with the other views:

    $result->as({ 1 => 'body' })->expand->by('id');

=head2 as

    my $view = $result->as(['seller_id', 'buyer_id', 'name']);
    my $view = $result->as({ 0 => 'seller_id', 1 => 'buyer_id' });

A view of the same rows under different column names. This is the fix for a
result whose names repeat: rename them and every hash view works again.

The arrayref form names every column and must be exactly as long as
L</columns>. The hashref form renames by index and leaves the rest alone.
Renaming is always by position, never by current name, because the case that
needs renaming is exactly the one where a name does not identify a column.

The view shares the rows rather than copying them, and carries its own
position, so iterating the view does not move the original's L</next> and
calling this on a half-read result is well defined. C<types> stay aligned by
position. The original still reports its raw names.

Three things are refused, all at the point of renaming rather than at the
next use: a list of the wrong length, an index that names no column, and a
rename that still leaves two columns sharing a name.

=head2 by

    my $users = $result->by('id');
    say $users->{42}{name};

A plain hashref of column value to row, for the lookups that otherwise get
written as a C<map>.

Refuses to lose a row. If the key column repeats a value, that C<map> would
silently keep the last one, so this croaks and points at L</groups> instead.
A NULL in the key column is refused for the same reason: as a hash key it
would become the empty string and merge with a row that holds one.

Croaks on a column name that is not present, listing the ones that are, and
on a result whose column names repeat.

=head2 groups

    my $teams = $result->groups('dept');
    say $teams->{eng}->size;

The lossless counterpart to L</by>: a hashref of column value to a
collection of every row with that value.

Croaks on a missing column and on a NULL key, as L</by> does.

=head2 preview

    say $result->preview;
    say $result->preview(20);

A short string describing the result: the column names with their types, the
row count, and the first few rows as an aligned table. Five rows by default.

    3 rows; 4 columns: id int4, name text, dept text, note text
    id | name  | dept  | note
    1  | Alice | eng   | NULL
    2  | Bob   | sales | a much longer note than fit...
    ... 1 more

Bounded in both directions on purpose: rows are capped and wide values are
truncated, because this is what goes into a log, a REPL, or an agent's
context, and none of those is better off holding the whole result set.

Positional, so it works on a result whose column names repeat -- which is
the one that most needs looking at. On a view it shows the view's names. A
statement returning no rows still describes its shape, and one with no
columns reports its C<rows_affected>.

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

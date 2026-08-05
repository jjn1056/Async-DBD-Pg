package Async::DBD::Pg::Error;

use strict;
use warnings;

use overload
    '""'   => sub { shift->message },
    'bool' => sub { 1 },
    fallback => 1;

sub new {
    my ($class, %args) = @_;
    return bless \%args, $class;
}

sub message { shift->{message} }

# Answerable on every error so a caller never has to guard the call. Only a
# query error can be retryable, and only for the two states below.
sub is_retryable { 0 }

sub throw {
    my $self = shift;
    die ref $self ? $self : $self->new(@_);
}

# SQLSTATE code to human-readable state name mapping
my %STATE_MAP = (
    '23505' => 'unique_violation',
    '23503' => 'foreign_key_violation',
    '23502' => 'not_null_violation',
    '23514' => 'check_violation',
    '23P01' => 'exclusion_violation',
    '42601' => 'syntax_error',
    '42501' => 'insufficient_privilege',
    '42P01' => 'undefined_table',
    '42703' => 'undefined_column',
    '42883' => 'undefined_function',
    '40001' => 'serialization_failure',
    '40P01' => 'deadlock_detected',
    '57014' => 'query_canceled',
    '08000' => 'connection_exception',
    '08003' => 'connection_does_not_exist',
    '08006' => 'connection_failure',
);


package Async::DBD::Pg::Error::Query;

use parent -norequire, 'Async::DBD::Pg::Error';

sub new {
    my ($class, %args) = @_;
    my $self = $class->SUPER::new(%args);
    return $self;
}

sub constraint { shift->{constraint} }
sub detail     { shift->{detail} }
sub hint       { shift->{hint} }
sub position   { shift->{position} }
sub severity   { shift->{severity} }
sub schema     { shift->{schema} }
sub table      { shift->{table} }
sub column     { shift->{column} }
sub context    { shift->{context} }

# The five-character SQLSTATE. This is what DBI's own state() returns, what
# PostgreSQL's documentation is indexed by, and what callers compare against.
sub state { $_[0]->{code} }

# The readable name for the codes worth naming, 'unknown' otherwise.
sub state_name {
    my ($self) = @_;
    return $STATE_MAP{ $self->{code} // '' } // 'unknown';
}

# Exactly the two states whose documented remedy is to run the transaction
# again: a serialization failure under SERIALIZABLE or REPEATABLE READ, and a
# deadlock the server broke by choosing a victim. Both mean this transaction
# lost a race it could win next time.
#
# Nothing else belongs here. A unique violation will violate uniqueness again,
# a syntax error will not parse next time either, and a lost connection is not
# something a retry on that connection can fix.
my %RETRYABLE = map { $_ => 1 } qw(40001 40P01);

sub is_retryable {
    my ($self) = @_;
    return $RETRYABLE{ $self->{code} // '' } ? 1 : 0;
}


package Async::DBD::Pg::Error::Connection;

use parent -norequire, 'Async::DBD::Pg::Error';

sub dsn { shift->{dsn} }


package Async::DBD::Pg::Error::PoolExhausted;

use parent -norequire, 'Async::DBD::Pg::Error';

sub pool_size { shift->{pool_size} }


package Async::DBD::Pg::Error::Timeout;

use parent -norequire, 'Async::DBD::Pg::Error';

sub timeout { shift->{timeout} }


1;

__END__

=head1 NAME

Async::DBD::Pg::Error - Error classes for Async::DBD::Pg

=head1 SYNOPSIS

    use Async::DBD::Pg::Error;

    eval { await $conn->query('BAD SQL') };
    if (my $err = $@) {
        if ($err->isa('Async::DBD::Pg::Error::Query')) {
            warn "Query failed: " . $err->message;
            warn "SQLSTATE: " . $err->state;
        }
    }

=head1 DESCRIPTION

This module provides a hierarchy of error classes for Async::DBD::Pg.

All errors stringify to their message and are always true in boolean context,
so C<if (my $err = $@) { warn $err }> behaves as expected.

=head1 METHODS

=head2 message

The error message.

=head1 SUBCLASSES

=head2 Async::DBD::Pg::Error::Query

Raised when a statement fails. Its accessors are populated from the
diagnostics PostgreSQL returned with the error, so most are only defined when
they apply to that particular error.

=head3 state

The five character SQLSTATE, for example C<23505>, as DBI's own C<state>
documents it. This changed meaning: it used to return a readable name, which
made code comparing C<state> against a SQLSTATE such as C<'23505'> never
match. Readable names are now C<state_name>.

=head3 state_name

The SQLSTATE mapped to a readable name, for example C<unique_violation>.
Returns C<unknown> for codes this module does not name.

=head3 severity

The severity reported by the server, normally C<ERROR>.

=head3 detail

The server's secondary explanation, for example which key already exists.

=head3 hint

The server's suggestion for resolving the error, when it offers one.

=head3 constraint

Name of the constraint that was violated.

=head3 schema

Schema containing the object the error refers to.

=head3 table

Table the error refers to.

=head3 column

Column the error refers to.

=head3 position

Character offset into the statement at which the error was found, counting
from one. Reported for syntax errors.

=head3 context

The server's call stack context, for errors raised inside PL/pgSQL.

=head2 is_retryable

    if ($err->is_retryable) { ... }

True for the two SQLSTATEs whose documented remedy is to run the transaction
again: C<40001>, a serialization failure under C<SERIALIZABLE> or
C<REPEATABLE READ>, and C<40P01>, a deadlock the server broke by picking a
victim. Both mean this transaction lost a race that it might win next time.

False for everything else, deliberately. A unique violation will violate
uniqueness again, a syntax error will not parse next time either, and a lost
connection is not something retrying on that connection can fix.

Answerable on every error this distribution raises, not only on a query
error, so it never needs guarding with C<can>.

Retrying correctly means re-running the whole transaction rather than the
statement that failed, which
L<Async::DBD::Pg::Connection/"Retrying a transaction"> does.

=head2 Async::DBD::Pg::Error::Connection

Raised when a connection cannot be established.

=head3 dsn

The DSN that was used, with the password masked.

=head2 Async::DBD::Pg::Error::PoolExhausted

Raised when no connection became available before C<queue_timeout> elapsed.

=head3 pool_size

The pool's C<max_connections> at the time of the failure.

=head2 Async::DBD::Pg::Error::Timeout

Raised when a query exceeds its C<timeout>.

=head3 timeout

The timeout, in seconds, that was exceeded.

=head1 AUTHOR

John Napiorkowski E<lt>jjn1056@yahoo.comE<gt>

=cut

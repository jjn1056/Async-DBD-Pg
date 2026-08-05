package Async::DBD::Pg::Util;

use strict;
use warnings;
use Exporter 'import';
use Future::IO;

our @EXPORT_OK = qw(convert_placeholders parse_dsn safe_dsn pending_future);

# Convert named placeholders (:name) to positional ($1, $2, ...)
sub convert_placeholders {
    my ($sql, $params) = @_;
    $params //= {};

    # No early return for an empty parameter hash: a statement carrying a
    # named placeholder with nothing to bind to it is the very case that
    # needs reporting.

    my %seen;
    my @bind;
    my $pos = 0;

    my $result = '';
    my $i = 0;
    my $len = length($sql);

    # Find the end of a quoted string opening at $start. A doubled quote
    # always escapes; a backslash escapes only in the E'...' form, because a
    # standard string treats it as an ordinary character. An unterminated
    # string runs to the end of the statement, which leaves the syntax error
    # for PostgreSQL to report on the original text.
    my $string_end = sub {
        my ($start, $quote, $backslash_escapes) = @_;
        my $j = $start + 1;
        while ($j < $len) {
            my $c = substr($sql, $j, 1);
            if ($backslash_escapes && $c eq "\\" && $j + 1 < $len) {
                $j += 2;
                next;
            }
            if ($c eq $quote) {
                return $j + 1 unless substr($sql, $j + 1, 1) eq $quote;
                $j += 2;
                next;
            }
            $j++;
        }
        return $len;
    };

    while ($i < $len) {
        my $char = substr($sql, $i, 1);

        # Regions where a colon is text rather than a placeholder. Each one
        # consumes itself whole, so no scanner state survives an iteration.

        # Line comment, running to the newline or to the end of the statement.
        if ($char eq '-' && substr($sql, $i, 2) eq '--') {
            my $nl  = index($sql, "\n", $i);
            my $end = $nl == -1 ? $len : $nl;
            $result .= substr($sql, $i, $end - $i);
            $i = $end;
            next;
        }

        # Block comment. PostgreSQL nests these, so /* a /* b */ c */ is one
        # comment and stopping at the first */ would read ' c */' as SQL.
        if ($char eq '/' && substr($sql, $i, 2) eq '/*') {
            my $depth = 1;
            my $j = $i + 2;
            while ($j < $len && $depth) {
                my $two = substr($sql, $j, 2);
                if    ($two eq '/*') { $depth++; $j += 2 }
                elsif ($two eq '*/') { $depth--; $j += 2 }
                else                 { $j++ }
            }
            $result .= substr($sql, $i, $j - $i);
            $i = $j;
            next;
        }

        # Dollar-quoted string, $$...$$ or $tag$...$tag$, closed only by its
        # own tag. A positional $1 does not match: a tag cannot start with a
        # digit, and the empty tag needs a second dollar sign immediately.
        if ($char eq '$' && substr($sql, $i) =~ /\A(\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$)/) {
            my $tag   = $1;
            my $close = index($sql, $tag, $i + length($tag));
            my $end   = $close == -1 ? $len : $close + length($tag);
            $result .= substr($sql, $i, $end - $i);
            $i = $end;
            next;
        }

        # E'...' string, where a backslash escapes the character after it.
        # The prefix has to stand alone rather than end an identifier.
        if (($char eq 'E' || $char eq 'e')
            && substr($sql, $i + 1, 1) eq "'"
            && ($i == 0 || substr($sql, $i - 1, 1) !~ /[A-Za-z0-9_]/)) {
            my $end = $string_end->($i + 1, "'", 1);
            $result .= substr($sql, $i, $end - $i);
            $i = $end;
            next;
        }

        # Standard string literal, or a double-quoted identifier. A quote is
        # escaped by doubling it and a backslash is an ordinary character.
        if ($char eq "'" || $char eq '"') {
            my $end = $string_end->($i, $char, 0);
            $result .= substr($sql, $i, $end - $i);
            $i = $end;
            next;
        }

        if ($char eq ':' && $i + 1 < $len && substr($sql, $i + 1, 1) eq ':') {
            $result .= '::';
            $i += 2;
            next;
        }

        if ($char eq ':') {
            my $name = '';
            my $j = $i + 1;
            while ($j < $len && substr($sql, $j, 1) =~ /[a-zA-Z0-9_]/) {
                $name .= substr($sql, $j, 1);
                $j++;
            }

            # Only an identifier names a placeholder. A run of digits is an
            # array slice bound, as in arr[1:3] or arr[:2], and passes
            # through untouched.
            if (length($name) && $name =~ /\A[a-zA-Z_]/) {
                # Letting an unmatched name through produces SQL that
                # PostgreSQL rejects with a syntax error pointing at the
                # colon, which hides the real mistake.
                die "No value supplied for placeholder ':$name'\n"
                    unless exists $params->{$name};

                if (!exists $seen{$name}) {
                    $pos++;
                    $seen{$name} = $pos;
                    push @bind, $params->{$name};
                }
                $result .= '$' . $seen{$name};
                $i = $j;
                next;
            }
        }

        $result .= $char;
        $i++;
    }

    return ($result, \@bind);
}

# Parse PostgreSQL URI to DBI components
sub parse_dsn {
    my ($uri) = @_;

    my $parsed = {
        dbi_dsn  => '',
        user     => undef,
        password => undef,
    };

    if ($uri =~ m{^postgres(?:ql)?://
        (?:([^:@/]+)(?::([^@/]*))?@)?  # user:pass@
        ([^:/?]+)?                      # host
        (?::(\d+))?                     # :port
        (?:/([^?]+))?                   # /dbname
        (?:\?(.+))?                     # ?options
    }x) {
        my ($user, $pass, $host, $port, $db, $options) = ($1, $2, $3, $4, $5, $6);

        $host //= 'localhost';
        $port //= 5432;

        my @parts;
        push @parts, "dbname=$db" if $db;
        push @parts, "host=$host" if $host;
        push @parts, "port=$port" if $port;

        if ($options) {
            for my $opt (split /&/, $options) {
                my ($key, $val) = split /=/, $opt, 2;
                push @parts, "$key=$val" if defined $val;
            }
        }

        $parsed->{dbi_dsn}  = 'dbi:Pg:' . join(';', @parts);
        $parsed->{user}     = $user;
        $parsed->{password} = $pass;
    }
    else {
        die "Cannot parse DSN: $uri";
    }

    return $parsed;
}

# Return DSN with password masked
sub safe_dsn {
    my ($uri) = @_;
    $uri =~ s{://([^:]+):[^@]+@}{://$1:***@};
    return $uri;
}

# A leaf future for a caller to be manually completed later, e.g. a queued
# pool waiter or a mutex slot -- anything that has to hand a Future to a
# caller before the real work it represents exists yet.
#
# Future::AsyncAwait builds the pending placeholder an async sub returns when
# it suspends by cloning whatever future it is suspended on (Future's own
# AWAIT_CLONE is "shift->new"), so that placeholder is always the same class
# as the thing being awaited. A plain Future->new has no event-loop of its
# own, so a caller suspended on one -- even several calls down, since the
# cloning nests through every suspended async sub in the chain -- gets back a
# future whose ->get can never block, only croak once it isn't already ready.
# Cloning from a real Future::IO future instead gives every future this
# returns the reactor-aware ->await a caller's top-level ->get needs.
#
# Built fresh each call rather than cloned from a cached prototype: caching
# would fix the class at whichever implementation was loaded on first use,
# and a consumer that installs a mock implementation later via
# Future::IO->override_impl -- the documented way to test Future::IO code --
# would silently get a real-implementation future back from a mocked
# reactor. The cost of not caching is one timer create-and-cancel per call,
# noise beside the database round trip this is used around.
sub pending_future {
    my $f = Future::IO->sleep(0);
    $f->cancel;
    return $f->new;
}

1;

__END__

=head1 NAME

Async::DBD::Pg::Util - Utility functions for Async::DBD::Pg

=head1 SYNOPSIS

    use Async::DBD::Pg::Util qw(convert_placeholders parse_dsn);

    my ($sql, $bind) = convert_placeholders(
        'SELECT * FROM users WHERE id = :id',
        { id => 42 }
    );

=head1 FUNCTIONS

Nothing is exported by default.

=head2 convert_placeholders

    my ($sql, $bind) = convert_placeholders($sql, \%params);

Rewrites C<:name> placeholders to the C<$1>, C<$2> positional form
PostgreSQL expects, and returns the rewritten statement together with the
bind values in matching order. A name used more than once is bound once and
reuses the same position.

Colons that do not introduce a placeholder are left alone. C<::> casts, and
array slice bounds such as C<arr[1:3]> or C<arr[:2]>, whose bounds are
numbers rather than identifiers. So is anything inside one of the regions
where a colon is text:

=over 4

=item * single and double quoted strings, where a quote is escaped by
doubling it

=item * C<E'...'> strings, where a backslash escapes the character after it
as well. A backslash is B<not> an escape in a standard C<'...'> string, so
C<'a\'> is a complete string whose content is a backslash

=item * dollar-quoted strings, C<$$...$$> and C<$tag$...$tag$>, which only
the matching tag closes

=item * line comments, C<--> to the end of the line

=item * block comments, which nest: C<< /* a /* b */ c */ >> is one comment

=back

Dies if the statement names a placeholder that C<%params> has no value for.
Passing the name through would otherwise produce a statement PostgreSQL
rejects with a syntax error pointing at the colon, which obscures the real
mistake. A consequence is that an array slice written with identifier
bounds, C<arr[lower:upper]>, cannot be used together with named
placeholders; use positional placeholders for such a statement.

=head2 parse_dsn

    my $parsed = parse_dsn('postgresql://user:pass@host:5432/dbname');

Splits a PostgreSQL connection URI into the pieces C<DBI-E<gt>connect> wants,
returning a hashref of C<dbi_dsn>, C<user> and C<password>. Both the
C<postgres://> and C<postgresql://> forms are accepted.

Host defaults to C<localhost> and port to 5432 when the URI omits them. A
query string is carried across as further C<key=value> pairs on the DBI DSN,
so options such as C<?sslmode=require> reach the driver.

=head2 safe_dsn

    my $safe = safe_dsn('postgresql://user:hunter2@host/db');
    # postgresql://user:***@host/db

Replaces the password in a URI with C<***>, for a DSN about to be logged or
put into an error message. Anything that reports a DSN should pass it through
here first.

=head2 pending_future

    my $f = pending_future();
    ...
    $f->done($result);   # or $f->fail($error), or $f->cancel

Returns a new, not-yet-ready L<Future>, for code that must hand a caller a
future before the work it represents exists yet -- a queued pool waiter, or a
mutex slot a later caller will complete.

Unlike a bare C<< Future->new >>, a future from here is safe to C<get> or
top-level C<await> directly, even while a caller is suspended on nothing but
this future several C<async sub> calls deep: it is cloned from a real
L<Future::IO> future, so it carries the same event-loop-aware C<await> that
blocking on it requires, rather than the plain L<Future> base class's, which
can only croak if asked to block on something not yet ready.

=head1 AUTHOR

John Napiorkowski E<lt>jjn1056@yahoo.comE<gt>

=cut

package Async::DBD::Pg::Util;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(convert_placeholders parse_dsn safe_dsn);

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
    my $in_string = 0;
    my $string_char = '';
    my $i = 0;
    my $len = length($sql);

    while ($i < $len) {
        my $char = substr($sql, $i, 1);

        if (!$in_string && ($char eq "'" || $char eq '"')) {
            $in_string = 1;
            $string_char = $char;
            $result .= $char;
            $i++;
            next;
        }

        if ($in_string) {
            $result .= $char;
            if ($char eq $string_char) {
                if ($i + 1 < $len && substr($sql, $i + 1, 1) eq $string_char) {
                    $result .= substr($sql, $i + 1, 1);
                    $i += 2;
                    next;
                }
                $in_string = 0;
            }
            $i++;
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

Colons that do not introduce a placeholder are left alone: C<::> casts,
anything inside a single or double quoted string, and array slice bounds
such as C<arr[1:3]> or C<arr[:2]>, whose bounds are numbers rather than
identifiers.

Dies if the statement names a placeholder that C<%params> has no value for.
Passing the name through would otherwise produce a statement PostgreSQL
rejects with a syntax error pointing at the colon, which obscures the real
mistake. A consequence is that an array slice written with identifier
bounds, C<arr[lower:upper]>, cannot be used together with named
placeholders; use positional placeholders for such a statement.

=head1 AUTHOR

John Napiorkowski E<lt>jjn1056@yahoo.comE<gt>

=cut

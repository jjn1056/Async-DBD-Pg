package Future::IO::Pg::Util;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(convert_placeholders parse_dsn safe_dsn);

# Convert named placeholders (:name) to positional ($1, $2, ...)
sub convert_placeholders {
    my ($sql, $params) = @_;
    $params //= {};

    return ($sql, []) unless %$params;

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

            if (length($name) && exists $params->{$name}) {
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

Future::IO::Pg::Util - Utility functions for Future::IO::Pg

=head1 SYNOPSIS

    use Future::IO::Pg::Util qw(convert_placeholders parse_dsn);

    my ($sql, $bind) = convert_placeholders(
        'SELECT * FROM users WHERE id = :id',
        { id => 42 }
    );

=head1 AUTHOR

John Napiorkowski E<lt>jjn1056@yahoo.comE<gt>

=cut

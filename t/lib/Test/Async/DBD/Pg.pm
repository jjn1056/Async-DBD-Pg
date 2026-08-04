package Test::Async::DBD::Pg;

use strict;
use warnings;
use DBI;
use Exporter 'import';
use Test2::V0;

our @EXPORT_OK = qw(require_postgres skip_without_postgres test_dsn);

# Tag every connection this suite opens. The kill helpers in the test files
# terminate backends to simulate a dropped connection, and without a tag the
# only thing they can filter on is the database -- so they take out every
# other connection to it as well, including an unrelated application's.
#
# libpq reads PGAPPNAME when it connects, which covers the pool's connections,
# anything an on_connect hook opens, reconnects, and the helpers' own
# DBI->connect. Set unconditionally rather than with //=: honouring an
# inherited value would point the kills at whatever that value names, which is
# the failure this exists to prevent.
#
# Per-process, so two concurrent runs of the suite cannot terminate each
# other's backends either.
BEGIN { $ENV{PGAPPNAME} = "async-dbd-pg-test-$$" }

# Deliberately without a fallback. These tests create and drop data, and
# terminate backends to simulate connection loss; running them against a
# database nobody nominated is not something to do by default. A localhost
# default meant that any machine with PostgreSQL answering on 5432 -- a CPAN
# smoker's, a contributor's own -- would be used uninvited, because connecting
# successfully was the only condition checked.
#
# Callers use it through require_postgres/skip_without_postgres, which skip
# when this is undef, so an unset variable produces a clean skip rather than a
# failure.
sub test_dsn {
    return $ENV{TEST_PG_DSN};
}

sub require_postgres {
    my $dsn = test_dsn()
        or skip_all('TEST_PG_DSN is not set; see CONTRIBUTORS.md for how to '
                  . 'start a test database');

    my $parsed = _dsn_to_dbi($dsn);

    my $dbh = eval {
        DBI->connect(
            $parsed->{dbi_dsn},
            $parsed->{user},
            $parsed->{password},
            { RaiseError => 1, PrintError => 0 }
        );
    };

    if ($@ || !$dbh) {
        skip_all("Cannot connect to PostgreSQL: " . ($@ || DBI->errstr));
    }

    $dbh->disconnect;
    return $dsn;
}

sub skip_without_postgres {
    my $dsn = test_dsn()
        or skip_all('TEST_PG_DSN is not set; see CONTRIBUTORS.md for how to '
                  . 'start a test database');

    my $parsed = eval { _dsn_to_dbi($dsn) };
    skip_all("Cannot parse PostgreSQL DSN: $dsn") unless $parsed;

    my $dbh = eval {
        DBI->connect(
            $parsed->{dbi_dsn},
            $parsed->{user},
            $parsed->{password},
            { RaiseError => 1, PrintError => 0 }
        );
    };

    if ($@ || !$dbh) {
        skip_all("Cannot connect to PostgreSQL: " . ($@ || DBI->errstr));
    }

    $dbh->disconnect;
    return $dsn;
}

sub _dsn_to_dbi {
    my ($uri) = @_;

    if ($uri =~ m{^postgres(?:ql)?://(?:([^:]+)(?::([^@]+))?@)?([^:/]+)?(?::(\d+))?/(\w+)}) {
        my ($user, $pass, $host, $port, $db) = ($1, $2, $3, $4, $5);
        $host //= 'localhost';
        $port //= 5432;

        return {
            dbi_dsn  => "dbi:Pg:dbname=$db;host=$host;port=$port",
            user     => $user,
            password => $pass,
        };
    }

    die "Cannot parse DSN: $uri";
}

1;

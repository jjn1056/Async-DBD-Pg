package Test::Future::IO::Pg;

use strict;
use warnings;
use Exporter 'import';
use Test2::V0;

our @EXPORT_OK = qw(skip_without_postgres test_dsn);

sub test_dsn {
    return $ENV{TEST_PG_DSN};
}

sub skip_without_postgres {
    my $dsn = test_dsn();
    skip_all("Set TEST_PG_DSN to run integration tests") unless $dsn;
    return $dsn;
}

1;

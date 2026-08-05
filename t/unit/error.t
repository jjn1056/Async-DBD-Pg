use strict;
use warnings;
use Test2::V0;

use Async::DBD::Pg::Error;

subtest 'base error class' => sub {
    my $err = Async::DBD::Pg::Error->new(
        message => 'Something went wrong',
    );

    isa_ok $err, 'Async::DBD::Pg::Error';
    is $err->message, 'Something went wrong', 'message accessor';
    like "$err", qr/Something went wrong/, 'stringifies to message';
};

subtest 'query error' => sub {
    my $err = Async::DBD::Pg::Error::Query->new(
        message    => 'duplicate key value violates unique constraint',
        code       => '23505',
        constraint => 'users_email_key',
        detail     => 'Key (email)=(test@example.com) already exists.',
        hint       => undef,
        position   => 42,
    );

    isa_ok $err, 'Async::DBD::Pg::Error';
    isa_ok $err, 'Async::DBD::Pg::Error::Query';

    is $err->state, '23505', 'SQLSTATE code';
    is $err->constraint, 'users_email_key', 'constraint name';
    is $err->detail, 'Key (email)=(test@example.com) already exists.', 'detail';
    is $err->hint, undef, 'hint can be undef';
    is $err->position, 42, 'position';
    is $err->state_name, 'unique_violation', 'human-readable state from code';
};

subtest 'state is the SQLSTATE, matching DBI' => sub {
    my $err = Async::DBD::Pg::Error::Query->new(
        message => 'boom', code => '23505',
    );

    is $err->state, '23505',
        'state is the five-character SQLSTATE, as DBI documents it';
    is $err->state_name, 'unique_violation',
        'the readable name moved to state_name';
    ok !Async::DBD::Pg::Error::Query->can('code'),
        'code is gone rather than aliased -- one accessor, one meaning';

    my $odd = Async::DBD::Pg::Error::Query->new(message => 'x', code => '99999');
    is $odd->state, '99999', 'an unmapped code still reports its SQLSTATE';
    is $odd->state_name, 'unknown', 'and only the name is unknown';
};

subtest 'is_retryable names the two states PostgreSQL says to retry' => sub {
    # PostgreSQL documents exactly these as "retry the transaction". Anything
    # broader would retry a query that will fail again forever, or one whose
    # first attempt already had an effect.
    my $query_error = sub {
        return Async::DBD::Pg::Error::Query->new(message => 'x', code => $_[0]);
    };

    for my $code (qw(40001 40P01)) {
        ok $query_error->($code)->is_retryable, "$code is retryable";
    }

    # A unique violation, a syntax error and a cancelled query are all
    # permanent for the same transaction; retrying is just a slower failure.
    for my $code (qw(23505 42601 57014 08006 99999)) {
        ok !$query_error->($code)->is_retryable, "$code is not retryable";
    }

    my $stateless = Async::DBD::Pg::Error::Query->new(message => 'x');
    ok !$stateless->is_retryable, 'an error with no SQLSTATE is not retryable';

    # Answerable on any of our errors, so callers need no can() dance.
    my $conn_err = Async::DBD::Pg::Error::Connection->new(message => 'x');
    my $timeout  = Async::DBD::Pg::Error::Timeout->new(message => 'x');
    my $pool_err = Async::DBD::Pg::Error::PoolExhausted->new(message => 'x');

    ok !$conn_err->is_retryable, 'a connection error is not retryable';
    ok !$timeout->is_retryable, 'nor is a timeout';
    ok !$pool_err->is_retryable, 'nor pool exhaustion';
};

subtest 'connection error' => sub {
    my $err = Async::DBD::Pg::Error::Connection->new(
        message => 'Connection refused',
        dsn     => 'postgresql://localhost/test',
    );

    isa_ok $err, 'Async::DBD::Pg::Error';
    isa_ok $err, 'Async::DBD::Pg::Error::Connection';

    is $err->dsn, 'postgresql://localhost/test', 'dsn accessor';
};

subtest 'pool exhausted error' => sub {
    my $err = Async::DBD::Pg::Error::PoolExhausted->new(
        message   => 'Connection pool exhausted (waited 5s)',
        pool_size => 10,
    );

    isa_ok $err, 'Async::DBD::Pg::Error';
    isa_ok $err, 'Async::DBD::Pg::Error::PoolExhausted';

    is $err->pool_size, 10, 'pool_size accessor';
};

subtest 'timeout error' => sub {
    my $err = Async::DBD::Pg::Error::Timeout->new(
        message => 'Query timeout after 30s',
        timeout => 30,
    );

    isa_ok $err, 'Async::DBD::Pg::Error';
    isa_ok $err, 'Async::DBD::Pg::Error::Timeout';

    is $err->timeout, 30, 'timeout accessor';
};

subtest 'every mapped SQLSTATE resolves to its name' => sub {
    # The mapping is what callers branch on, so a typo in any entry is a bug
    # that only shows up in the one situation it names.
    my %expected = (
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

    for my $code (sort keys %expected) {
        my $err = Async::DBD::Pg::Error::Query->new(
            message => 'boom',
            code    => $code,
        );
        is $err->state_name, $expected{$code}, "$code is $expected{$code}";
    }
};

subtest 'unmapped SQLSTATE resolves to unknown' => sub {
    for my $code ('99999', 'XX000', '') {
        my $err = Async::DBD::Pg::Error::Query->new(
            message => 'boom',
            code    => $code,
        );
        is $err->state_name, 'unknown', "unmapped '$code' reports unknown";
    }
};

subtest 'query error carries server diagnostics' => sub {
    my $err = Async::DBD::Pg::Error::Query->new(
        message    => 'duplicate key',
        code       => '23505',
        severity   => 'ERROR',
        detail     => 'Key (email)=(a@example.com) already exists.',
        hint       => 'try another',
        constraint => 'users_email_key',
        schema     => 'public',
        table      => 'users',
        column     => 'email',
        position   => 42,
        context    => 'PL/pgSQL function f() line 1',
    );

    is $err->severity, 'ERROR', 'severity';
    is $err->detail, 'Key (email)=(a@example.com) already exists.', 'detail';
    is $err->hint, 'try another', 'hint';
    is $err->constraint, 'users_email_key', 'constraint';
    is $err->schema, 'public', 'schema';
    is $err->table, 'users', 'table';
    is $err->column, 'email', 'column';
    is $err->position, 42, 'position';
    is $err->context, 'PL/pgSQL function f() line 1', 'context';
};

subtest 'diagnostics are undef when the server did not supply them' => sub {
    my $err = Async::DBD::Pg::Error::Query->new(
        message => 'boom',
        code    => '42601',
    );

    is $err->$_, undef, "$_ is undef" for qw(
        severity detail hint constraint schema table column position context
    );
};

subtest 'errors can be thrown and caught' => sub {
    my $caught;
    eval {
        die Async::DBD::Pg::Error::Query->new(
            message => 'syntax error',
            code    => '42601',
        );
    };
    $caught = $@;

    ok $caught, 'error was thrown';
    isa_ok $caught, 'Async::DBD::Pg::Error::Query';
    is $caught->state, '42601', 'caught error has correct code';
};

done_testing;

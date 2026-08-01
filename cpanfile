# Dependencies for Async-DBD-Pg.
#
# This file is the single source of truth: dist.ini reads it through
# [Prereqs::FromCPANfile], so the released metadata and anything that
# installs from a checkout cannot drift apart.

requires 'perl', '5.018';

requires 'DBD::Pg', '3.18';
requires 'DBI', '1.643';
requires 'Future', '0.49';
requires 'Future::AsyncAwait', '0.66';
requires 'Future::IO', '0.23';

on 'test' => sub {
    requires 'Test2::V0', '0.000159';

    # Any Future::IO implementation will do; this one is what the suite
    # loads by default. The tests also pass under Future::IO::Impl::IOAsync,
    # which CI installs separately rather than making every installer pull
    # IO::Async in.
    requires 'Future::IO::Impl::UV', '0.07';
};

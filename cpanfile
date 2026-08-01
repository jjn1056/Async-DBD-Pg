# Dependencies for Async-DBD-Pg.
#
# This file is the single source of truth: dist.ini reads it through
# [Prereqs::FromCPANfile], so the released metadata and anything that
# installs from a checkout cannot drift apart.

# 5.24 is a hard floor, established by testing rather than chosen.
#
# Future::AsyncAwait implements cancellation propagation only on 5.24 and
# above: below that an async sub stops when cancelled but does not propagate
# the request into the future it is awaiting. This distribution depends on
# that propagation throughout — every guard that releases a resource when a
# caller cancels mid-await relies on it — so on 5.20 and 5.22 the suite fails
# wholesale, not marginally.
#
# 5.18 is additionally impossible: DBI 1.651 and later require 5.020, so a
# fresh install cannot resolve a current DBI at all.
requires 'perl', '5.024';

# Three components, deliberately. DBD::Pg declares its version with qv(),
# so a single-decimal '3.18' is read as v3.180.0 — a release that will never
# exist — and every install fails the prerequisite. CI caught this; nothing
# local would have, because the tests never check the prereq.
requires 'DBD::Pg', '3.18.0';
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

package Test::Async::DBD::Pg::DelayProxy;

use strict;
use warnings;

use IO::Socket::INET;
use POSIX ();

# A TCP proxy that sleeps before relaying each chunk, so a test can put a
# known amount of latency between this library and PostgreSQL.
#
# tc/netem would be the obvious tool and is not usable here: it needs
# privileges the CI sandbox does not have, and has no equivalent on macOS.
# This is unprivileged and deterministic.
#
# It runs in a child process, and that is not incidental. An in-process proxy
# deadlocks: libpq blocks inside connect, and the reactor it is blocking is
# the same one the proxy needs in order to accept that connection. Measured --
# a plain socket client relays fine in-process, and the library's own connect
# hangs forever.

sub new {
    my ($class, %args) = @_;

    my $target_port = $args{target_port}
        or die "DelayProxy needs target_port\n";

    my $self = bless {
        # Seconds of delay applied to each relayed chunk, in each direction.
        delay       => $args{delay} // 0,
        target_host => $args{target_host} // 'localhost',
        target_port => $target_port,
        _sessions   => [],
    }, $class;

    # Bound before the fork, so the parent knows the port without having to
    # be told it by the child.
    my $listener = IO::Socket::INET->new(
        LocalAddr => '127.0.0.1',
        LocalPort => 0,          # let the OS choose, so tests never collide
        Listen    => 128,
        Proto     => 'tcp',
        ReuseAddr => 1,
    ) or die "DelayProxy could not listen: $!\n";

    $self->{port} = $listener->sockport;

    my $pid = fork();
    die "DelayProxy could not fork: $!\n" unless defined $pid;

    if ($pid == 0) {
        # Child: relay until killed. Nothing here returns.
        eval { $self->_relay_forever($listener) };
        POSIX::_exit(0);
    }

    close $listener;
    $self->{pid} = $pid;

    return $self;
}

sub port { $_[0]{port} }

# A DSN pointing at the proxy rather than at PostgreSQL, with everything else
# taken from the DSN the suite was given.
sub dsn_from {
    my ($self, $dsn) = @_;

    $dsn =~ s{\@([^/:]+)(?::\d+)?}{\@127.0.0.1:$self->{port}};

    return $dsn;
}

# Plain select in the child, deliberately, rather than Future::IO.
#
# The child is forked from a process whose event loop may already be running,
# and a libuv loop does not survive fork: the first proxy in a test file works
# and every later one silently fails to accept. Measured, and it cost an
# afternoon. select has no such problem, the child needs no concurrency beyond
# "watch these sockets", and a blocking sleep is free here because nothing
# else shares this process.
sub _relay_forever {
    my ($self, $listener) = @_;

    require IO::Select;

    my $select = IO::Select->new($listener);
    my %peer;    # each socket of a pair points at the other

    local $SIG{PIPE} = 'IGNORE';

    while (1) {
        my @ready = $select->can_read(0.05);

        for my $sock (@ready) {
            if ($sock == $listener) {
                my $client = $listener->accept or next;

                my $server = IO::Socket::INET->new(
                    PeerAddr => $self->{target_host},
                    PeerPort => $self->{target_port},
                    Proto    => 'tcp',
                );

                if (!$server) {
                    close $client;
                    next;
                }

                $peer{$client} = $server;
                $peer{$server} = $client;
                $select->add($client, $server);
                next;
            }

            my $other = $peer{$sock} or next;

            my $chunk = '';
            my $bytes = sysread $sock, $chunk, 65536;

            if (!$bytes) {
                # Either end closing takes the pair down with it.
                $select->remove($sock, $other);
                delete @peer{ $sock, $other };
                close $sock;
                close $other;
                next;
            }

            select undef, undef, undef, $self->{delay} if $self->{delay};

            my $written = 0;
            while ($written < length $chunk) {
                my $n = syswrite $other, $chunk, length($chunk) - $written, $written;
                last unless defined $n;
                $written += $n;
            }
        }
    }

    return;
}

sub stop {
    my ($self) = @_;

    my $pid = delete $self->{pid} or return;

    kill 'TERM', $pid;
    waitpid $pid, 0;

    return;
}

sub DESTROY {
    my ($self) = @_;
    return if ${^GLOBAL_PHASE} eq 'DESTRUCT';

    # Only the parent owns the child; a forked copy must not reap it.
    return unless $self->{pid};

    $self->stop;
}

1;

__END__

=head1 NAME

Test::Async::DBD::Pg::DelayProxy - inject latency between the suite and PostgreSQL

=head1 SYNOPSIS

    my $proxy = Test::Async::DBD::Pg::DelayProxy->new(
        target_port => 5432,
        delay       => 0.002,     # 2ms each way, per chunk
    );

    my $pg = Async::DBD::Pg->new(dsn => $proxy->dsn_from(test_dsn()));
    ...
    $proxy->stop;

=head1 DESCRIPTION

A TCP proxy that relays to PostgreSQL after sleeping, so that a benchmark can
report what a feature is worth at a realistic round trip rather than only on
loopback.

C<tc>/C<netem> would be the usual tool and is not usable here: it needs
privileges the CI sandbox lacks and has no macOS equivalent. This is
unprivileged and deterministic.

The delay applies per relayed chunk in each direction, so one request/response
exchange costs roughly twice C<delay>.

The relay runs in a forked child using plain C<select>, for two measured
reasons. In-process, it deadlocks: libpq blocks inside connect while holding
the reactor the proxy needs in order to accept that same connection. And a
libuv loop does not survive C<fork>, so a child built on L<Future::IO> accepts
for the first proxy in a test file and silently fails for every later one.

=cut

package Async::DBD::Pg::PubSub;

use strict;
use warnings;

use Future::AsyncAwait;
use Future::IO qw(POLLIN);
use Scalar::Util qw(refaddr weaken);

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        pool             => $args{pool},
        conn             => undef,
        channels         => {},
        connected        => 0,
        _listener_future => undef,
        _stopping        => 0,
    }, $class;

    weaken($self->{pool}) if $self->{pool};

    return $self;
}

sub pool                { shift->{pool} }
sub conn                { shift->{conn} }
sub is_connected        { shift->{connected} }
sub subscribed_channels { scalar keys %{shift->{channels}} }

sub _validate_channel {
    my ($self, $channel) = @_;

    return 0 unless defined $channel && length $channel;
    return 0 if $channel =~ /[\s;'"\\]/;
    return 0 if $channel =~ /[\x00-\x1f]/;
    return 1;
}

sub _log {
    my ($self, $level, $message) = @_;

    if (my $pool = $self->{pool}) {
        $pool->_log($level, $message);
        return;
    }

    warn "Async::DBD::Pg::PubSub [$level]: $message\n";
}

async sub connect {
    my ($self) = @_;

    return $self if $self->{connected} && $self->{conn} && $self->{conn}->dbh;

    my $pool = $self->{pool} or die "No pool configured";

    $self->{conn} = await $pool->connection;
    $self->{connected} = 1;
    $self->{_stopping} = 0;

    await $self->_start_listener;

    return $self;
}

async sub listen {
    my ($self, $channel, $callback) = @_;

    die "Invalid channel name: $channel"
        unless $self->_validate_channel($channel);
    die "listen requires a callback"
        unless ref $callback eq 'CODE';

    await $self->connect unless $self->{connected};

    my $callbacks = $self->{channels}{$channel} ||= [];
    my $first_subscription = !@$callbacks;

    push @$callbacks, $callback;

    if ($first_subscription) {
        await $self->_run_control_query("LISTEN $channel");
    }

    return $self;
}

async sub unlisten {
    my ($self, $channel, $callback) = @_;

    return $self unless exists $self->{channels}{$channel};

    if ($callback) {
        my $target = refaddr($callback);
        @{$self->{channels}{$channel}} = grep {
            refaddr($_) != $target
        } @{$self->{channels}{$channel}};
    }
    else {
        $self->{channels}{$channel} = [];
    }

    if (!@{$self->{channels}{$channel}}) {
        delete $self->{channels}{$channel};
        if ($self->{conn}) {
            await $self->_run_control_query("UNLISTEN $channel");
        }
    }

    return $self;
}

async sub unlisten_all {
    my ($self) = @_;

    $self->{channels} = {};

    if ($self->{conn}) {
        await $self->_run_control_query('UNLISTEN *');
    }

    return $self;
}

async sub notify {
    my ($self, $channel, $payload) = @_;

    die "Invalid channel name: $channel"
        unless $self->_validate_channel($channel);

    my $pool = $self->{pool} or die "No pool configured";
    my $conn = await $pool->connection;

    my $result = eval {
        await $conn->query('SELECT pg_notify($1, $2)', $channel, $payload);
    };
    my $err = $@;

    $conn->release;

    die $err if $err;
    return $result;
}

sub _process_notifications {
    my ($self) = @_;

    my $conn = $self->{conn} or return 0;
    my $dbh = $conn->dbh or return 0;

    my $count = 0;

    while (my $notification = $dbh->pg_notifies) {
        my ($channel, $pid, $payload) = @$notification;
        my $callbacks = $self->{channels}{$channel} || [];

        for my $cb (@$callbacks) {
            eval { $cb->($channel, $payload, $pid) };
            next unless $@;
            $self->_log(warn => "PubSub callback error for $channel: $@");
        }

        $count++;
    }

    return $count;
}

async sub _listener_loop {
    my ($self) = @_;

    my $conn = $self->{conn} or return;
    my $sock = $conn->_get_socket;

    while (!$self->{_stopping}) {
        await Future::IO->poll($sock, POLLIN);
        last if $self->{_stopping};
        $self->_process_notifications;
    }

    return;
}

async sub _start_listener {
    my ($self) = @_;

    return $self unless $self->{connected} && $self->{conn};
    return $self if $self->{_listener_future} && !$self->{_listener_future}->is_ready;

    my $listener = $self->_listener_loop;
    my $weak_self = $self;
    weaken($weak_self);

    $listener->on_fail(sub {
        my ($err) = @_;
        my $self = $weak_self or return;
        return if $self->{_stopping};
        $self->_log(warn => "PubSub listener stopped: $err");
    });

    $self->{_listener_future} = $listener;

    return $self;
}

async sub _stop_listener {
    my ($self) = @_;

    my $listener = delete $self->{_listener_future} or return;

    $self->{_stopping} = 1;
    $listener->cancel unless $listener->is_ready;

    eval { await $listener };

    return;
}

async sub _run_control_query {
    my ($self, $sql, @bind) = @_;

    await $self->_stop_listener if $self->{_listener_future};

    my $result = await $self->{conn}->query($sql, @bind);

    $self->{_stopping} = 0;
    await $self->_start_listener if $self->{connected};

    return $result;
}

async sub disconnect {
    my ($self) = @_;

    return $self unless $self->{connected} || $self->{conn};

    await $self->_stop_listener if $self->{_listener_future};

    if (my $conn = delete $self->{conn}) {
        eval { await $conn->query('UNLISTEN *') };
        $conn->release;
    }

    $self->{channels} = {};
    $self->{connected} = 0;
    $self->{_stopping} = 0;

    return $self;
}

sub _pool_shutdown {
    my ($self) = @_;

    $self->{_stopping} = 1;

    if (my $listener = delete $self->{_listener_future}) {
        $listener->cancel unless $listener->is_ready;
    }

    $self->{conn} = undef;
    $self->{channels} = {};
    $self->{connected} = 0;
}

sub DESTROY {
    my ($self) = @_;

    return if ${^GLOBAL_PHASE} eq 'DESTRUCT';
    $self->_pool_shutdown;
}

1;

__END__

=head1 NAME

Async::DBD::Pg::PubSub - LISTEN/NOTIFY support for Async::DBD::Pg

=head1 SYNOPSIS

    my $pubsub = $pg->pubsub;

    await $pubsub->listen(my_channel => sub {
        my ($channel, $payload, $pid) = @_;
        ...
    });

    await $pubsub->notify(my_channel => 'hello');
    await $pubsub->disconnect;

=head1 DESCRIPTION

This module provides loop-agnostic PostgreSQL pub/sub support built on top of
L<DBD::Pg>'s C<LISTEN>, C<UNLISTEN>, and C<pg_notifies> support, with socket
readiness handled through L<Future::IO>.

=cut

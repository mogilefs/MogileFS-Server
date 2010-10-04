package MogileFS::Worker;
use strict;
use fields ('psock',              # socket for parent/child communications
            'last_bcast_state',   # "{device|host}-$devid" => [$time, {alive|dead}]
            'readbuf',            # unparsed data from parent
            'monitor_has_run',    # true once we've heard of the monitor job being alive
            'last_ping',          # time we last said we're alive
            'woken_up',           # bool: if we've been woken up
            'last_wake',          # hashref: { $class -> time() } when we last woke up a certain job class
            'queue_depth',        # depth of a queue we queried
            'queue_todo',         # aref of hrefs of work sent from parent
            );

use MogileFS::Util qw(error eurl decode_url_args);
use MogileFS::Server;

use vars (
          '$got_live_vs_die',    # local'ized scalarref flag for whether we've
                                 # gotten a live-vs-die instruction from parent
          );

sub new {
    my ($self, $psock) = @_;
    $self = fields::new($self) unless ref $self;

    $self->{psock}            = $psock;
    $self->{readbuf}          = '';
    $self->{last_bcast_state} = {};
    $self->{monitor_has_run}  = 0;
    $self->{last_ping}        = 0;
    $self->{last_wake}        = {};
    $self->{queue_depth}      = {};
    $self->{queue_todo}       = {};

    IO::Handle::blocking($psock, 0);
    return $self;
}

sub psock_fd {
    my $self = shift;
    return fileno($self->{psock});
}

sub validate_dbh {
    return Mgd::validate_dbh();
}

sub get_dbh {
    return Mgd::get_dbh();
}

sub monitor_has_run {
    my $self = shift;
    return $self->{monitor_has_run} ? 1 : 0;
}

sub forget_that_monitor_has_run {
    my $self = shift;
    $self->{monitor_has_run} = 0;
}

sub wait_for_monitor {
    my $self = shift;
    while (! $self->monitor_has_run) {
        $self->read_from_parent;
        $self->still_alive;
        sleep 1;
    }
}

# method that workers can call just to write something to the parent, so worker
# doesn't get killed.  (during idle/slow operation, say)
# returns current time, so caller can avoid a time() call as well, for its loop
sub still_alive {
    my $self = shift;
    my $now = time();
    if ($now > $self->{last_ping} + ($self->watchdog_timeout / 4)) {
        $self->send_to_parent(":still_alive");  # a no-op, just for the watchdog
        $self->{last_ping} = $now;
    }
    return $now;
}

sub send_to_parent {
    my $self = shift;

    # can be called as package method:  MogileFS::Worker->send_to_parent...
    unless (ref $self) {
        $self = MogileFS::ProcManager->is_child
            or return;
    }

    my $write = "$_[0]\r\n";
    my $totallen = length $write;
    my $rv = syswrite($self->{psock}, $write);
    return 1 if defined $rv && $rv == $totallen;
    die "Error writing to parent process: $!" if $! && ! $!{EAGAIN};

    $rv ||= 0;  # could've been undef, if EAGAIN immediately.
    my $remain = $totallen - $rv;
    my $offset = $rv;
    while ($remain > 0) {
        MogileFS::Util::wait_for_writeability(fileno($self->{psock}), 30)
            or die "Parent not writable in 30 seconds";

        $rv = syswrite($self->{psock}, $write, $remain, $offset);
        die "Error writing to parent process (in loop): $!" if $! && ! $!{EAGAIN};
        if ($rv) {
            $remain -= $rv;
            $offset += $rv;
        }
    }
    die "remain is negative:  $remain" if $remain < 0;
    return 1;
}

# override in children
sub watchdog_timeout {
    return 10;
}

# should be overridden by workers to process worker-specific directives
# from the parent process.  return 1 if you recognize the command, 0 otherwise.
sub process_line {
    my ($self, $lineref) = @_;
    return 0;
}

sub read_from_parent {
    my $self    = shift;
    my $timeout = shift || 0;
    my $psock = $self->{psock};

    # while things are immediately available,
    # (or optionally sleep a bit)
    while (MogileFS::Util::wait_for_readability(fileno($psock), $timeout)) {
        $timeout = 0; # only wait on the timeout for the first read.
        my $buf;
        my $rv = sysread($psock, $buf, 1024);
        if (!$rv) {
            if (defined $rv) {
                die "While reading pipe from parent, got EOF.  Parent's gone.  Quitting.\n";
            } else {
                die "Error reading pipe from parent: $!\n";
            }
        }

        if ($Mgd::POST_SLEEP_DEBUG) {
            my $out = $buf;
            $out =~ s/\s+$//;
            warn "proc ${self}[$$] read: [$out]\n"
        }
        $self->{readbuf} .= $buf;

        while ($self->{readbuf} =~ s/^(.+?)\r?\n//) {
            my $line = $1;

            next if $self->process_generic_command(\$line);
            my $ok = $self->process_line(\$line);
            unless ($ok) {
                error("Unrecognized command from parent: $line");
            }
        }
    }
}

sub parent_ping {
    my $self = shift;
    my $psock = $self->{psock};
    $self->send_to_parent(':ping');

    my $got_reply = 0;
    die "recursive parent_ping!" if $got_live_vs_die;
    local $got_live_vs_die = \$got_reply;

    my $loops = 0;

    while (!$got_reply) {
        $self->read_from_parent;
        return if $got_reply;

        $loops++;
        select undef, undef, undef, 0.20;
        if ($loops > 5) {
            warn "No simple reply from parent to child $self [$$] in $loops 0.2second loops.\n";
            die "No answer in 4 seconds from parent to child $self [$$], dying" if $loops > 20;
        }
    }
}

sub broadcast_device_writeable {
    $_[0]->_broadcast_state("device", $_[1], "writeable");
}
sub broadcast_device_readable {
    $_[0]->_broadcast_state("device", $_[1], "readable");
}
sub broadcast_device_unreachable {
    $_[0]->_broadcast_state("device", $_[1], "unreachable");
}
sub broadcast_host_reachable {
    $_[0]->_broadcast_state("host", $_[1], "reachable");
}
sub broadcast_host_unreachable {
    $_[0]->_broadcast_state("host", $_[1], "unreachable");
}

sub _broadcast_state {
    my ($self, $what, $whatid, $state) = @_;
    if ($what eq "host") {
        MogileFS::Host->of_hostid($whatid)->set_observed_state($state);
    } elsif ($what eq "device") {
        MogileFS::Device->of_devid($whatid)->set_observed_state($state);
    }
    my $key = "$what-$whatid";
    my $laststate = $self->{last_bcast_state}{$key};
    my $now = time();
    # broadcast on initial discovery, state change, and every 10 seconds
    if (!$laststate || $laststate->[1] ne $state || $laststate->[0] < $now - 10) {
        $self->send_to_parent(":state_change $what $whatid $state");
        $self->{last_bcast_state}{$key} = [$now, $state];
    }
}

sub invalidate_meta {
    my ($self, $what) = @_;
    return if $Mgd::INVALIDATE_NO_PROPOGATE;  # anti recursion
    $self->send_to_parent(":invalidate_meta $what");
}

# tries to parse generic (not job-specific) commands sent from parent
# to child.  returns 1 on success, or 0 if command given isn't generic,
# and child should parse.
# lineref doesn't have \r\n at end.
sub process_generic_command {
    my ($self, $lineref) = @_;
    return 0 unless $$lineref =~ /^:/;  # all generic commands start with colon

    if ($$lineref =~ /^:state_change (\w+) (\d+) (\w+)/) {
        my ($what, $whatid, $state) = ($1, $2, $3);
        if ($what eq "host") {
            MogileFS::Host->of_hostid($whatid)->set_observed_state($state);
        } elsif ($what eq "device") {
            MogileFS::Device->of_devid($whatid)->set_observed_state($state);
        }
        return 1;
    }

    if ($$lineref =~ /^:shutdown/) {
        $$got_live_vs_die = 1 if $got_live_vs_die;
        exit 0;
    }

    if ($$lineref =~ /^:stay_alive/) {
        $$got_live_vs_die = 1 if $got_live_vs_die;
        return 1;
    }

    if ($$lineref =~ /^:invalidate_meta_once (\w+)/) {
        local $Mgd::INVALIDATE_NO_PROPOGATE = 1;
        # where $1 is one of {"domain", "device", "host", "class"}
        my $class = "MogileFS::" . ucfirst(lc($1));
        $class->invalidate_cache;
        return 1;
    }

    if ($$lineref =~ /^:monitor_has_run/) {
        $self->{monitor_has_run} = 1;
        return 1;
    }

    if ($$lineref =~ /^:wake_up/) {
        $self->{woken_up} = 1;
        return 1;
    }

    if ($$lineref =~ /^:set_config_from_parent (\S+) (.+)/) {
        # the 'no_broadcast' API keeps us from looping forever.
        MogileFS::Config->set_config_no_broadcast($1, $2);
        return 1;
    }

    # :set_dev_(await|svctm|utilization) dev# 45.2 dev# 45.2 dev# 45.2 dev# 45.2 dev 45.2\n
    # (dev#, utilz%)+
    if (my ($devid, $util) = $$lineref =~ /^:set_dev_(await|svctm|utilization) (.+)/) {
        my $type = $1;
        my %pairs = split(/\s+/, $2);
        local $MogileFS::Device::no_broadcast = 1;
        while (my ($devid, $val) = each %pairs) {
            my $dev = eval { MogileFS::Device->of_devid($devid) } or next;

            if ($type eq 'await') {
                $dev->set_observed_await($val);
            } elsif ($type eq 'svctm') {
                $dev->set_observed_svctm($val);
            } elsif ($type eq 'utilization') {
                $dev->set_observed_utilization($val);
            }
        }
        return 1;
    }

    # queue_name depth
    if ($$lineref =~ /^:queue_depth (\w+) (\d+)/) {
        $self->queue_depth($1, $2);
        return 1;
    }

    # queue_name encoded_item
    if ($$lineref =~ /^:queue_todo (\w+) (.+)/) {
        # TODO: Use the accessor.
        push(@{$self->{queue_todo}->{$1}}, decode_url_args(\$2));
        return 1;
    }

    # TODO: warn on unknown commands?

    return 0;
}

sub queue_depth {
    my MogileFS::Worker $self = shift;
    my $type = shift;
    $self->{queue_depth}->{$type} ||= 0;
    return $self->{queue_depth}->{$type} unless @_;
    return $self->{queue_depth}->{$type} = shift;
}

sub queue_todo {
    my MogileFS::Worker $self = shift;
    my $type = shift;
    $self->{queue_todo}->{$type} ||= [];
    push(@{$self->{queue_todo}->{$type}}, @_) if @_;
    return $self->{queue_todo}->{$type};
}

sub was_woken_up {
    my MogileFS::Worker $self = shift;
    return $self->{woken_up};
}

sub forget_woken_up {
    my MogileFS::Worker $self = shift;
    $self->{woken_up} = 0;
}

# don't wake processes more than once a second... not necessary.
sub wake_a {
    my ($self, $class) = @_;
    my $now = time();
    return if ($self->{last_wake}{$class}||0) == $now;
    $self->{last_wake}{$class} = $now;
    $self->send_to_parent(":wake_a $class");
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:


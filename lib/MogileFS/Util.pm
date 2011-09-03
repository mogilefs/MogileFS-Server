package MogileFS::Util;
use strict;
use Carp qw(croak);
use Time::HiRes;
use MogileFS::Server;
use MogileFS::Exception;
use MogileFS::DeviceState;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(
                    error undeferr debug fatal daemonize weighted_list every
                    wait_for_readability wait_for_writeability throw error_code
                    max min first okay_args device_state eurl decode_url_args
                    encode_url_args apply_state_events
                    );

# Applies monitor-job-supplied state events against the factory singletons.
# Sad this couldn't be an object method, but ProcManager doesn't base off
# anything common.
sub apply_state_events {
    my @events = split(/\s/, ${$_[0]});
    shift @events; # pop the :monitor_events part

    # This will needlessly fetch domain/class/host most of the time.
    # Maybe replace with something that "caches" factories?
    my %factories = ( 'domain' => MogileFS::Factory::Domain->get_factory,
        'class'  => MogileFS::Factory::Class->get_factory,
        'host'   => MogileFS::Factory::Host->get_factory,
        'device' => MogileFS::Factory::Device->get_factory, );

    for my $ev (@events) {
        my $args = decode_url_args($ev);
        my $mode = delete $args->{ev_mode};
        my $type = delete $args->{ev_type};
        my $id   = delete $args->{ev_id};

        my $old = $factories{$type}->get_by_id($id);
        if ($mode eq 'setstate') {
            # Host/Device only.
            # FIXME: Make objects slightly mutable and directly set fields?
            $factories{$type}->set({ %{$old->fields}, %$args });
        } elsif ($mode eq 'set') {
            # Re-add any observed data.
            my $observed = $old ? $old->observed_fields : {};
            $factories{$type}->set({ %$args, %$observed });
        } elsif ($mode eq 'remove') {
            $factories{$type}->remove($old) if $old;
        }
    }
}

sub every {
    my ($delay, $code) = @_;
    my ($worker, $psock_fd);
    if ($worker = MogileFS::ProcManager->is_child) {
        $psock_fd = $worker->psock_fd;
    }
  CODERUN:
    while (1) {
        my $start = Time::HiRes::time();
        my $explicit_sleep = undef;

        # run the code in a loop, so "next" will get out of it.
        foreach (1) {
            $code->(sub {
                $explicit_sleep = shift;
            });
        }

        my $now = Time::HiRes::time();
        my $took = $now - $start;
        my $sleep_for = defined $explicit_sleep ? $explicit_sleep : ($delay - $took);

        # simple case, not in a child process (this never happens currently)
        unless ($psock_fd) {
            Time::HiRes::sleep($sleep_for);
            next;
        }

        Time::HiRes::sleep($sleep_for) if $sleep_for > 0;
        #local $Mgd::POST_SLEEP_DEBUG = 1;
        # This calls read_from_parent. Workers used to needlessly call
        # parent_ping constantly.
        $worker->parent_ping;
    }
}

sub debug {
    my ($msg, $level) = @_;
    return unless $Mgd::DEBUG >= 1;
    $msg =~ s/[\r\n]+//g;
    if (my $worker = MogileFS::ProcManager->is_child) {
        $worker->send_to_parent("debug $msg");
    } else {
        my $dbg = "[debug] $msg";
        MogileFS::ProcManager->NoteError(\$dbg);
        Mgd::log('debug', $msg);
    }
}

our $last_error;
sub error {
    my ($errmsg) = @_;
    $last_error = $errmsg;
    if (my $worker = MogileFS::ProcManager->is_child) {
        my $msg = "error $errmsg";
        $msg =~ s/\s+$//;
        $worker->send_to_parent($msg);
    } else {
        MogileFS::ProcManager->NoteError(\$errmsg);
        Mgd::log('debug', $errmsg);
    }
    return 0;
}

# like error(), but returns undef.
sub undeferr {
    error(@_);
    return undef;
}

sub last_error {
    return $last_error;
}

sub fatal {
    my ($errmsg) = @_;
    error($errmsg);
    die $errmsg;
}

sub throw {
    my ($errcode) = @_;
    MogileFS::Exception->new($errcode)->throw;
}

sub error_code {
    my ($ex) = @_;
    return "" unless UNIVERSAL::isa($ex, "MogileFS::Exception");
    return $ex->code;
}

sub daemonize {
    my($pid, $sess_id, $i);

    ## Fork and exit parent
    if ($pid = fork) { exit 0; }

    ## Detach ourselves from the terminal
    croak "Cannot detach from controlling terminal"
        unless $sess_id = POSIX::setsid();

    ## Prevent possibility of acquiring a controlling terminal
    $SIG{'HUP'} = 'IGNORE';
    if ($pid = fork) { exit 0; }

    ## Change working directory
    chdir "/";

    ## Clear file creation mask
    umask 0;

    print STDERR "Daemon running as pid $$.\n" if $MogileFS::DEBUG;

    ## Close open file descriptors
    close(STDIN);
    close(STDOUT);
    close(STDERR);

    ## Reopen STDERR, STDOUT, STDIN to /dev/null
    if ( $MogileFS::DEBUG ) {
        open(STDIN,  "+>/tmp/mogilefsd.log");
    } else {
        open(STDIN,  "+>/dev/null");
    }
    open(STDOUT, "+>&STDIN");
    open(STDERR, "+>&STDIN");
}

# input:
#   given an array of arrayrefs of [ item, weight ], returns weighted randomized
#   list of items (without the weights, not arrayref; just list)
#
#   a weight of 0 means to exclude that item from the results list; i.e. it's not
#   ever used
#
# example:
#   my @items = weighted_list( [ 1, 10 ], [ 2, 20 ], [ 3, 0 ] );
#
#   returns (1, 2) or (2, 1) with the latter far more likely
sub weighted_list (@) {
    my @list = grep { $_->[1] > 0 } @_;
    my @ret;

    my $sum = 0;
    $sum += $_->[1] foreach @list;

    my $getone = sub {
        return shift(@list)->[0]
            if scalar(@list) == 1;

        my $val = rand() * $sum;
        my $curval = 0;
        for (my $idx = 0; $idx < scalar(@list); $idx++) {
            my $item = $list[$idx];
            $curval += $item->[1];
            if ($curval >= $val) {
                my ($ret) = splice(@list, $idx, 1);
                $sum -= $item->[1];
                return $ret->[0];
            }
        }
    };

    push @ret, $getone->() while @list;
    return @ret;
}

# given a file descriptor number and a timeout, wait for that descriptor to
# become readable; returns 0 or 1 on if it did or not
sub wait_for_readability {
    my ($fileno, $timeout) = @_;
    return 0 unless $fileno && $timeout >= 0;

    my $rin = '';
    vec($rin, $fileno, 1) = 1;
    my $nfound = select($rin, undef, undef, $timeout);

    # nfound can be undef or 0, both failures, or 1, a success
    return $nfound ? 1 : 0;
}

sub wait_for_writeability {
    my ($fileno, $timeout) = @_;
    return 0 unless $fileno && $timeout;

    my $rout = '';
    vec($rout, $fileno, 1) = 1;
    my $nfound = select(undef, $rout, undef, $timeout);

    # nfound can be undef or 0, both failures, or 1, a success
    return $nfound ? 1 : 0;
}

# if given an HTTP URL, break it down into [ host, port, URI ], else
# returns die, because we don't support non-http-mode anymore
sub url_parts {
    my $path = shift;
    if ($path =~ m!^http://(.+?)(?::(\d+))?(/.+)$!) {
        return [ $1, $2 || 80, $3 ];
    }
    Carp::croak("Bogus URL: $path");
}

sub max {
    my ($n1, $n2) = @_;
    return $n1 if $n1 > $n2;
    return $n2;
}

sub min {
    my ($n1, $n2) = @_;
    return $n1 if $n1 < $n2;
    return $n2;
}

sub first (&@) {
    my $code = shift;
    foreach (@_) {
        return $_ if $code->();
    }
    undef;
}

sub okay_args {
    my ($href, @okay) = @_;
    my %left = %$href;
    delete $left{$_} foreach @okay;
    return 1 unless %left;
    Carp::croak("Unknown argument(s): " . join(", ", sort keys %left));
}

sub device_state {
    my ($state) = @_;
    return MogileFS::DeviceState->of_string($state);
}

sub eurl {
    my $a = defined $_[0] ? $_[0] : "";
    $a =~ s/([^a-zA-Z0-9_\,\-.\/\\\: ])/uc sprintf("%%%02x",ord($1))/eg;
    $a =~ tr/ /+/;
    return $a;
}

sub encode_url_args {
    my $args = shift;
    return join('&', map { eurl($_) . "=" . eurl($args->{$_}) } keys %$args);
}

sub decode_url_args {
    my $a = shift;
    my $buffer = ref $a ? $a : \$a;
    my $ret = {};

    my $pair;
    my @pairs = grep { $_ } split(/&/, $$buffer);
    my ($name, $value);
    foreach $pair (@pairs)
    {
        ($name, $value) = split(/=/, $pair);
        $value =~ tr/+/ /;
        $value =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        $name =~ tr/+/ /;
        $name =~ s/%([a-fA-F0-9][a-fA-F0-9])/pack("C", hex($1))/eg;
        $ret->{$name} .= $ret->{$name} ? "\0$value" : $value;
    }
    return $ret;
}

1;

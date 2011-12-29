package MogileFS::Worker::Monitor;
use strict;
use warnings;

use base 'MogileFS::Worker';
use fields (
            'last_db_update',  # devid -> time.  update db less often than poll interval.
            'last_test_write', # devid -> time.  time we last tried writing to a device.
            'skip_host',       # hostid -> 1 if already noted dead (reset every loop)
            'seen_hosts',      # IP -> 1 (reset every loop)
            'ua',              # LWP::UserAgent for checking usage files
            'iow',             # MogileFS::IOStatWatcher object
            'prev_data',       # DB data from previous run
            'devutil',         # Running tally of device utilization
            'events',          # Queue of state events
            );

use Danga::Socket 1.56;
use MogileFS::Config;
use MogileFS::Util qw(error debug encode_url_args);
use MogileFS::IOStatWatcher;
use MogileFS::Server;

use constant UPDATE_DB_EVERY => 15;

sub new {
    my ($class, $psock) = @_;
    my $self = fields::new($class);
    $self->SUPER::new($psock);

    $self->{last_db_update}  = {};
    $self->{last_test_write} = {};
    $self->{iow}             = MogileFS::IOStatWatcher->new;
    $self->{prev_data}       = { domain => {}, class => {}, host => {},
        device => {} };
    $self->{devutil}         = { cur => {}, prev => {} };
    $self->{events}          = [];
    return $self;
}

sub watchdog_timeout {
    30;
}

sub cache_refresh {
    my $self = shift;

    debug("Monitor running; checking DB for updates");
    $self->validate_dbh;

    my $db_data   = $self->grab_all_data;

    # Stack diffs to ship back later
    $self->diff_data($db_data);

    $self->send_events_to_parent;
}

sub usage_refresh {
    my $self = shift;

    debug("Monitor running; scanning usage files");
    $self->validate_dbh;

    $self->{skip_host}  = {};  # hostid -> 1 if already noted dead.
    $self->{seen_hosts} = {}; # IP -> 1

    my $dev_factory = MogileFS::Factory::Device->get_factory();

    my $cur_iow = {};
    # Run check_devices to test host/devs. diff against old values.
    for my $dev ($dev_factory->get_all) {
        if (my $state = $self->is_iow_diff($dev)) {
            $self->state_event('device', $dev->id, {utilization => $state});
        }
        $cur_iow->{$dev->id} = $self->{devutil}->{cur}->{$dev->id};
        next if $self->{skip_host}{$dev->hostid};
        $self->check_device($dev) if $dev->dstate->should_monitor;
        $self->still_alive; # Ping parent if needed so we don't time out
                            # given lots of devices.
    }

    $self->{devutil}->{prev} = $cur_iow;
    # Set the IOWatcher hosts (once old monitor code has been disabled)

    $self->send_events_to_parent;

    $self->{iow}->set_hosts(keys %{$self->{seen_hosts}});
}

sub work {
    my $self = shift;

    # we just forked from our parent process, also using Danga::Socket,
    # so we need to lose all that state and start afresh.
    Danga::Socket->Reset;

    my $iow = $self->{iow};
    $iow->on_stats(sub {
        my ($hostname, $stats) = @_;

        while (my ($devid, $util) = each %$stats) {
            # Lets not propagate devices that we accidentally find.
            # This does hit the DB every time a device does not exist, so
            # perhaps should add negative caching in the future.
            $self->{devutil}->{cur}->{$devid} = $util;
            my $dev = Mgd::device_factory()->get_by_id($devid);
            next unless $dev;
            $dev->set_observed_utilization($util);
        }
    });

    # We announce "monitor_just_ran" every time the device checks are run, but
    # only if the DB has been checked inbetween.
    my $db_monitor_ran = 0;

    my $db_monitor;
    $db_monitor = sub {
        $self->parent_ping;
        $self->cache_refresh;
        $db_monitor_ran++;
        Danga::Socket->AddTimer(4, $db_monitor);
    };

    $db_monitor->();
    $self->read_from_parent;

    my $main_monitor;
    $main_monitor = sub {
        $self->parent_ping;
        $self->usage_refresh;
        if ($db_monitor_ran) {
            $self->send_to_parent(":monitor_just_ran");
            $db_monitor_ran = 0;
        }
        Danga::Socket->AddTimer(2.5, $main_monitor);
    };

    $main_monitor->();
    Danga::Socket->AddOtherFds($self->psock_fd, sub{ $self->read_from_parent });
    Danga::Socket->EventLoop;
}

sub process_line {
    my MogileFS::Worker::Monitor $self = shift;
    my $lineref = shift;
    if ($$lineref =~ /^:refresh_monitor$/) {
        $self->cache_refresh;
        $self->usage_refresh;
        $self->send_to_parent(":monitor_just_ran");
        return 1;
    }
    return 0;
}

# --------------------------------------------------------------------------

# Flattens and flips events up to the parent. Can be huge on startup!
# Events: set type foo=bar&baz=quux
# remove type id
# setstate type id foo=bar&baz=quux
# Combined: ev_mode=set&ev_type=device&foo=bar
# ev_mode=setstate&ev_type=device&ev_id=1&foo=bar
sub send_events_to_parent {
    my $self = shift;
    my @flat = ();
    for my $ev (@{$self->{events}}) {
        my ($mode, $type, $args) = @$ev;
        $args->{ev_mode} = $mode;
        $args->{ev_type} = $type;
        push(@flat, encode_url_args($args));
    }
    return unless @flat;
    $self->{events} = [];
    # TODO: Maybe wasting too much CPU building this debug line every time...
    debug("sending state changes " . join(' ', ':monitor_events', @flat), 2);
    $self->send_to_parent(join(' ', ':monitor_events', @flat));
}

sub add_event {
    push(@{$_[0]->{events}}, $_[1]);
}

sub set_event { 
    # Allow callers to use shorthand
    $_[3]->{ev_id} = $_[2];
    $_[0]->add_event(['set', $_[1], $_[3]]); 
}
sub remove_event { $_[0]->add_event(['remove', $_[1], { ev_id => $_[2] }]); }
sub state_event {
    $_[3]->{ev_id} = $_[2];
    $_[0]->add_event(['setstate', $_[1], $_[3]]);
}

sub is_iow_diff {
    my ($self, $dev) = @_;
    my $devid = $dev->id;
    my $p = $self->{devutil}->{prev}->{$devid};
    my $c = $self->{devutil}->{cur}->{$devid};
    if ( ! defined $p || $p ne $c ) {
        return $c;
    }
    return undef;
}

sub diff_data {
    my ($self, $db_data) = @_;

    my $new_data  = {};
    my $prev_data = $self->{prev_data};
    for my $type (keys %{$db_data}) {
        my $d_data = $db_data->{$type};
        my $p_data = $prev_data->{$type};
        my $n_data = {};

        for my $item (@{$d_data}) {
            my $id = $type eq 'domain' ? $item->{dmid}
                : $type eq 'class'     ? $item->{dmid} . '-' . $item->{classid}
                : $type eq 'host'      ? $item->{hostid}
                : $type eq 'device'    ? $item->{devid} : die "Unknown type";
            my $old = delete $p_data->{$id};
            # Special case: for devices, we don't care if mb_asof changes.
            # FIXME: Change the grab routine (or filter there?).
            delete $item->{mb_asof} if $type eq 'device';
            if (!$old || $self->diff_hash($old, $item)) {
                $self->set_event($type, $id, { %$item });
            }
            $n_data->{$id} = $item;
        }
        for my $id (keys %{$p_data}) {
            $self->remove_event($type, $id);
        }

        $new_data->{$type} = $n_data;
    }
    $self->{prev_data} = $new_data;
}

# returns 1 if the hashes are different.
sub diff_hash {
    my ($self, $old, $new) = @_;

    my %keys = ();
    map { $keys{$_}++ } keys %$old, keys %$new;
    for my $k (keys %keys) {
        return 1 if (exists $old->{$k} && ! exists $new->{$k});
        return 1 if (exists $new->{$k} && ! exists $old->{$k});
        return 1 if (defined $old->{$k} && ! defined $new->{$k});
        return 1 if (defined $new->{$k} && ! defined $old->{$k});
        next     if (! defined $new->{$k} && ! defined $old->{$k});
        return 1 if ($old->{$k} ne $new->{$k});
    }
    return 0;
}

sub grab_all_data {
    my $self = shift;
    my $sto  = Mgd::get_store();

    # Normalize the domain data to the rest to simplify the differ.
    # FIXME: Once new objects are swapped in, fix the original
    my %dom = $sto->get_all_domains;
    my @fixed_dom = ();
    while (my ($name, $id) = each %dom) {
        push(@fixed_dom, { namespace => $name, dmid => $id });
    }
    my %ret = ( domain => \@fixed_dom,
        class  => [$sto->get_all_classes],
        host   => [$sto->get_all_hosts],
        device => [$sto->get_all_devices], );
    return \%ret;
}

sub ua {
    my $self = shift;
    return $self->{ua} ||= LWP::UserAgent->new(
                                               timeout    => MogileFS::Config->config('conn_timeout') || 2,
                                               keep_alive => 20,
                                               );
}

sub check_device {
    my ($self, $dev) = @_;

    my $devid = $dev->id;
    my $host  = $dev->host;

    my $port     = $host->http_port;
    my $get_port = $host->http_get_port; #  || $port;
    my $hostip   = $host->ip;
    my $url      = $dev->usage_url;

    $self->{seen_hosts}{$hostip} = 1;

    # now try to get the data with a short timeout
    my $timeout = MogileFS::Config->config('conn_timeout') || 2;
    my $start_time = Time::HiRes::time();

    my $ua       = $self->ua;
    my $response = $ua->get($url);
    my $res_time = Time::HiRes::time();

    $hostip ||= 'unknown';
    $get_port ||= 'unknown';
    $devid ||= 'unknown';
    $timeout ||= 'unknown';
    $url ||= 'unknown';
    unless ($response->is_success) {
        my $failed_after = $res_time - $start_time;
        if ($failed_after < 0.5) {
            $self->state_event('device', $dev->id, {observed_state => 'unreachable'})
                if (!$dev->observed_unreachable);
            error("Port $get_port not listening on $hostip ($url)?  Error was: " . $response->status_line);
        } else {
            $failed_after = sprintf("%.02f", $failed_after);
            $self->state_event('host', $dev->hostid, {observed_state => 'unreachable'})
                if (!$host->observed_unreachable);
            $self->{skip_host}{$dev->hostid} = 1;
            error("Timeout contacting $hostip dev $devid ($url):  took $failed_after seconds out of $timeout allowed");
        }
        return;
    }

    # at this point we can reach the host
    $self->state_event('host', $dev->hostid, {observed_state => 'reachable'})
        if (!$host->observed_reachable);
    $self->{iow}->restart_monitoring_if_needed($hostip);

    my %stats;
    my $data = $response->content;
    foreach (split(/\r?\n/, $data)) {
        next unless /^(\w+)\s*:\s*(.+)$/;
        $stats{$1} = $2;
    }

    my ($used, $total) = ($stats{used}, $stats{total});
    unless ($used && $total) {
        $used  = "<undef>" unless defined $used;
        $total = "<undef>" unless defined $total;
        my $clen = length($data || "");
        error("dev$devid reports used = $used, total = $total, content-length: $clen, error?");
        return;
    }

    # only update database every ~15 seconds per device
    my $last_update = $self->{last_db_update}{$dev->id} || 0;
    my $next_update = $last_update + UPDATE_DB_EVERY;
    my $now = time();
    if ($now >= $next_update) {
        Mgd::get_store()->update_device_usage(mb_total => int($total / 1024),
                                              mb_used  => int($used / 1024),
                                              devid    => $devid);
        $self->{last_db_update}{$devid} = $now;
    }

    # next if we're not going to try this now
    return if ($self->{last_test_write}{$devid} || 0) + UPDATE_DB_EVERY > $now;
    $self->{last_test_write}{$devid} = $now;

    unless ($dev->can_delete_from) {
        # we should not try to write on readonly devices because it can be # mounted as RO.
        $self->state_event('device', $devid, {observed_state => 'readable'})
            if (!$dev->observed_readable);
        debug("dev$devid: used = $used, total = $total, writeable = 0");
        return;
    }
    # now we want to check if this device is writeable

    # first, create the test-write directory.  this will return
    # immediately after the first time, as the 'create_directory'
    # function caches what it's already created.
    $dev->create_directory("/dev$devid/test-write");

    my $num = int(rand 100);  # this was "$$-$now" before, but we don't yet have a cleaner in mogstored for these files
    my $puturl = "http://$hostip:$port/dev$devid/test-write/test-write-$num";
    my $content = "time=$now rand=$num";
    my $req = HTTP::Request->new(PUT => $puturl);
    $req->content($content);

    # TODO: guard against race-conditions with double-check on failure

    # now, depending on what happens
    my $resp = $ua->request($req);
    if ($resp->is_success) {
        # now let's get it back to verify; note we use the get_port to verify that
        # the distinction works (if we have one)
        my $geturl = "http://$hostip:$get_port/dev$devid/test-write/test-write-$num";
        my $testwrite = $ua->get($geturl);

        # if success and the content matches, mark it writeable
        if ($testwrite->is_success && $testwrite->content eq $content) {
            $self->state_event('device', $devid, {observed_state => 'writeable'})
                if (!$dev->observed_writeable);
            debug("dev$devid: used = $used, total = $total, writeable = 1");
            return;
        }
    }

    # if we fall through to here, then we know that something is not so good, so mark it readable
    # which is guaranteed given we even tested writeability
    $self->state_event('device', $devid, {observed_state => 'readable'})
        if (!$dev->observed_readable);
    debug("dev$devid: used = $used, total = $total, writeable = 0");
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:

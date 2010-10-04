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
            );

use Danga::Socket 1.56;
use MogileFS::Config;
use MogileFS::Util qw(error debug);
use MogileFS::IOStatWatcher;

use constant UPDATE_DB_EVERY => 15;

sub new {
    my ($class, $psock) = @_;
    my $self = fields::new($class);
    $self->SUPER::new($psock);

    $self->{last_db_update}  = {};
    $self->{last_test_write} = {};
    $self->{iow}             = MogileFS::IOStatWatcher->new;
    return $self;
}

sub watchdog_timeout {
    30;
}

sub work {
    my $self = shift;

    # we just forked from our parent process, also using Danga::Socket,
    # so we need to lose all that state and start afresh.
    Danga::Socket->Reset;

    my $iow = $self->{iow};
    $iow->on_stats(sub {
        my ($hostname, $stats) = @_;

        while (my ($devid, $devstats) = each %$stats) {
            # Lets not propagate devices that we accidentally find.
            # This does hit the DB every time a device does not exist, so
            # perhaps should add negative caching in the future.
            my $dev = MogileFS::Device->of_devid($devid);
            next unless $dev->exists;

            $dev->set_observed_await($devstats->{'await'});
            $dev->set_observed_svctm($devstats->{'svctm'});
            $dev->set_observed_utilization($devstats->{'util'});
        }
    });

    my $main_monitor;
    $main_monitor = sub {
        $self->parent_ping;

        # get db and note we're starting a run
        debug("Monitor running; scanning usage files");
        $self->validate_dbh;

        $self->{skip_host}  = {};  # hostid -> 1 if already noted dead.
        $self->{seen_hosts} = {}; # IP -> 1

        # now iterate over devices
        MogileFS::Device->invalidate_cache;
        MogileFS::Host->invalidate_cache;

        foreach my $dev (MogileFS::Device->devices) {
            next unless $dev->dstate->should_monitor;
            next if $self->{skip_host}{$dev->hostid};
            $self->check_device($dev);
        }

        $iow->set_hosts(keys %{$self->{seen_hosts}});
        $self->send_to_parent(":monitor_just_ran");

        # Make sure we sleep for at least 2.5 seconds before running again.
        # If there's a die above, the monitor will be restarted.
        Danga::Socket->AddTimer(2.5, $main_monitor);
    };

    $main_monitor->();
    Danga::Socket->EventLoop;
}

# --------------------------------------------------------------------------

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
            $self->broadcast_device_unreachable($dev->id);
            error("Port $get_port not listening on $hostip ($url)?  Error was: " . $response->status_line);
        } else {
            $failed_after = sprintf("%.02f", $failed_after);
            $self->broadcast_host_unreachable($dev->hostid);
            $self->{skip_host}{$dev->hostid} = 1;
            error("Timeout contacting $hostip dev $devid ($url):  took $failed_after seconds out of $timeout allowed");
        }
        return;
    }

    # at this point we can reach the host
    $self->broadcast_host_reachable($dev->hostid);
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
            $self->broadcast_device_writeable($devid);
            debug("dev$devid: used = $used, total = $total, writeable = 1");
            return;
        }
    }

    # if we fall through to here, then we know that something is not so good, so mark it readable
    # which is guaranteed given we even tested writeability
    $self->broadcast_device_readable($devid);
    debug("dev$devid: used = $used, total = $total, writeable = 0");
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:

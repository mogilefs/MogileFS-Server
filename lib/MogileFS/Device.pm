package MogileFS::Device;
use strict;
use warnings;
use Carp qw(croak);
use MogileFS::Config qw(DEVICE_SUMMARY_CACHE_TIMEOUT);
use MogileFS::Util qw(okay_args device_state error);

BEGIN {
    my $testing = $ENV{TESTING} ? 1 : 0;
    eval "sub TESTING () { $testing }";
}

my %singleton;      # devid -> instance
my $last_load = 0;  # unixtime we last reloaded devices from database
my $all_loaded = 0; # bool: have we loaded all the devices?

# throws "dup" on duplicate devid.  returns new MogileFS::Device object on success.
# %args include devid, hostid, and status (in (alive, down, readonly))
sub create {
    my ($pkg, %args) = @_;
    okay_args(\%args, qw(devid hostid status));
    my $devid = Mgd::get_store()->create_device(@args{qw(devid hostid status)});
    MogileFS::Device->invalidate_cache;
    return $pkg->of_devid($devid);
}

sub of_devid {
    my ($class, $devid) = @_;
    croak("Invalid devid") unless $devid;
    return $singleton{$devid} ||= bless {
        devid    => $devid,
        no_mkcol => 0,
        _loaded  => 0,
    }, $class;
}

sub t_wipe_singletons {
    %singleton = ();
    $last_load = time();  # fake it
}

sub t_init {
    my ($self, $hostid, $state) = @_;
    $self->{_loaded} = 1;

    my $dstate = device_state($state) or
        die "Bogus state";

    $self->{hostid}  = $hostid;
    $self->{status}  = $state;
    $self->{observed_state} = "writeable";

    # say it's 10% full, of 1GB
    $self->{mb_total} = 1000;
    $self->{mb_used}  = 100;
}

sub from_devid_and_hostname {
    my ($class, $devid, $hostname) = @_;
    my $dev = MogileFS::Device->of_devid($devid)
        or return undef;
    return undef unless $dev->exists;
    my $host = $dev->host;
    return undef
        unless $host && $host->exists && $host->hostname eq $hostname;
    return $dev;
}

sub vivify_directories {
    my ($class, $path) = @_;

    # $path is something like:
    #    http://10.0.0.26:7500/dev2/0/000/148/0000148056.fid

    # three directories we'll want to make:
    #    http://10.0.0.26:7500/dev2/0
    #    http://10.0.0.26:7500/dev2/0/000
    #    http://10.0.0.26:7500/dev2/0/000/148

    croak "non-HTTP mode no longer supported" unless $path =~ /^http/;
    return 0 unless $path =~ m!/dev(\d+)/(\d+)/(\d\d\d)/(\d\d\d)/\d+\.fid$!;
    my ($devid, $p1, $p2, $p3) = ($1, $2, $3, $4);

    my $dev = MogileFS::Device->of_devid($devid);
    return 0 unless $dev->exists;

    $dev->create_directory("/dev$devid/$p1");
    $dev->create_directory("/dev$devid/$p1/$p2");
    $dev->create_directory("/dev$devid/$p1/$p2/$p3");
}

# returns array of all MogileFS::Device objects
sub devices {
    my $class = shift;
    MogileFS::Device->check_cache;
    return values %singleton;
}

# returns hashref of devid -> $device_obj
# you're allowed to mess with this returned hashref
sub map {
    my $class = shift;
    my $ret = {};
    foreach my $d (MogileFS::Device->devices) {
        $ret->{$d->id} = $d;
    }
    return $ret;
}

sub reload_devices {
    my $class = shift;

    # mark them all invalid for now, until they're reloaded
    foreach my $dev (values %singleton) {
        $dev->{_loaded} = 0;
    }

    MogileFS::Host->check_cache;

    my $sto = Mgd::get_store();
    foreach my $row ($sto->get_all_devices) {
        my $dev =
            MogileFS::Device->of_devid($row->{devid});
        $dev->absorb_dbrow($row);
    }

    # get rid of ones that could've gone away:
    foreach my $devid (keys %singleton) {
        my $dev = $singleton{$devid};
        delete $singleton{$devid} unless $dev->{_loaded}
    }

    $all_loaded = 1;
    $last_load  = time();
}

sub invalidate_cache {
    my $class = shift;

    # so next time it's invalid and won't be used old
    $last_load    = 0;
    $all_loaded   = 0;
    $_->{_loaded} = 0 foreach values %singleton;

    if (my $worker = MogileFS::ProcManager->is_child) {
        $worker->invalidate_meta("device");
    }
}

sub check_cache {
    my $class = shift;
    my $now = $Mgd::nowish || time();
    return if $last_load > $now - DEVICE_SUMMARY_CACHE_TIMEOUT;
    MogileFS::Device->reload_devices;
}

# --------------------------------------------------------------------------

sub devid { return $_[0]{devid} }
sub id    { return $_[0]{devid} }

sub absorb_dbrow {
    my ($dev, $hashref) = @_;
    foreach my $k (qw(hostid mb_total mb_used mb_asof status weight)) {
        $dev->{$k} = $hashref->{$k};
    }

    $dev->{$_} ||= 0 foreach qw(mb_total mb_used mb_asof);

    my $host = MogileFS::Host->of_hostid($dev->{hostid});
    if ($host && $host->exists) {
        my $host_status = $host->status;
        die "No status" unless $host_status =~ /^\w+$/;
        # FIXME: not sure I like this, changing the in-memory version
        # of the configured status is.  I'd rather this be calculated
        # in an accessor.
        if ($dev->{status} eq 'alive' && $host_status ne 'alive') {
            $dev->{status} = "down"
        }
    } else {
        if ($dev->{status} eq "dead") {
            # ignore dead devices without hosts.  not a big deal.
        } else {
            die "No host for dev $dev->{devid} (host $dev->{hostid})";
        }
    }

    $dev->{_loaded} = 1;
}

# returns 0 if not known, else [0,1]
sub percent_free {
    my $dev = shift;
    $dev->_load;
    return 0 unless $dev->{mb_total} && defined $dev->{mb_used};
    return 1 - ($dev->{mb_used} / $dev->{mb_total});
}

# returns undef if not known, else [0,1]
sub percent_full {
    my $dev = shift;
    $dev->_load;
    return undef unless $dev->{mb_total} && defined $dev->{mb_used};
    return $dev->{mb_used} / $dev->{mb_total};
}

our $no_broadcast = 0;

sub set_observed_await {
    my ($dev, $await) = @_;
    $dev->{await} = $await;
    my $devid = $dev->id;

    return if $no_broadcast;

    my $worker = MogileFS::ProcManager->is_child or return;
    $worker->send_to_parent(":set_dev_await $devid $await");
}

sub set_observed_svctm {
    my ($dev, $svctm) = @_;
    $dev->{svctm} = $svctm;
    my $devid = $dev->id;

    return if $no_broadcast;

    my $worker = MogileFS::ProcManager->is_child or return;
    $worker->send_to_parent(":set_dev_svctm $devid $svctm");
}

sub set_observed_utilization {
    my ($dev, $util) = @_;
    $dev->{utilization} = $util;
    my $devid = $dev->id;

    return if $no_broadcast;

    my $worker = MogileFS::ProcManager->is_child or return;
    $worker->send_to_parent(":set_dev_utilization $devid $util");
}

sub observed_await {
    my ($dev) = @_;

    if (TESTING) {
        my $weight_varname = 'T_FAKE_IO_DEV' . $dev->id;
        return $ENV{$weight_varname} if defined $ENV{$weight_varname};
    }

    return $dev->{await};
}

sub observed_svctm {
    my ($dev) = @_;

    if (TESTING) {
        my $weight_varname = 'T_FAKE_IO_DEV' . $dev->id;
        return $ENV{$weight_varname} if defined $ENV{$weight_varname};
    }

    return $dev->{svctm};
}

sub observed_utilization {
    my ($dev) = @_;

    if (TESTING) {
        my $weight_varname = 'T_FAKE_IO_DEV' . $dev->id;
        return $ENV{$weight_varname} if defined $ENV{$weight_varname};
    }

    return $dev->{utilization};
}

sub set_observed_state {
    my ($dev, $state) = @_;
    croak "set_observed_state() with invalid device state '$state', valid: writeable, readable, unreachable"
        if $state !~ /^(?:writeable|readable|unreachable)$/;
    $dev->{observed_state} = $state;
}

sub observed_writeable {
    my $dev = shift;
    return 0 unless $dev->{observed_state} && $dev->{observed_state} eq "writeable";
    my $host = $dev->host
        or return 0;
    return 0 unless $host->observed_reachable;
    return 1;
}

sub observed_readable {
    my $dev = shift;
    return $dev->{observed_state} && $dev->{observed_state} eq "readable";
}

sub observed_unreachable {
    my $dev = shift;
    return $dev->{observed_state} && $dev->{observed_state} eq "unreachable";
}

# returns status as a string (SEE ALSO: dstate, returns DeviceState object,
# which knows the traits/capabilities of that named state)
sub status {
    my $dev = shift;
    $dev->_load;
    return $dev->{status};
}

sub weight {
    my $dev = shift;
    $dev->_load;
    return $dev->{weight};
}

sub dstate {
    my $ds = device_state($_[0]->status);
    return $ds if $ds;
    error("dev$_[0]->{devid} has bogus status '$_[0]->{status}', pretending 'down'");
    return device_state("down");
}

sub can_delete_from {
    my $self = shift;
    return $self->dstate->can_delete_from;
}

sub can_read_from {
    my $self = shift;
    return $self->dstate->can_read_from;
}

sub should_get_new_files {
    my $dev    = shift;
    my $dstate = $dev->dstate;

    return 0 unless $dstate->should_get_new_files;
    return 0 unless $dev->observed_writeable;
    return 0 unless $dev->host->should_get_new_files;

    # have enough disk space? (default: 100MB)
    my $min_free = MogileFS->config("min_free_space");
    return 0 if $dev->{mb_total} &&
        $dev->mb_free < $min_free;

    return 1;
}

sub mb_free {
    my $self = shift;
    return $self->{mb_total} - $self->{mb_used};
}

sub mb_used {
    return $_[0]->{mb_used};
}

# currently the same policy, but leaving it open for differences later.
sub should_get_replicated_files {
    my $dev = shift;
    return $dev->should_get_new_files;
}

sub not_on_hosts {
    my ($dev, @hosts) = @_;
    my @hostids   = map { ref($_) ? $_->hostid : $_ } @hosts;
    my $my_hostid = $dev->hostid;
    return (grep { $my_hostid == $_ } @hostids) ? 0 : 1;
}

sub exists {
    my $dev = shift;
    $dev->_try_load;
    return $dev->{_loaded};
}

sub host {
    my $dev = shift;
    return MogileFS::Host->of_hostid($dev->hostid);
}

sub hostid {
    my $dev = shift;
    $dev->_load;
    return $dev->{hostid};
}

sub doesnt_know_mkcol {
    my $self = shift;
    # TODO: forget this periodically?  maybe whenever host/device is observed down?
    # in case webserver changes.
    return $self->{no_mkcol};
}

my %dir_made;  # /dev<n>/path -> $time
my $dir_made_lastclean = 0;
# returns 1 on success, 0 on failure
sub create_directory {
    my ($self, $uri) = @_;
    return 1 if $self->doesnt_know_mkcol;

    # rfc2518 says we "should" use a trailing slash. Some servers
    # (nginx) appears to require it.
    $uri .= '/' unless $uri =~ m!/$!;

    return 1 if $dir_made{$uri};

    my $hostid = $self->hostid;
    my $host   = $self->host;
    my $hostip = $host->ip        or return 0;
    my $port   = $host->http_port or return 0;
    my $peer = "$hostip:$port";

    my $sock = IO::Socket::INET->new(PeerAddr => $peer, Timeout => 1)
        or return 0;

    print $sock "MKCOL $uri HTTP/1.0\r\n".
        "Content-Length: 0\r\n\r\n";

    my $ans = <$sock>;

    # if they don't support this method, remember that
    if ($ans && $ans =~ m!HTTP/1\.[01] (400|501)!) {
        $self->{no_mkcol} = 1;
        # TODO: move this into method on device, which propagates to parent
        # and also receive from parent.  so all query workers share this knowledge
        return 1;
    }

    return 0 unless $ans && $ans =~ m!^HTTP/1.[01] 2\d\d!;

    my $now = time();
    $dir_made{$uri} = $now;

    # cleanup %dir_made occasionally.
    my $clean_interval = 300;  # every 5 minutes.
    if ($dir_made_lastclean < $now - $clean_interval) {
        $dir_made_lastclean = $now;
        foreach my $k (keys %dir_made) {
            delete $dir_made{$k} if $dir_made{$k} < $now - 3600;
        }
    }
    return 1;
}

sub fid_list {
    my ($self, %opts) = @_;
    my $limit = delete $opts{limit};
    croak("No limit specified") unless $limit && $limit =~ /^\d+$/;
    croak("Unknown options to fid_list") if %opts;

    my $sto = Mgd::get_store();
    my $fidids = $sto->get_fidids_by_device($self->devid, $limit);
    return map {
        MogileFS::FID->new($_)
    } @{$fidids || []};
}

sub fid_chunks {
    my ($self, %opts) = @_;

    my $sto = Mgd::get_store();
    # storage function does validation.
    my $fidids = $sto->get_fidid_chunks_by_device(devid => $self->devid, %opts);
    return map {
        MogileFS::FID->new($_)
    } @{$fidids || []};
}

sub forget_about {
    my ($dev, $fid) = @_;
    Mgd::get_store()->remove_fidid_from_devid($fid->id, $dev->id);
    return 1;
}

sub usage_url {
    my $dev = shift;
    my $host     = $dev->host;
    my $get_port = $host->http_get_port;
    my $hostip   = $host->ip;
    return "http://$hostip:$get_port/dev$dev->{devid}/usage";
}

sub overview_hashref {
    my $dev = shift;
    $dev->_load;

    my $ret = {};
    foreach my $k (qw(devid hostid status weight observed_state
                      mb_total mb_used mb_asof await svctm utilization)) {
        $ret->{$k} = $dev->{$k};
    }
    $ret->{mb_free} = $dev->mb_free;
    return $ret;
}

sub set_weight {
    my ($dev, $weight) = @_;
    my $sto = Mgd::get_store();
    $sto->set_device_weight($dev->id, $weight);
    MogileFS::Device->invalidate_cache;
}

sub set_state {
    my ($dev, $state) = @_;
    my $dstate = device_state($state) or
        die "Bogus state";
    my $sto = Mgd::get_store();
    $sto->set_device_state($dev->id, $state);
    MogileFS::Device->invalidate_cache;

    # wake a reaper process up from sleep to get started as soon as possible
    # on re-replication
    MogileFS::ProcManager->wake_a("reaper") if $dstate->should_wake_reaper;
}

# given the current state, can this device transition into the provided $newstate?
sub can_change_to_state {
    my ($self, $newstate) = @_;
    # don't allow dead -> alive transitions.  (yes, still possible
    # to go dead -> readonly -> alive to bypass this, but this is
    # all more of a user-education thing than an absolute policy)
    return 0 if $self->dstate->is_perm_dead && $newstate eq 'alive';
    return 1;
}

# --------------------------------------------------------------------------

sub _load {
    return if $_[0]{_loaded};
    MogileFS::Device->reload_devices;
    return if $_[0]{_loaded};
    my $dev = shift;
    croak "Device $dev->{devid} doesn't exist.\n";
}

sub _try_load {
    return if $_[0]{_loaded};
    MogileFS::Device->reload_devices;
}

1;

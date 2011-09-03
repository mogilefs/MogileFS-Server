package MogileFS::Rebalance;
use strict;
use warnings;
use Carp qw(croak);
use List::Util ();
use MogileFS::Server ();

# Note: The filters aren't written for maximum speed, as they're not likely
# in the slow path. They're supposed to be readable/extensible. Please don't
# cram them down unless you have to.
# TODO: allow filters to note by dev why they were filtered in/out, and return
# that info for DEBUG display.
# TODO: Add "debug trace" lines to most functions. "choosing sdev to work on",
# etc.
# TODO: tally into the state how many fids/size/etc it's done so far.
# TODO: should track old device state and return to it. Overall this is
# probably better fit by switching "device state" to a set of "device flags",
# so we can disable specifically "stop getting new files" while we work :(

# Default policy structure are all of these fields.
# A minimum set of fields should be defined for a policy to be valid..
my %default_policy = (
    # source
    from_all_devs => 1,
    from_hosts => [],           # host ids.
    from_devices => [],         # dev ids.
    from_percent_used => undef, # 0.nn * 100
    from_percent_free => undef,
    from_space_used => undef,
    from_space_free => undef,
    fid_age => 'old',           # old|new
    limit_type => 'device',     # global|device
    limit_by => 'none',         # size|count|percent|none
    limit => undef,             # 100g|10%|5000
    # target
    to_all_devs => 1,
    to_hosts => [],
    to_devices => [],
    to_percent_used => undef,
    to_percent_free => undef,
    to_space_used => undef,
    to_space_free => undef,
    not_to_hosts => [],
    not_to_devices => [],
    use_dest_devs => 'all',     # all|N (list up to N devices to rep pol)
    leave_in_drain_mode => 0,
);

# State policy example
my %default_state = (
    completed_devs => [],
    source_devs => [],
    sdev_current => 0,
    sdev_lastfid => 0,
    sdev_limit => 0,
    limit => 0,
    fids_queued => 0,
    bytes_queued => 0,
    time_started => 0,
    time_finished => 0,
    time_stopped => 0,
);

sub new {
    my $class  = shift;
    my $policy = shift || "";
    my $state  = shift || '';

    # Validate policy here?
    my $self = bless {
        policy => '',
        state => '',
    }, $class;

    $self->policy($policy) if $policy;
    $self->load_state($state) if $state;

    return $self;
}

sub init {
    my $self = shift;
    my $devs = shift;

    croak "policy object already initialized" if $self->{state};
    croak "please pass in devices to filter" unless $devs && ref($devs);
    my %state = %default_state;

    # If we don't have an initial source device list, discover them.
    # Used to filter destination devices later.
    $state{source_devs} = $self->filter_source_devices($devs);
    $state{time_started} = time();
    $self->{state} = \%state;
}

sub stop {
    my $self = shift;
    my $p    = $self->{policy};
    my $s    = $self->{state};
    my $sdev = $self->{sdev_current};
    unless ($p->{leave_in_drain_mode}) {
        Mgd::get_store()->set_device_state($sdev, 'alive') if $sdev;
    }
    $s->{time_stopped} = time();
}

sub finish {
    my $self = shift;
    my $s    = $self->{state};
    $s->{time_finished} = time();
}

# Resume from saved as_string state.
sub load_state {
    my $self  = shift;
    my $state = shift;
    my $state_parsed = $self->_parse_settings($state, \%default_state);
    # TODO: validate state?
    $self->{state} = $state_parsed;
}

# Call as_string()? merge into load_state as "state"?
sub save_state {
    my $self = shift;
    return $self->_save_settings($self->{state});
}

sub source_devices {
    my $self = shift;
    return $self->{source_devs};
}

sub policy {
    my $self = shift;
    unless (@_) {
        # TODO: serialize it or pass a structure?
        return $self->{policy};
    }
    my $policy = shift;
    $self->{policy} = $self->_parse_settings($policy, \%default_policy);
    return $self->{policy};
}

sub _save_settings {
    my $self     = shift;
    my $settings = shift;
    my @tosave   = ();
    while (my ($key, $val) = each %{$settings}) {
        # Only ref we support is ARRAY at the mo'...
        if (ref($val) eq 'ARRAY') {
            push(@tosave, $key . '=' . join(',', @$val));
        } else {
            push(@tosave, $key . '=' . $val);
        }
    }
    return join(' ', @tosave);
}

# foo=bar foo2=bar2 foo3=baaz,quux
sub _parse_settings {
    my $self       = shift;
    my $settings   = shift;
    my $constraint = shift || '';
    my %parsed     = ();
    # the constraint also serves as a set of defaults.
    %parsed = %{$constraint} if ($constraint);

    # parse out from a string: key=value key=value
    for my $tuple (split /\s/, $settings) {
        my ($key, $value) = split /=/, $tuple;
        if (index($value, ',') > -1) {
            # ',' is reserved for multivalue types.
            $value = [split /,/, $value];
        }
        # In the future we could do stronger type checking at load
        # time, but for now this will happen at use time :/
        if ($constraint) {
            if (exists $constraint->{$key}) {
                my $c = $constraint->{$key};
                # default says we should be an array.
                if (ref($c) && ref($c) eq 'ARRAY' && !ref($value)) {
                    $parsed{$key} = [$value];
                } else {
                    $parsed{$key} = $value;
                }
            } else {
                croak "Invalid setting $key";
            }
        } else {
            $parsed{$key} = $value;
        }
    }
    return \%parsed;
}

# step through the filters and find the next set of fids to rebalance.
# should $sto be passed in here or should we fetch it ourselves?
# also, should device info be passed in? I think so.
# returning 'undef' means there's nothing left
# returning an empty array means "try again"
sub next_fids_to_rebalance {
    my $self  = shift;
    my $devs  = shift;
    my $sto   = shift;
    my $limit = shift || 100; # random low default.
    # Balk unless we have a policy or a state?
    my $policy = $self->{policy};
    croak "No policy loaded" unless $policy;
    croak "Must pass in device list" unless $devs;
    croak "Must pass in storage object" unless $sto;
    my $state = $self->{state};

    # If we're not working against a source device, discover one
    my $sdev = $self->_find_source_device($state->{source_devs});
    return undef unless $sdev;
    $sdev = Mgd::device_factory()->get_by_id($sdev);
    my $filtered_destdevs = $self->filter_dest_devices($devs);

    croak("rebalance cannot find suitable destination devices")
        unless (@$filtered_destdevs);

    my @fids = $sdev->fid_chunks(age => $policy->{fid_age},
        fidid => $state->{sdev_lastfid},
        limit => $limit);
    # We'll wait until the next cycle to find a new sdev.
    if (! @fids || ! $self->_check_limits) {
        $self->_finish_source_device;
        return [];
    }

    # In both old or new cases, the "last" fid in the list is correct.
    $state->{sdev_lastfid} = $fids[-1]->id;

    # TODO: create a filterset for $fid settings. filesize, class, domain, etc.
    my @devfids = ();
    for my $fid (@fids) {
        # count the fid or size against device limit.
        next unless $fid->exists;
        $self->_check_limits($fid) or next;
        my $destdevs = $self->_choose_dest_devs($fid, $filtered_destdevs);
        # Update internal stats.
        $state->{fids_queued}++;
        $state->{bytes_queued} += $fid->length;
        push(@devfids, [$fid->id, $sdev->id, $destdevs]);
    }

    # return block of fiddev combos.
    return \@devfids;
}

# ensure this fid wouldn't overrun a limit.
sub _check_limits {
    my $self = shift;
    my $fid  = shift;
    my $p = $self->{policy};
    my $s = $self->{state};
    return 1 if ($p->{limit_by} eq 'none');

    my $limit;
    if ($p->{limit_type} eq 'global') {
        $limit = \$s->{limit};
    } else {
        $limit = \$s->{sdev_limit};
    }

    if ($p->{limit_by} eq 'count') {
        return $fid ? $$limit-- : $$limit;
    } elsif ($p->{limit_by} eq 'size') {
        if ($fid) {
            if ($fid->length() <= $$limit) {
                $$limit -= $fid->length();
                return 1;
            } else {
                return 0;
            }
        } else {
            if ($$limit < 1024) {
                # Arbitrary "give up if there's less than 1kb in the limit"
                # FIXME: Make this configurable
                return 0;
            } else {
                return 1;
            }
        }
    } else {
        croak("uknown limit_by type");
    }
}

# shuffle the list and return by limit.
# TODO: use the fid->length to ensure we don't send the file to devices
# that can't handle it.
sub _choose_dest_devs {
    my $self          = shift;
    my $fid           = shift;
    my $filtered_devs = shift;
    my $p             = $self->{policy};

    my @shuffled_devs = List::Util::shuffle(@$filtered_devs);
    return \@shuffled_devs if ($p->{use_dest_devs} eq 'all');

    return splice @shuffled_devs, 0, $p->{use_dest_devs};
}

# Iterate through all possible constraints until we have a final list.
# unlike the source list we try this 
sub filter_source_devices {
    my $self = shift;
    my $devs = shift;
    my $policy = $self->{policy};
 
    my @sdevs = ();
    for my $dev (@$devs) {
        next unless $dev->can_delete_from;
        my $id = $dev->id;
        if (@{$policy->{from_devices}}) {
            next unless grep { $_ == $id } @{$policy->{from_devices}};
        }
        if (@{$policy->{from_hosts}}) {
            my $hostid = $dev->hostid;
            next unless grep { $_ == $hostid } @{$policy->{from_hosts}};
        }
        # "at least this much used"
        if ($policy->{from_percent_used}) {
            # returns undef if it doesn't have stats on the device.
            my $full = $dev->percent_full * 100;
            next unless defined $full;
            next unless $full > $policy->{from_percent_used};
        }
        # "at least this much free"
        if ($policy->{from_percent_free}) {
            # returns *0* if lacking stats. Must fix :(
            my $free = $dev->percent_free * 100;
            next unless $free; # hope this never lands at exact zero.
            next unless $free > $policy->{from_percent_free};
        }
        # "at least this much used"
        if ($policy->{from_space_used}) {
            my $used = $dev->mb_used;
            next unless $used && $used > $policy->{from_space_used};
        }
        # "at least this much free"
        if ($policy->{from_space_free}) {
            my $free = $dev->mb_free;
            next unless $free && $free > $policy->{from_space_free};
        }
        push @sdevs, $id;
    }

    return \@sdevs;
}

sub _finish_source_device {
    my $self = shift;
    my $state  = $self->{state};
    my $policy = $self->{policy};
    croak "Not presently working on a source device"
        unless $state->{sdev_current};

    delete $state->{sdev_lastfid};
    delete $state->{sdev_limit};
    my $sdev = delete $state->{sdev_current};
    # Unless the user wants a device to never get new files again (sticking in
    # drain mode), return to alive.
    unless ($policy->{leave_in_drain_mode}) {
        Mgd::get_store()->set_device_state($sdev, 'alive');
    }
    push @{$state->{completed_devs}}, $sdev;
}

# TODO: Be aware of down/unavail devices. temp skip them?
sub _find_source_device {
    my $self  = shift;
    my $sdevs = shift;

    my $state = $self->{state};
    my $p     = $self->{policy};
    unless ($state->{sdev_current}) {
        my $sdev = shift @$sdevs;
        return undef, undef unless $sdev;
        $state->{sdev_current} = $sdev;
        $state->{sdev_lastfid} = 0;
        my $limit;
        if ($p->{limit_type} eq 'device') {
            if ($p->{limit_by} eq 'size') {
                # Parse the size (default in megs?) out into bytes.
                $limit = $self->_human_to_bytes($p->{limit});
            } elsif ($p->{limit_by} eq 'count') {
                $limit = $p->{limit};
            } elsif ($p->{limit_by} eq 'percent') {
                croak("policy size limits by percent are unimplemented");
            } elsif ($p->{limit_by} eq 'none') {
                $limit = 'none';
            }
        }
        # Must mark device in "drain" mode while we work on it.
        Mgd::get_store()->set_device_state($sdev, 'drain');
        $state->{sdev_limit} = $limit;
    }

    return $state->{sdev_current};
}

# FIXME: Move to MogileFS::Util
# take a numeric string with a char suffix and turn it into bytes.
# no suffix means it's already bytes.
sub _human_to_bytes {
    my $self = shift;
    my $num  = shift;

    my ($digits, $type);
    if ($num =~ m/^(\d+)([bkmgtp])?$/i) {
        $digits = $1;
        $type   = lc($2);
    } else {
        croak("Don't know what this number is: " . $num);
    }

    return $digits unless $type || $type eq 'b';
    # Sorry, being cute here :P
    return $digits * (1024 ** index('bkmgtpezy', $type));
}

# Apply policy to destination devices.
sub filter_dest_devices {
    my $self = shift;
    my $devs = shift;
    my $policy = $self->{policy};
    my $state  = $self->{state};

    # skip anything we would source from.
    # FIXME: ends up not skipping stuff out of completed_devs? :/
    my %sdevs = map { $_ => 1 } @{$state->{source_devs}},
        @{$state->{completed_devs}}, $state->{sdev_current};
    my @devs  = grep { ! $sdevs{$_->id} } @$devs;

    my @ddevs = ();
    for my $dev (@devs) {
        next unless $dev->should_get_new_files;
        my $id = $dev->id;
        my $hostid = $dev->hostid;

        if (@{$policy->{to_devices}}) {
            next unless grep { $_ == $id } @{$policy->{to_devices}};
        }
        if (@{$policy->{to_hosts}}) {
            next unless grep { $_ == $hostid } @{$policy->{to_hosts}};
        }
        if (@{$policy->{not_to_devices}}) {
            next if grep { $_ == $id } @{$policy->{not_to_devices}};
        }
        if (@{$policy->{not_to_hosts}}) {
            next if grep { $_ == $hostid } @{$policy->{not_to_hosts}};
        }
        if ($policy->{to_percent_used}) {
            my $full = $dev->percent_full * 100;
            next unless defined $full;
            next unless $full > $policy->{to_percent_used};
        }
        if ($policy->{to_percent_free}) {
            my $free = $dev->percent_free * 100;
            next unless $free; # hope this never lands at exact zero.
            next unless $free > $policy->{to_percent_free};
        }
        if ($policy->{to_space_used}) {
            my $used = $dev->mb_used;
            next unless $used && $used > $policy->{to_space_used};
        }
        if ($policy->{to_space_free}) {
            my $free = $dev->mb_free;
            next unless $free && $free > $policy->{to_space_free};
        }
        push @ddevs, $id;
    }

    return \@ddevs;
}

package MogileFS::ReplicationPolicy::MultipleNetworks;

use strict;
use base 'MogileFS::ReplicationPolicy';
use MogileFS::Util qw(weighted_list);
use MogileFS::ReplicationRequest qw(ALL_GOOD TOO_GOOD TEMP_NO_ANSWER);

my %cache;
my $age;

sub AVOIDNETWORK { return "AVOIDNETWORK"; }

sub new {
    my ($class, $mindevcount) = @_;
    return bless {
        mindevcount => $mindevcount,
    }, $class;
}

sub new_from_policy_args {
    my ($class, $argref) = @_;
    # Note: "MultipleNetworks()" is okay, in which case the 'mindevcount'
    # on the class is used.  (see below)
    $$argref =~ s/^\s* \( \s* (\d*) \s* \) \s*//x
        or die "$class failed to parse args: $$argref";
    return $class->new($1)
}

sub mindevcount { $_[0]{mindevcount} }

sub replicate_to {
    my ($self, %args) = @_;

    my $fid      = delete $args{fid};      # fid scalar to copy
    my $on_devs  = delete $args{on_devs};  # arrayref of device objects
    my $all_devs = delete $args{all_devs}; # hashref of { devid => MogileFS::Device }
    my $failed   = delete $args{failed};   # hashref of { devid => 1 } of failed attempts this round

    # old-style
    my $min      = delete $args{min};
    $min         = $self->{mindevcount} || $min;

    warn "Unknown parameters: " . join(", ", sort keys %args) if %args;
    die "Missing parameters" unless $on_devs && $all_devs && $failed && $fid;

    # number of devices we currently live on
    my $already_on = @$on_devs;

    # a silly special case, bail out early.
    return ALL_GOOD if $min == 1 && $already_on;

    # total disks available which are candidates for having files on them
    my $total_disks = scalar grep { $_->dstate->should_have_files } values %$all_devs;

    # if we have two copies and that's all the disks there are
    # anywhere, be happy enough
    return ALL_GOOD if $already_on >= 2 && $already_on == $total_disks;

    # see which and how many unique hosts/networks we're already on.
    my %on_dev;
    my %on_host;
    my %on_network;
    foreach my $dev (@$on_devs) {
        $on_host{$dev->hostid} = 1;
        $on_dev{$dev->id} = 1;

        my $on_ip = $dev->host->ip;
        if ($on_ip) {
            my $network = network_for_ip($on_ip);
            $on_network{$network->desc} = $network;
        }
    }

    my $uniq_hosts_on       = scalar keys %on_host;
    my $uniq_networks_on    = scalar keys %on_network || 1;

    my ($total_uniq_hosts, $total_uniq_networks) = unique_hosts_and_networks($all_devs);

    # target as many networks as we can, but not more than min
    my $target_networks = ($min < $total_uniq_networks) ? $min : $total_uniq_networks;

    # we're never good if our copies aren't on as many networks as possible
    if (($target_networks / $uniq_networks_on) <= 1) {
        return TOO_GOOD if $uniq_hosts_on >  $min;
        return TOO_GOOD if $uniq_hosts_on == $min && $already_on > $min;

        return ALL_GOOD if $uniq_hosts_on == $min;
        return ALL_GOOD if $uniq_hosts_on >= $total_uniq_hosts && $already_on >= $min;
    }

    # if there are more hosts we're not on yet, we want to exclude devices we're already
    # on from our applicable host search.
    # also exclude hosts on networks we're already on
    my @skip_network = values %on_network;
    my %skip_host; # hostid => 1
    if ($uniq_hosts_on < $total_uniq_hosts) {
        %skip_host = %on_host;

        if (@skip_network) {
            # work out hosts from the devs passed to us
            my %seen_host;
            foreach my $device (values %$all_devs) {
                next if ($seen_host{$device->host->id}++);

                foreach my $disliked_network (@skip_network) {
                    if (($disliked_network->match($device->host->ip)) and
                        (not $skip_host{$device->host->id})) {
                        $skip_host{$device->host->id} = AVOIDNETWORK;
                    }
                }
            }
        }
    }

    my @all_dests = sort {
        $b->percent_free <=> $a->percent_free
    } grep {
        ! $on_dev{$_->devid} &&
        ! $failed->{$_->devid} &&
        $_->should_get_replicated_files
    } values %$all_devs;

    return TEMP_NO_ANSWER unless @all_dests;

    my @ideal         = grep { ! $skip_host{$_->hostid} } @all_dests;
    # wrong network is less desperate than wrong host
    my @network_desp  = grep {   $skip_host{$_->hostid} &&
                                 $skip_host{$_->hostid} eq AVOIDNETWORK } @all_dests;
    my @host_desp     = grep {   $skip_host{$_->hostid} &&
                                 $skip_host{$_->hostid} ne AVOIDNETWORK } @all_dests;

    @ideal        = weighted_list(map { [$_, 100 * $_->percent_free] }
        splice(@ideal, 0, 20));
    @network_desp = weighted_list(map { [$_, 100 * $_->percent_free] }
        splice(@network_desp, 0, 20));
    @host_desp    = weighted_list(map { [$_, 100 * $_->percent_free] }
        splice(@host_desp, 0, 20));

    my @desp = (@network_desp, @host_desp);

    return MogileFS::ReplicationRequest->new(
                                             ideal     => \@ideal,
                                             desperate => \@desp,
                                            );
}

# can't just scalar keys %cache to count networks
# might include networks for which we have no hosts yet
sub unique_hosts_and_networks {
    my ($devs) = @_;

    my %host;
    my %netmask; 
    foreach my $devid (keys %$devs) {
        my $dev = $devs->{$devid};
        next unless $dev->dstate->should_get_repl_files;

        $host{$dev->hostid}++;

        my $ip = $dev->host->ip;
        $netmask{network_for_ip($ip)->desc}++;
    }

    return (scalar keys %host, scalar keys %netmask || 1);
}


{
    my %cache; # '192.168.0.0/24' => Net::Netmask->new2('192.168.0.0/24');
    my $age;   # increments every time we look

    # turn a server ip into a network
    # defaults to /16 ranges
    # this can be overridden with a "zone_$location" setting per network "zone" and
    # a lookup field listing all "zones"
    # e.g.
    # mogadm settings set network_zones location1,location2
    # mogadm settings set zone_location1 192.168.0.0/24
    # mogadm settings set zone_location2 10.0.0.0/24
    # zone names and netmasks must be unique
    sub network_for_ip {
        my ($ip) = @_;

        if (not $ip) { # can happen in testing
            return Net::Netmask->new('default');
        }

        # clear the cache occasionally
        if (($age == 0) or ($age++ > 500)) {
            clear_and_build_cache();
            $age = 1;
        }

        my $network;
        foreach my $zone (keys %cache) {
            if ($cache{$zone}->match($ip)) {
                $network = $cache{$zone};
            }
        }

        if (not $network) { 
            ($network) = ($ip =~ m/(\d+\.\d+)./);
            $network .= '/16'; # default
            $network = Net::Netmask->new2($network);
        }

        return $network;
    }

    sub clear_and_build_cache {
        undef %cache;

        my @zones = split(/\s*,\s*/,MogileFS::Config->server_setting("network_zones"));

        foreach my $zone (@zones) {
            my $netmask = MogileFS::Config->server_setting("zone_".$zone);

            if (not $netmask) {
                warn "couldn't find network_zone <<zone_".$zone.">> check your server settings";
                next;
            }

            if ($cache{$netmask}) {
                warn "duplicate netmask <$netmask> in network zones. check your server settings";
            }

            $cache{$netmask} = Net::Netmask->new2($netmask);

            if (Net::Netmask::errstr()) {
                warn "couldn't parse <$zone> as a netmask. error was <".Net::Netmask::errstr().
                     ">. check your server settings";
            }
        }
    }

    sub stuff_cache { # for testing, or it'll try the db
        my ($self, $ip, $netmask) = @_;

        $cache{$ip} = $netmask;
        $age = 1;
    }
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:

__END__

=head1 NAME

MogileFS::ReplicationPolicy::MultipleNetworks

=head1 RULES

This policy tries to put files onto devices which are on different networks, if that isn't possible then devices on the same network are returned as "desperate" options.

We aim to have as many copies as we can on unique networks, if there are 2 copies on one network and none on another, with a min of 2,  we will still over-replicate to the other network. When called from the rebalancer we will therefore rebalance across networks and reduce the correct copy.

By default we class 2 hosts as being on 2 different networks if they're are on different /16 networks (255.255.0.0). This can be controlled using server settings, with a list of network "zones", and then a definition of a netmask for each "zone".

mogadm settings set network_zones location1,location2
mogadm settings set zone_location1 192.168.0.0/24
mogadm settings set zone_location2 10.0.0.0/24

Zone names and netmasks must each be unique.

=head1 SEE ALSO

L<MogileFS::Worker::Replicate>

L<MogileFS::ReplicationPolicy>

l<MogileFS::ReplicationRequest>

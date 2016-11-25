package MogileFS::ReplicationPolicy::HostsPerNetwork;

use strict;
use warnings;

use base 'MogileFS::ReplicationPolicy';

use MogileFS::Network;
use MogileFS::Util qw(weighted_list);
use MogileFS::ReplicationRequest qw(ALL_GOOD TOO_GOOD TEMP_NO_ANSWER);

sub new {
    my $class = shift;
    my %args = @_;

    my $self = bless {}, $class;

    $self->{hosts_per_zone} = delete $args{hosts_per_zone}
        if $args{hosts_per_zone};

    return $self;
}

sub new_from_policy_args {
    my ($class, $argref) = @_;
    # Note: "MultipleNetworks()" is okay, in which case the 'mindevcount'
    # on the class is used.  (see below)
    $$argref =~ s/^\s* \( \s* ( [^)]*?) \s* \) \s*//x
        or die "$class failed to parse args: $$argref";

    my @args = split /\s*,\s*/, $1;
    my %hosts_per_zone;

    foreach my $arg (@args) {
        my ($zone, $count) = split /\s*=\s*/, $arg;
        $hosts_per_zone{$zone} = $count;
    }

    return $class->new(hosts_per_zone => \%hosts_per_zone);
}

sub replicate_to {
    my ($self, %args) = @_;

    my $hosts_per_zone = $self->{hosts_per_zone};

    my $fid      = delete $args{fid};      # fid scalar to copy
    my $on_devs  = delete $args{on_devs};  # arrayref of device objects
    my $all_devs = delete $args{all_devs}; # hashref of { devid => MogileFS::Device }
    my $failed   = delete $args{failed};   # hashref of { devid => 1 } of failed attempts this round

    delete $args{min}; # We don't use this.

    warn "Unknown parameters: " . join(", ", sort keys %args) if %args;
    die "Missing parameters" unless $on_devs && $all_devs && $failed && $fid;

    # see which and how many unique hosts/networks we're already on.
    my %on_dev;
    my %on_host;

    my %on_host_per_zone;
    my %on_dev_per_zone;

    foreach my $dev (@$on_devs) {
        my $on_ip = $dev->host->ip;
        my $hostid = $dev->host->id;

        if ($on_ip) {
            my $zone = MogileFS::Network->zone_for_ip($on_ip);

            $on_dev_per_zone{$zone}++;

            # If we've already counted this host, then don't increment it for this zone
            $on_host_per_zone{$zone}++ unless $on_host{$dev->hostid};
        }

        $on_dev{$dev->id}++;
        $on_host{$dev->hostid}++;
    }

    my %available_hosts_per_zone;
    my %available_hosts;

    foreach my $dev (values %$all_devs) {
        next unless $dev->dstate->should_have_files;
        my $ip = $dev->host->ip;
        my $hostid = $dev->host->id;
        my $zone = MogileFS::Network->zone_for_ip($ip);
        $available_hosts_per_zone{$zone}++ unless $available_hosts{$hostid};
        $available_hosts{$hostid}++;
    }

    my %needed_network;
    my $too_good = 0;

    while (my ($zone, $needed) = each %$hosts_per_zone) {
        # If we already on all hosts in the target zone, and we're still not happy, then
        # we need to start doubling up on devices, but now devs is not to exceed the requested
        # number of hosts.
        my $on = ($needed <= $available_hosts_per_zone{$zone}) ? $on_host_per_zone{$zone} : $on_dev_per_zone{$zone};
        $on ||= 0;

        if ($on < $needed) {
            $needed_network{$zone} = 1;
        } elsif ($on_dev_per_zone{$zone} > $needed) {
            $too_good++;
        }
    }

    unless (keys %needed_network) {
        return TOO_GOOD if $too_good;
        return ALL_GOOD;
    }

    my @all_dests = sort {
        $b->percent_free <=> $a->percent_free
    } grep {
        ! $on_dev{$_->devid} &&
        ! $failed->{$_->devid} &&
        $_->should_get_replicated_files
    } values %$all_devs;

    return TEMP_NO_ANSWER unless @all_dests;

    my @ideal;
    my @desp;

    foreach my $dev (@all_dests) {
            my $ip = $dev->host->ip;
            my $host_id = $dev->host->id;
            my $zone = MogileFS::Network->zone_for_ip($ip);

            # If we don't need more devices in this current network
            # zone, then don't include the current device.
            next unless $needed_network{$zone};

            if ($on_host{$host_id}) {
                    push @desp, $dev;
            } else {
                    push @ideal, $dev;
            }
    }

    return TEMP_NO_ANSWER unless @desp or @ideal;

    @ideal = weighted_list(map { [$_, 100 * $_->percent_free] }
        splice(@ideal, 0, 20));
    @desp  = weighted_list(map { [$_, 100 * $_->percent_free] }
        splice(@desp, 0, 20));

    return MogileFS::ReplicationRequest->new(
                                             ideal     => \@ideal,
                                             desperate => \@desp,
                                            );
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:
# vim: filetype=perl softtabstop=4 expandtab

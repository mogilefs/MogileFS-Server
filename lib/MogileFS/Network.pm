package MogileFS::Network;

=head1 NAME

MogileFS::Network - Network awareness and extensions for MogileFS::Server

=head1 DESCRIPTION

This collection of modules adds multiple network awareness to the MogileFS
server. It provides two replication policies, 'MultipleNetworks' and
'HostsPerNetwork'; and also provides a plugin 'ZoneLocal' that causes
get_paths queries to be returned in a prioritized order based on locality of
storage.

For information on configuring a location-aware installation of MogileFS
please check out the MogileFS wiki.

L<http://code.google.com/p/mogilefs/wiki/ConfigureMultiNet>

=cut

use strict;
use warnings;

use Net::Netmask;
use Net::Patricia;
use MogileFS::Config;

our $VERSION = "0.06";

use constant DEFAULT_RELOAD_INTERVAL => 60;

my $trie = Net::Patricia->new(); # Net::Patricia object used for cache and lookup.
my $next_reload = 0;             # Epoch time at or after which the trie expires and must be regenerated.
my $has_cached = MogileFS::Config->can('server_setting_cached');

sub zone_for_ip {
    my $class = shift;
    my $ip = shift;

    return unless $ip;

    check_cache();

    return $trie->match_string($ip);
}

sub check_cache {
    # Reload the trie if it's expired
    return unless (time() >= $next_reload);

    $trie = Net::Patricia->new();

    my @zones = split(/\s*,\s*/, get_setting("network_zones"));

    my @netmasks; # [ $bits, $netmask, $zone ], ...

    foreach my $zone (@zones) {
        my $zone_masks = get_setting("zone_$zone");

        if (not $zone_masks) {
            warn "couldn't find network_zone <<zone_$zone>> check your server settings";
            next;
        }

        foreach my $network_string (split /[,\s]+/, $zone_masks) {
            my $netmask = Net::Netmask->new2($network_string);

            if (Net::Netmask::errstr()) {
                warn "couldn't parse <$zone> as a netmask. error was <" . Net::Netmask::errstr().
                     ">. check your server settings";
                next;
            }

            push @netmasks, [$netmask->bits, $netmask, $zone];
        }
    }

    # Sort these by mask bit count, because Net::Patricia doesn't say in its docs whether add order
    # or bit length is the overriding factor.
    foreach my $set (sort { $a->[0] <=> $b->[0] } @netmasks) {
        my ($bits, $netmask, $zone) = @$set;

        if (my $other_zone = $trie->match_exact_string("$netmask")) {
            warn "duplicate netmask <$netmask> in network zones '$zone' and '$other_zone'. check your server settings";
        }

        $trie->add_string("$netmask", $zone);
    }

    my $interval = get_setting("network_reload_interval") || DEFAULT_RELOAD_INTERVAL;

    $next_reload = time() + $interval;

    return 1;
}

# This is a separate subroutine so I can redefine it at test time.
sub get_setting {
    my $key = shift;
    if ($has_cached) {
        my $val = MogileFS::Config->server_setting_cached($key);
        return $val;
    }
    # Fall through to the server in case we don't have a cached value yet.
    return MogileFS::Config->server_setting($key);
}

sub test_config {
    my $class = shift;

    my %config = @_;

    no warnings 'redefine';

    *get_setting = sub {
        my $key = shift;
        return $config{$key};
    };

    $next_reload = 0;
}

=head1 COPYRIGHT

Copyright 2011 - Jonathan Steinert

=head1 AUTHOR

Jonathan Steinert

=head1 LICENSE

This module is licensed under the same terms as Perl itself.

=cut

1;

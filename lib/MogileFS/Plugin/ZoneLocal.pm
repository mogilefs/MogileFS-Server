# ZoneLocal plugin for MogileFS, by hachi

package MogileFS::Plugin::ZoneLocal;

use strict;
use warnings;

use MogileFS::Worker::Query;
use MogileFS::Network;
use MogileFS::Util qw/error/;

sub prioritize_devs_current_zone;

sub load {
    my $local_network = MogileFS::Config->config('local_network');
    die "must define 'local_network' (ie: 10.5.0.0/16) in your mogilefsd.conf"
        unless $local_network;
    my $local_zone_test = MogileFS::Network->zone_for_ip($local_network);
    die "Could not resolve a local zone for $local_network. Please ensure this IP is within a configured zone"
        unless $local_zone_test;

    MogileFS::register_global_hook( 'cmd_get_paths_order_devices', sub {
        my $devices = shift;
        my $sorted_devs = shift;

        @$sorted_devs = prioritize_devs_current_zone(
                        $MogileFS::REQ_client_ip,
                        \&MogileFS::Worker::Query::sort_devs_by_utilization,
                        @$devices
                        );

        return 1;
    });

    MogileFS::register_global_hook( 'cmd_create_open_order_devices', sub {
        my $devices = shift;
        my $sorted_devs = shift;

        @$sorted_devs = prioritize_devs_current_zone(
                        $MogileFS::REQ_client_ip,
                        \&MogileFS::Worker::Query::sort_devs_by_freespace,
                        @$devices
                        );

        return 1;
    });

    MogileFS::register_global_hook( 'replicate_order_final_choices', sub {
        my $devs    = shift;
        my $choices = shift;

        my @sorted = prioritize_devs_current_zone(
                     MogileFS::Config->config('local_network'),
                     sub { return @_; },
                     map { $devs->{$_} } @$choices);
        @$choices  = map { $_->id } @sorted;

        return 1;
    });

    MogileFS::register_global_hook( 'slave_list_filter', sub {
        my $slaves_list = shift;

        @$slaves_list = filter_slaves_current_zone(
            MogileFS::Config->config('local_network'),
            @$slaves_list);

        return 1;
    });

    MogileFS::register_global_hook( 'slave_list_check', sub {
        my $slaves_list = shift;

        my $slave_skip_filtering = MogileFS::Config->server_setting('slave_skip_filtering');

        check_slaves_list(@$slaves_list)
            unless defined $slave_skip_filtering && $slave_skip_filtering eq 'on';

        return 1;
    });

    return 1;
}

sub unload {
    # remove our hooks
    MogileFS::unregister_global_hook( 'cmd_get_paths_order_devices' );
    MogileFS::unregister_global_hook( 'cmd_create_open_order_devices' );
    MogileFS::unregister_global_hook( 'replicate_order_final_choices' );

    return 1;
}

sub prioritize_devs_current_zone {
    my $local_ip = shift;
    my $sorter   = shift;
    my $current_zone = MogileFS::Network->zone_for_ip($local_ip);
    error("Cannot find current zone for local ip $local_ip")
        unless defined $current_zone;

    my (@this_zone, @other_zone);

    foreach my $dev (@_) {
        my $ip = $dev->host->ip;
        my $host_id = $dev->host->id;
        my $zone = MogileFS::Network->zone_for_ip($ip);
        error("Cannot find zone for remote IP $ip")
            unless defined $zone;

        if ($current_zone eq $zone) {
            push @this_zone, $dev;
        } else {
            push @other_zone, $dev;
        }
    }

    return $sorter->(@this_zone), $sorter->(@other_zone);
}

# TODO: This could be further improved by making split lists as with above,
# then changing core code to try other slaves if all local ones are dead.
sub filter_slaves_current_zone {
    my $local_ip    = shift;

    my $current_zone = MogileFS::Network->zone_for_ip($local_ip);
    error("Cannot find current zone for local ip $local_ip")
        unless defined $current_zone;

    my @list = ();
    foreach my $slave (@_) {
        my $dsn = $slave->[0];
        if ($dsn =~ m/host=([^;]+)/) {
            my $host = $1;
            # Don't need the port.
            $host =~ s/:(\d+)//;
            if ($host eq 'localhost') {
                # "localhost" is a special case for saying "use a unix dmoain
                # socket", which will always be local to the box.
                push @list, $slave;
                next;
            }
            unless ($host =~ m/^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$/) {
                # TODO: Pick the least depressing way to deal with this
                # Must cache forward/negative lookups and blah blah blah.
                error("Must specify slave host by IP address, not name: $dsn");
                next;
            }
            my $zone = MogileFS::Network->zone_for_ip($host);
            unless (defined $zone) {
                error("Cannot find zone for slave IP $host");
                next;
            }

            if ($current_zone eq $zone) {
                push @list, $slave;
            }
        } else {
            error("Slave DSN must specify IP address via host= argument: $dsn");
        }
    }

    return @list;
}

sub check_slaves_list {
    foreach my $slave (@_) {
        my $dsn = $slave->[0];
        if ($dsn =~ m/host=([^;]+)/) {
            my $host = $1;
            # Don't need the port.
            $host =~ s/:(\d+)//;
            if ($host eq 'localhost') {
                # "localhost" is a special case for saying "use a unix dmoain
                # socket", which will always be local to the box.
                next;
            }
            unless ($host =~ m/^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$/) {
                # TODO: Pick the least depressing way to deal with this
                # Must cache forward/negative lookups and blah blah blah.
                die("Must specify slave host by IP address, not name: $dsn");
            }
            my $zone = MogileFS::Network->zone_for_ip($host);
            unless (defined $zone) {
                die("Cannot find zone for slave IP $host");
            }
        } else {
            die("Slave DSN must specify IP address via host= argument: $dsn");
        }
    }
}

1;

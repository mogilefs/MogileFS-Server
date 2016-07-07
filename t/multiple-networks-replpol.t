#!/usr/bin/perl

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Net::Netmask;

use MogileFS::Server;
use MogileFS::Util qw(error_code);
use MogileFS::ReplicationPolicy::MultipleNetworks;
use MogileFS::Test;

plan tests => 25;

# need just the one, so we only have to stuff the cache once
my $polclass = "MogileFS::ReplicationPolicy::MultipleNetworks";
my $pol = $polclass->new;

# test that the MultipleHosts stuff still works
# we cope when there are no ips

# already good.
is(rr("min=2  h1[d1=X d2=_] h2[d3=X d4=_]"),
   "all_good", "all good");

# need to get it onto host2...
is(rr("min=2  h1[d1=X d2=_] h2[d3=_ d4=_]"),
   "ideal(3,4)", "need host2");

# still needs to be on host2, even though 2 copies on host1
is(rr("min=2  h1[d1=X d2=X] h2[d3=_ d4=_]"),
   "ideal(3,4)", "need host2, even though 2 on host1");

# anywhere will do.  (can happen on, say, rebalance)
is(rr("min=2  h1[d1=_ d2=_] h2[d3=_ d4=_]"),
   "ideal(1,2,3,4)", "anywhere");

# should desperately try d2, since host2 is down
is(rr("min=2  h1[d1=X d2=_] h2=down[d3=_ d4=_]"),
   "desperate(2)");

# should try host3, since host2 is down
is(rr("min=2  h1[d1=X d2=_] h2=down[d3=_ d4=_] h3[d5=_ d6=_]"),
   "ideal(5,6)");

# need a copy on a non-dead disk on host1
is(rr("min=2  h1[d1=_ d2=X,dead] h2=alive[d3=X d4=_]"),
   "ideal(1)");

# this is an ideal move, since we only have 2 unique hosts:
is(rr("min=3 h1[d1=_ d2=X] h2[d3=X d4=_]"),
   "ideal(1,4)");

# ... but if we have a 3rd host, it's gotta be there
is(rr("min=3 h1[d1=_ d2=X] h2[d3=X d4=_] h3[d5=_]"),
   "ideal(5)");

# ... unless that host is down, in which case it's back to 1/4,
# but desperately
is(rr("min=3 h1[d1=_ d2=X] h2[d3=X d4=_] h3=down[d5=_]"),
   "desperate(1,4)");

# too good, uniq hosts > min
is(rr("min=2 h1[d1=X d2=_] h2[d3=X d4=_] h3[d5=X]"),
   "too_good");

# too good, but but with uniq hosts == min
is(rr("min=2 h1[d1=X d2=X] h2[d3=X d4=_]"),
   "too_good");

# be happy with 3 copies, even though two are on same host (that's our max unique hosts)
is(rr("min=3 h1[d1=_ d2=X] h2[d3=X d4=X]"),
   "all_good");

##
##
# actual network policy tests
my ($ad1, $ad2) = ("#192.168.0.2#" ,"#192.168.0.3#" );
my ($ad3, $ad4) = ("#10.0.0.2#"    ,"#10.0.0.3#"    );
my ($ad5, $ad6) = ("#146.101.246.2#","#146.101.142.130#");

# stuff the cache with the default, otherwise it'll go to the db
$pol->stuff_cache('192.168.0.2'    , Net::Netmask->new('192.168.0.0/16'));
$pol->stuff_cache('192.168.0.3'    , Net::Netmask->new('192.168.0.0/16'));
$pol->stuff_cache('10.0.0.2'       , Net::Netmask->new('10.0.0.0/16'));
$pol->stuff_cache('10.0.0.3'       , Net::Netmask->new('10.0.0.0/16'));
$pol->stuff_cache('146.101.246.2'  , Net::Netmask->new('146.101.0.0/16'));
$pol->stuff_cache('146.101.142.130', Net::Netmask->new('146.101.0.0/16'));

# retest some multiple Host logic all on the same network
# already good. (there's only one network)
is(rr("min=2  h1[d1=X d2=_]$ad1 h2[d3=X d4=_]$ad2"),
   "all_good", "all good");

# need to get it onto host2...
is(rr("min=2  h1[d1=X d2=_]$ad1 h2[d3=_ d4=_]$ad2"),
   "desperate(2,3,4)", "need host2"); 

# still needs to be on host2, even though 2 copies on host1
is(rr("min=2  h1[d1=X d2=X]$ad1 h2[d3=_ d4=_]$ad2"),
   "desperate(3,4)", "need host2, even though 2 on host1");

# target another network
is(rr("min=2 h1[d1=_ d2=X]$ad1 h2[d3=_ d4=_]$ad2 h3[d5=_ d6=_]$ad3 h4[d7=_ d8=_]$ad4"),
   "ideal(5,6,7,8)","target other network"); # no device 3 or 4 (or 1) in the ideal

# other network down
is(rr("min=2 h1[d1=_ d2=X]$ad1 h2[d3=_ d4=_]$ad2 h3=down[d5=_ d6=_]$ad3 h4=down[d7=_ d8=_]$ad4"),
   "desperate(1,3,4)", "desperate this network"); 

is(rr("min=2 h1[d1=_ d2=X]$ad1 h2[d3=_ d4=_]$ad2 h3[d5=_ d6=_]$ad3 h4[d7=_ d8=_]$ad5"),
   "ideal(5,6,7,8)","include both other networks with three networks");

is(rr("min=2 h1[d1=_ d2=X]$ad1 h2[d3=_ d4=_]$ad2 h3=down[d5=_ d6=_]$ad3 h4[d7=_ d8=_]$ad5"),
   "ideal(7,8)","one of three networks down");

is(rr("min=2  h1[d1=_ d2=X,dead]$ad1 h2=alive[d3=_ d4=_]$ad2 h3=alive[d5=X d6=_]$ad3"),
   "ideal(1,3,4)","dead copies don't exclude a network");

is(rr("min=2  h1[d1=_ d2=X]$ad1 h2[d3=_ d4=_]$ad2 h3[d5=X d6=_]$ad3"),
   "all_good","enough copies on different networks");

is(rr("min=2  h1[d1=_ d2=X]$ad1 h2[d3=X d4=X]$ad2"),
   "too_good","3 copies on 2 networks with a min of 2 is too good");

# too many copies on one network, not enough on another, want to over-replicate
is(rr("min=2 h1[d1=X d2=X]$ad1 h2[d3=X d4=X]$ad2 h3[d5=_ d6=_]$ad3 h4[d7=_ d8=_]$ad4"),
   "ideal(5,6,7,8)", "more than min hosts, but all on one network");

# mess with netmasks
$pol->stuff_cache('146.101.246.2'  , Net::Netmask->new('146.101.246.0/24'));
$pol->stuff_cache('146.101.142.130', Net::Netmask->new('146.101.142.0/24'));

is(rr("min=2 h1[d1=_ d2=X]$ad6 h2[d3=_ d4=_]$ad5 h3[d5=_ d6=_]$ad4 h4[d7=_ d8=_]$ad3"),
   "ideal(3,4,5,6,7,8)","target other network"); # ad5 and ad6 are no longer the same network

sub rr {
    my ($state) = @_;
    my $ostate = $state; # original

    MogileFS::Factory::Host->t_wipe;
    MogileFS::Factory::Device->t_wipe;
    MogileFS::Config->set_config_no_broadcast("min_free_space", 100);
    my $hfac = MogileFS::Factory::Host->get_factory;
    my $dfac = MogileFS::Factory::Device->get_factory;

    my $min = 2;
    if ($state =~ s/^\bmin=(\d+)\b//) {
        $min = $1;
    }

    my $hosts   = {};
    my $devs    = {};
    my $on_devs = [];

    my $parse_error = sub {
        die "Can't parse:\n   $ostate\n"
    };
    while ($state =~ s/\bh(\d+)(?:=(.+?))?\[(.+?)\](#\d+\.\d+\.\d+\.\d+\.?#)?//) {
        my ($n, $opts, $devstr, $ip) = ($1, $2, $3, $4);
        $opts ||= "";
        die "dup host $n" if $hosts->{$n};

#        print "1 2 3 4 : <<$1>> <<$2>> <<$3>> <<$4>>\n";
#        print "$state\n";

        my %extras;
        if ($ip) {
            $ip =~ s/#//g;
            $extras{hostip} = $ip;
        }

        my $h = $hosts->{$n} = $hfac->set({ hostid => $n,
            status => ($opts || "alive"), observed_state => "reachable",
            hostname => $n, %extras });


        foreach my $ddecl (split(/\s+/, $devstr)) {
            $ddecl =~ /^d(\d+)=([_X])(?:,(\w+))?$/
                or $parse_error->();
            my ($dn, $on_not, $status) = ($1, $2, $3);
            die "dup device $dn" if $devs->{$dn};
            my $d = $devs->{$dn} = $dfac->set({ devid => $dn,
                hostid => $h->id, observed_state => "writeable",
                status => ($status || "alive"), mb_total => 1000,
                mb_used => 100, });
            if ($on_not eq "X" && $d->dstate->should_have_files) {
                push @$on_devs, $d;
            }
        }
    }
    $parse_error->() if $state =~ /\S/;

    my $rr = $pol->replicate_to(
                                fid      => 1,
                                on_devs  => $on_devs,
                                all_devs => $devs,
                                failed   => {},
                                min      => $min,
                                );
    return $rr->t_as_string;
}


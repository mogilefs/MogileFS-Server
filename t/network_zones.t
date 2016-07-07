#!/usr/bin/perl

use strict;
use warnings;
use Test::More tests => 5;
use FindBin qw($Bin);

use MogileFS::Network;

MogileFS::Network->test_config(
    zone_one    => '127.0.0.0/16',
    zone_two    => '10.0.0.0/8, 172.16.0.0/16',
    zone_three => '10.1.0.0/16',
    network_zones => 'one, two, three',
);


is(lookup('127.0.0.1'), 'one', "Standard match");
is(lookup('10.0.0.1'), 'two', "Outer netblock match");
is(lookup('10.1.0.1'), 'three', "Inner netblock match");
is(lookup('172.16.0.1'), 'two', "Zone with multiple netblocks");
is(lookup('192.168.0.1'), undef, "Unknown zone");

sub lookup {
    return MogileFS::Network->zone_for_ip(@_);
}

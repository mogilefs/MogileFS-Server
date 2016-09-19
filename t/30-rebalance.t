# -*-perl-*-

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

use MogileFS::Server;
use MogileFS::Util qw(error_code);
use MogileFS::Test;

find_mogclient_or_skip();

my $sto = eval { temp_store(); };
if (!$sto) {
    plan skip_all => "Can't create temporary test database: $@";
    exit 0;
}

my $dbh = $sto->dbh;
my $rv;

my ($hostA_ip, $hostB_ip, $hostC_ip) = (qw/127.0.1.1 127.0.1.2 127.0.1.3/);

use File::Temp;
my %mogroot;
$mogroot{1} = File::Temp::tempdir( CLEANUP => 1 );
$mogroot{2} = File::Temp::tempdir( CLEANUP => 1 );
$mogroot{3} = File::Temp::tempdir( CLEANUP => 1 );
my $dev2host = { 1 => 1, 2 => 1,
                 3 => 2, 4 => 2,
                 5 => 3, 6 => 3, };
foreach (sort { $a <=> $b } keys %$dev2host) {
    my $root = $mogroot{$dev2host->{$_}};
    mkdir("$root/dev$_") or die "Failed to create dev$_ dir: $!";
}

my $ms1 = create_mogstored($hostA_ip, $mogroot{1});
ok($ms1, "got mogstored1");
my $ms2 = create_mogstored($hostB_ip, $mogroot{2});
ok($ms2, "got mogstored2");

while (! -e "$mogroot{1}/dev1/usage" &&
       ! -e "$mogroot{2}/dev4/usage") {
    print "Waiting on usage...\n";
    sleep 1;
}

my $tmptrack = create_temp_tracker($sto);
ok($tmptrack);

my $mogc = MogileFS::Client->new(
                                 domain => "testdom",
                                 hosts  => [ "127.0.0.1:7001" ],
                                 );
my $be = $mogc->{backend}; # gross, reaching inside of MogileFS::Client

# test some basic commands to backend
ok($be->do_request("test", {}), "test ping worked");

ok($tmptrack->mogadm("domain", "add", "testdom"), "created test domain");
ok($tmptrack->mogadm("class", "add", "testdom", "1copy", "--mindevcount=1"), "created 1copy class in testdom");
ok($tmptrack->mogadm("class", "add", "testdom", "2copies", "--mindevcount=2"), "created 2copies class in testdom");

ok($tmptrack->mogadm("host", "add", "hostA", "--ip=$hostA_ip", "--status=alive"), "created hostA");
ok($tmptrack->mogadm("host", "add", "hostB", "--ip=$hostB_ip", "--status=alive"), "created hostB");

ok($tmptrack->mogadm("device", "add", "hostA", 1), "created dev1 on hostA");
ok($tmptrack->mogadm("device", "add", "hostA", 2), "created dev2 on hostA");
ok($tmptrack->mogadm("device", "add", "hostB", 3), "created dev3 on hostB");
ok($tmptrack->mogadm("device", "add", "hostB", 4), "created dev4 on hostB");

my $ms3 = create_mogstored($hostC_ip, $mogroot{3});
ok($ms3, "got mogstored3");
ok($tmptrack->mogadm("host", "add", "hostC", "--ip=$hostC_ip", "--status=alive"), "created hostC");
ok($tmptrack->mogadm("device", "add", "hostC", 5), "created dev5 on hostC");
ok($tmptrack->mogadm("device", "add", "hostC", 6), "created dev6 on hostC");

# wait for monitor
{
    my $was = $be->{timeout};  # can't use local on phash :(
    $be->{timeout} = 10;
    ok($be->do_request("clear_cache", {}), "waited for monitor")
        or die "Failed to wait for monitor";
    ok($be->do_request("clear_cache", {}), "waited for monitor")
        or die "Failed to wait for monitor";
    $be->{timeout} = $was;
}

# create a couple hundred files now
my $n_files = 300;
diag("Creating $n_files files...");
for my $n (1..$n_files) {
    my $fh = $mogc->new_file("manyhundred_$n", "2copies")
        or die "Failed to create manyhundred_$n: " . $mogc->errstr;
    my $data = "File number $n.\n" x 128;
    print $fh $data;
    close($fh) or die "Failed to close manyhundred_$n";
    diag("created $n/$n_files") if $n % 10 == 0;
}
pass("Created a ton of files");

# wait for replication to go down
# We need to wait for BOTH queues to be empty before we continue to rebalance.
# If there is anything left w/ a devid that we rebalance away from, there would
# be a failure when the HTTP delete happens simultaenously to the replication.
# This will manifest as subtest 48 failing often...
{
    my $iters = 30;
    my ($to_repl_rows, $to_queue_rows);
    while ($iters) {
        $iters--;
        $to_repl_rows = $dbh->selectrow_array("SELECT COUNT(*) FROM file_to_replicate");
        $to_queue_rows = $dbh->selectrow_array("SELECT COUNT(*) FROM file_to_queue");
        last if $to_repl_rows eq 0 && $to_queue_rows eq 0;
        diag("Files to replicate: file_to_replicate=$to_repl_rows file_to_queue=$to_queue_rows");
        sleep 1;
    }
    die "Failed to replicate all $n_files files" if $to_repl_rows || $to_queue_rows;
    pass("Replicated all $n_files files");
}

# Create a rebalance object and test a few things.
use MogileFS::Device;
use MogileFS::Host;
use MogileFS::Config;
use MogileFS::Rebalance;
use MogileFS::Factory::Host;
use MogileFS::Factory::Device;
use Data::Dumper qw/Dumper/;

my $dfac = MogileFS::Factory::Device->get_factory;
my $hfac = MogileFS::Factory::Host->get_factory;

map { $hfac->set($_) } $sto->get_all_hosts;
map { $dfac->set($_) } $sto->get_all_devices;
my @devs = $dfac->get_all;

### Hacks to make tests work :/
$MogileFS::Config::skipconfig = 1;
MogileFS::Config->load_config;
for my $h ($hfac->get_all) {
    print "hostid: ", $h->id, " name: ", $h->hostname, "\n";
    $h->{observed_state} = "reachable";
}
for my $d (@devs) {
    print "Dev: ", $d->id;
    print " free: ", $d->percent_free;
    print " used: ", $d->percent_full;
    print "\n";
    $d->{observed_state} = "writeable";
}

### Actual rebalance tests.
my ($devfids, $devfids2, $saved_state);
my $rebal_pol = "from_hosts=1 fid_age=old limit_type=device limit_by=none to_all_devs=0 to_hosts=3 leave_in_drain_mode=0";
eval {
    my $rebal = MogileFS::Rebalance->new;
    ok($rebal->policy($rebal_pol));
    ok($rebal->init(\@devs));
    ok($devfids = $rebal->next_fids_to_rebalance(\@devs, $sto, 5));
    ok($devfids2 = $rebal->next_fids_to_rebalance(\@devs, $sto, 8));
    ok($saved_state = $rebal->save_state);
#    print Dumper($rebal), "\n";
};
if ($@) {
    print "error: ", $@;
}

#print Dumper($saved_state), "\n";
#print Dumper($devfids), "\n";
#print Dumper($devfids2), "\n";

$devfids2 = undef;
eval {
    my $rebal = MogileFS::Rebalance->new;
    ok($rebal->policy($rebal_pol));
    ok($rebal->load_state($saved_state));
    ok($devfids2 = $rebal->next_fids_to_rebalance(\@devs, $sto, 3));
#    print Dumper($rebal), "\n";
};
if ($@) {
    print "error: ", $@;
}

#print Dumper($saved_state), "\n";
#print Dumper($devfids2), "\n";

# ensure all devices are still marked alive.
ok($tmptrack->mogadm("device", "mark", "hostA", 1, "alive"), "dev1 alive");
ok($tmptrack->mogadm("device", "mark", "hostA", 2, "alive"), "dev2 alive");
ok($tmptrack->mogadm("device", "mark", "hostB", 3, "alive"), "dev3 alive");
ok($tmptrack->mogadm("device", "mark", "hostB", 4, "alive"), "dev4 alive");
ok($tmptrack->mogadm("device", "mark", "hostC", 5, "alive"), "dev5 alive");
ok($tmptrack->mogadm("device", "mark", "hostC", 6, "alive"), "dev6 alive");

use MogileFS::Admin;
my $moga = MogileFS::Admin->new(
                                 domain => "testdom",
                                 hosts  => [ "127.0.0.1:7001" ],
                                 );

ok(! defined $moga->rebalance_stop);
my $res;

# Quickly test the "no dupes" policy.
# ensures that source devices are properly filtered.
my $rebal_pol_dupes = "from_devices=1";
ok($res = $moga->rebalance_set_policy($rebal_pol_dupes));
if (! defined $res) {
    print "Admin error: ", $moga->errstr, "\n";
}
ok($res = $moga->rebalance_test);
{
    for my $dev (sort split /,/, $res->{ddevs}) {
        ok($dev != 1);
    }
}

ok($res = $moga->rebalance_set_policy($rebal_pol));
if (! defined $res) {
    print "Admin error: ", $moga->errstr, "\n";
}
ok($res = $moga->rebalance_test);
#print "Test result: ", Dumper($res), "\n\n";
ok(! defined $moga->rebalance_status);
if (! defined $res) {
    print "Admin error: ", $moga->errstr, "\n";
}
#print "Status results: ", Dumper($res), "\n\n";
ok($res = $moga->rebalance_start);
if (! defined $res) {
    print "Admin error: ", $moga->errstr, "\n";
}
if ($res) {
#    print "Start results: ", Dumper($res), "\n\n";
}

# This sleep should be replaced with a "rebalance status" check to confirm
# it's been started. Otherwise there's up to two seconds where JobMaster might
# not have seen the start request yet. Lowered the sleep from 5 to 3.
sleep 3;

{
    my $iters = 60;
    my ($to_repl_rows, $to_queue_rows);
    while ($iters) {
        $iters--;
        $to_repl_rows = $dbh->selectrow_array("SELECT COUNT(*) FROM file_to_replicate");
        $to_queue_rows = $dbh->selectrow_array("SELECT COUNT(*) FROM file_to_queue");
        last if $to_repl_rows eq 0 && $to_queue_rows eq 0;
        diag("Files to rebalance: file_to_replicate=$to_repl_rows file_to_queue=$to_queue_rows");
        sleep 1;
    }
    die "Failed to rebalance all files" if $to_repl_rows || $to_queue_rows;
    pass("Replicated all files");
}

# TODO: Verify that files moved from devs 1,2 to 5,6
# select devid, count(*) from file_on group by devid;

# TODO: Verify that devices are left in drain mode or not left in drain mode.

# NOTE: The above just does some barebones testing. I was using the Dumper
# to visually inspect.
# For the enterprising, more tests are needed:
# - fiddle mbused/mbfree for devices and test the percentages
# - test move limits (count, size, etc)

done_testing();

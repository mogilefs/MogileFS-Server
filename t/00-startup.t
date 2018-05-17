# -*-perl-*-

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

use MogileFS::Server;
use MogileFS::Util qw(error_code);
use MogileFS::Test;

BEGIN {
    $ENV{TESTING} = 1;
}

find_mogclient_or_skip();

# use mogadm to init it,
# mogstored on temp dir,
# register mogstored temp dir,
# mogilefsd startup,
# add file,
# etc

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

my $lasttime = 1167609600; # Mon Jan  1 00:00:00 UTC 2007
ok(try_for(3, sub {
    my $timestamp = $dbh->selectrow_array("SELECT ".$sto->unix_timestamp);
    # FIXME: Some databases might be pedantic about the FROM
    # but having it on others means that if the table has no rows
    # we won't get any results!
    my $rv = $timestamp > $lasttime;
    $lasttime = $timestamp;
    return $rv;
}), "Store provides sane unix_timestamp");

# test some basic commands to backend
ok($be->do_request("test", {}), "test ping worked");
ok(!$be->do_request("test", {crash => 1}), "crash didn't");
ok($be->do_request("test", {}), "test ping again worked");

{
    my $c = IO::Socket::INET->new(PeerAddr => '127.0.0.1:7001', Timeout => 3);
    ok(want($c, 1, "queryworker"), "set 1 queryworker");

    my $expect = "ERR no_domain No+domain+provided\r\n" x 2;

    # bad domain won't return twice
    my $cmd = "list_keys domain=\r\n";
    $c->syswrite($cmd x 2);
    my $r;
    my $resp = "";
    do {
        $r = $c->sysread(my $buf, 500);
        if (defined $r && $r > 0) {
            $resp .= $buf;
        }
    } while ($r && length($resp) != length($expect));
    is($resp, $expect, "response matches expected");

    ok(want($c, 2, "queryworker"), "restored 2 queryworkers");
}

ok($tmptrack->mogadm("domain", "add", "todie"), "created todie domain");
ok($tmptrack->mogadm("domain", "delete", "todie"), "delete todie domain");
ok(!$tmptrack->mogadm("domain", "delete", "todie"), "didn't delete todie domain again");

# ensure "default" class is removed when its domain is removed
{
    use Data::Dumper;
    my $before = Dumper($sto->get_all_classes);
    ok($tmptrack->mogadm("domain", "add", "def"), "created def domain");

    my $dmid = $sto->get_domainid_by_name("def");
    ok(defined($dmid), "def dmid retrieved");

    isnt($sto->domain_has_classes($dmid), "domain_has_classes does not show default class");
    ok($tmptrack->mogadm("class", "modify", "def", "default", "--mindevcount=3"), "modified default to have mindevcount=3");

    my $classid = $sto->get_classid_by_name($dmid, "default");
    is($classid, 0, "default class has classid=0");
    isnt($sto->domain_has_classes($dmid), "domain_has_classes does not show default class");
    ok($tmptrack->mogadm("domain", "delete", "def"), "remove def domain");
    is($sto->get_domainid_by_name("def"), undef, "def nonexistent");
    is($sto->get_classid_by_name($dmid, "default"), undef, "def/default class nonexistent");

    my $after = Dumper($sto->get_all_classes);
    is($after, $before, "class listing is unchanged");
}

ok($tmptrack->mogadm("domain", "add", "hasclass"), "created hasclass domain");
ok($tmptrack->mogadm("class", "add", "hasclass", "nodel"), "created nodel class");
ok(!$tmptrack->mogadm("domain", "delete", "hasclass"), "didn't delete hasclass domain");
ok($tmptrack->mogadm("class", "delete", "hasclass", "nodel"), "created nodel class");
ok($tmptrack->mogadm("domain", "delete", "hasclass"), "didn't delete hasclass domain");

ok($tmptrack->mogadm("domain", "add", "testdom"), "created test domain");
ok($tmptrack->mogadm("class", "add", "testdom", "1copy", "--mindevcount=1"), "created 1copy class in testdom");
ok($tmptrack->mogadm("class", "add", "testdom", "2copies", "--mindevcount=2"), "created 2copies class in testdom");
ok($tmptrack->mogadm("class", "add", "testdom", "poltest", "--replpolicy=MultipleHosts(3)"),
    "created a specific policy class");

ok($tmptrack->mogadm("host", "add", "hostA", "--ip=$hostA_ip", "--status=alive"), "created hostA");
ok($tmptrack->mogadm("host", "add", "hostB", "--ip=$hostB_ip", "--status=alive"), "created hostB");

ok($tmptrack->mogadm("device", "add", "hostA", 1), "created dev1 on hostA");
ok($tmptrack->mogadm("device", "add", "hostA", 2), "created dev2 on hostA");
ok($tmptrack->mogadm("device", "add", "hostB", 3), "created dev3 on hostB");
ok($tmptrack->mogadm("device", "add", "hostB", 4), "created dev4 on hostB");

#ok($tmptrack->mogadm("device", "mark", "hostA", 1, "alive"), "dev1 alive");
#ok($tmptrack->mogadm("device", "mark", "hostA", 2, "alive"), "dev2 alive");
#ok($tmptrack->mogadm("device", "mark", "hostB", 3, "alive"), "dev3 alive");
#ok($tmptrack->mogadm("device", "mark", "hostB", 4, "alive"), "dev4 alive");

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

{
    my $fh = $mogc->new_file('no_content', "2copies");
    die "Error: " . $mogc->errstr unless $fh;
    ok(close($fh), "closed file");
}

{
    my $fh = $mogc->new_file('no_content', "2copies");
    die "Error: " . $mogc->errstr unless $fh;
    ok(close($fh), "closed file");
}

# wait for it to replicate
ok(try_for(10, sub {
    my @urls = $mogc->get_paths("no_content");
    my $nloc = @urls;
    if ($nloc < 2) {
        note("no_content still only on $nloc devices");
        return 0;
    }
    return 1;
}), "replicated to 2 paths");

ok(try_for(3, sub {
    my $to_repl_rows = $dbh->selectrow_array("SELECT COUNT(*) FROM file_to_replicate");
    return $to_repl_rows == 0;
}), "no more files to replicate");

# quick delete test
ok($mogc->delete("no_content"), "deleted no_content")
    or die "Error: " . $mogc->errstr;

# create two sample files
my $data = "My test file.\n" x 1024;
foreach my $k (qw(file1 file2)) {
    my $fh = $mogc->new_file($k, "2copies");
    ok($fh, "got filehandle") or
        die "Error: " . $mogc->errstr;
    print $fh $data;
    ok(close($fh), "closed file");
}

# quick delete test
ok($mogc->delete("file2"), "deleted file2")
    or die "Error: " . $mogc->errstr;

# verify we can't delete the domain now
ok(!$tmptrack->mogadm("domain", "delete", "testdom"), "can't delete domain in use");

# wait for it to replicate
my @urls;
ok(try_for(10, sub {
    @urls = $mogc->get_paths("file1");
    my $nloc = @urls;
    if ($nloc < 2) {
        note("file1 still only on $nloc devices");
        return 0;
    }
    return 1;
}), "replicated to 2 paths");

ok(try_for(3, sub {
    my $to_repl_rows = $dbh->selectrow_array("SELECT COUNT(*) FROM file_to_replicate");
    return $to_repl_rows == 0;
}), "no more files to replicate");

my $p1 = MogPath->new($urls[0]);
my $p2 = MogPath->new($urls[1]);
isnt($p1->host, $p2->host, "host1 and host2 are different");
my $path1 = $mogroot{$dev2host->{$p1->device}} . $p1->path;
my $path2 = $mogroot{$dev2host->{$p2->device}} . $p2->path;
is(-s $path1, length($data), "right length on disk for path1");
is(-s $path2, length($data), "right length on disk for path2");

ok(unlink($path1), "deleted path $path1");
my $dead_url = $urls[0];
for (1..10) {
    @urls = $mogc->get_paths("file1");
    isnt($urls[0], $dead_url, "didn't return dead url first (try $_)");
}

# Tests for updateclass command
{
    my $fh = $mogc->new_file('file1copy', "1copy");
    ok($fh, "got filehandle") or
        die "Error: " . $mogc->errstr;
    print $fh 'EXAMPLE DATA';
    ok(close($fh), "closed file");

    is scalar($mogc->get_paths("file1copy")), 1, 'File is on 1 device';

    ok($mogc->update_class('file1copy', '2copies'), "updated class to 2 copies");

    # wait for it to replicate
    ok(try_for(10, sub {
        my @urls = $mogc->get_paths("file1copy");
        my $nloc = @urls;
        if ($nloc < 2) {
            note("no_content still only on $nloc devices");
            return 0;
        }
        return 1;
    }), "replicated to 2 paths");

    ok($mogc->update_class('file1copy', 'default'), "updated class to default");

    ok($mogc->delete("file1copy"), "deleted updateclass testfile file1copy")
        or die "Error: " . $mogc->errstr;
}

ok($be->do_request("rename", {
    from_key => "file1",
    to_key   => "file1renamed",
    domain   => "testdom",
}), "renamed file1 to file1renamed");

ok($be->do_request("delete", {
    key    => "file1renamed",
    domain => "testdom",
}), "deleted file1renamed");

# create a couple hundred files now
my $n_files = 100;
note("Creating $n_files files...");
for my $n (1..$n_files) {
    my $fh = $mogc->new_file("manyhundred_$n", "2copies")
        or die "Failed to create manyhundred_$n: " . $mogc->errstr;
    my $data = "File number $n.\n" x 512;
    print $fh $data;
    close($fh) or die "Failed to close manyhundred_$n";
    note("created $n/$n_files") if $n % 10 == 0;
}
pass("Created a ton of files");

# wait for replication to go down
{
    my $iters = 30;
    my $to_repl_rows;
    while ($iters) {
        $iters--;
        $to_repl_rows = $dbh->selectrow_array("SELECT COUNT(*) FROM file_to_replicate");
        last if ! $to_repl_rows;
        note("Files to replicate: $to_repl_rows");
        sleep 1;
    }
    die "Failed to replicate all $n_files files" if $to_repl_rows;
    pass("Replicated all $n_files files");
}

# now let's delete a host, which should fail hard, because there are still devices attached to it
{
    die "Can't delete an active host" if
        $tmptrack->mogadm("host", "delete", "hostB");
    pass("didn't delete hostB");
}

# create a new host and device, for when we start killing some devices
my $ms3 = create_mogstored($hostC_ip, $mogroot{3});
ok($ms3, "got mogstored3");
ok($tmptrack->mogadm("host", "add", "hostC", "--ip=$hostC_ip", "--status=alive"), "created hostC");
ok($tmptrack->mogadm("device", "add", "hostC", 5), "created dev5 on hostC");
ok($tmptrack->mogadm("device", "add", "hostC", 6), "created dev6 on hostC");

ok($tmptrack->mogadm("device", "mark", "hostB", 3, "dead"), "marked device B/3 dead");
ok($tmptrack->mogadm("device", "mark", "hostB", 4, "dead"), "marked device B/4 dead");

ok(try_for(40, sub {
    my %has;
    my $sth = $dbh->prepare("SELECT devid, COUNT(*) FROM file_on GROUP BY devid");
    $sth->execute;
    while (my ($devid, $ct) = $sth->fetchrow_array) {
        $has{$devid} = $ct;
    }
    note("Replication update: " . join(", ", map { "dev$_: " . sprintf("%3d", ($has{$_}||0)) } (1..6)));
    return 0 if $has{3} || $has{4};
    return $has{1} && $has{1} && $has{5} && $has{6};
}), "files replicated to hostC from hostB");

# kill hostB now
# hosts are no longer able to be nuked even if they have deleted devices.
# this saves us from some subtle bugs.
#ok($tmptrack->mogadm("host", "delete", "hostB"), "killed hostB");

# delete them all, see if they go away.
for my $n (1..$n_files) {
    my $rv = $mogc->delete("manyhundred_$n")
        or die "Failed to delete manyhundred_$n";
}
pass("deleted all $n_files files");

ok(try_for(25, sub {
    my @files;
    foreach my $hn (1, 3) {
        my @lfiles = `find $mogroot{$hn} -type f -name '*.fid'`;
        push @files, @lfiles;
        note("files on host $hn = " . scalar(@lfiles));
    }
    return @files == 0;
}), "and they're gone from filesystem");

foreach my $t (qw(file file_on file_to_delete)) {
    ok(try_for(5, sub {
        return $dbh->selectrow_array("SELECT COUNT(*) FROM $t") == 0;
    }), "table $t is empty");
}

# Test some broken client modes.
{
    my $c = IO::Socket::INET->new(PeerAddr => '127.0.0.1:7001',
        Timeout => 3);
    die "Failed to connect to test tracker" unless $c;
    # Pretend to upload a file, then tell the server weird things.
    # Not trying to be defensable to all sorts of things, but ensuring we're
    # safe against double close, bad destdev, etc.
    print $c "create_open "
        . "domain=testdom&fid=0&class=&multi_dest=1&key=fufufu\n";
    my $res = <$c>;
    my $fidid;
    ok($res =~ m/fid=(\d+)/, "bare create_open worked");
    $fidid = $1;
    # Pretend we uploaded something.
    print $c "create_close "
        . "domain=testdom&fid=$fidid&devid=4&size=0&key=fufufu"
        . "&path=http://127.0.1.2:7500/dev4/0/000/000/0000000$fidid.fid\n";
    my $res2 = <$c>;
    ok($res2 =~ m/invalid_destdev/, "cannot upload to unlisted destdev");

    # TODO: test double closing, etc.
}

# give an explicit fid, to prevent bugs like the reason behind
# commit ac5534a0c3d046e660fa7581c9173857f182bd81
# This is functionality is a bad idea otherwise.
{
    my $expfid = 2147483632;
    my $opts = { fid => $expfid };
    my $fh = $mogc->new_file("explicit_fid", "1copy", 2, $opts);
    die "Error: " . $mogc->errstr unless $fh;
    ok((print $fh "hi" ), "wrote 2 bytes");
    ok(close($fh), "closed file");
    my $info = $mogc->file_info("explicit_fid");

    is($info->{devcount}, 1, "devcount is 1");
    is($info->{fid}, $opts->{fid}, "explicit fid is correctly set");
}

{
    my $fh = $mogc->new_file("0", "1copy");
    ok((print $fh "zero\n"), "wrote to file");
    ok(close($fh), "closed file");

    my $info = $mogc->file_info("0");
    is("HASH", ref($info), "file_info returned a hash");
    is("0", $info->{key}, "key matches 0");
    is("1copy", $info->{class}, "class matches for 0 key");

    my @paths = $mogc->get_paths("0");
    is(1, scalar(@paths), "path returned for 0");

    $mogc->rename("0", "zero");
    is($info->{fid}, $mogc->file_info("zero")->{fid}, "rename from 0");
    $mogc->rename("zero", "0");
    is($info->{fid}, $mogc->file_info("0")->{fid}, "rename to 0");
    $mogc->update_class("0", "2copies");
    is("2copies", $mogc->file_info("0")->{class}, "class updated for 0 key");

    my $debug = $mogc->file_debug(key => "0");
    is($debug->{fid_fid}, $info->{fid}, "FID from debug matches");
    is($debug->{fid_dkey}, "0", "key from debug matches");

    ok($mogc->delete("0"), "delete 0 works");
}

# ensure all workers can be stopped/started
{
    my $c = IO::Socket::INET->new(PeerAddr => '127.0.0.1:7001', Timeout => 3);
    my @jobs = qw(fsck queryworker delete replicate reaper monitor job_master);

    foreach my $j (@jobs) {
        ok(want($c, 0, $j), "shut down all $j");
    }

    # spawn job_master first to ensure delete/fsck/replicate can start
    foreach my $j (reverse @jobs) {
        ok(want($c, 1, $j), "start 1 $j");
    }
}

# list_keys with underscore
{
    my $c = IO::Socket::INET->new(PeerAddr => '127.0.0.1:7001', Timeout => 3);

    foreach my $k (qw(under_score under.score per%cent back\\slash)) {
        my $fh = $mogc->new_file($k, '1copy');
        ok($fh, "got filehandle for $k");
        ok(close($fh), "created file $k");
    }

    # we only have one queryworker from the previous test, so no need to
    # clear cache twice and wait on monitor after "mogadm settings set"
    foreach my $cslk (qw(on off)) {
        ok($tmptrack->mogadm("settings", "set", "case_sensitive_list_keys", $cslk), "case_sensitive_list_keys = $cslk");
        ok($be->do_request("clear_cache", {}), "cleared_cache");
        my @l = $mogc->list_keys("under_");
        is_deeply(['under_score', [ 'under_score' ]], \@l, "list_keys handled underscore properly (case-sensitive $cslk)");

        @l = $mogc->list_keys("per%");
        is_deeply(['per%cent', [ 'per%cent' ]], \@l, "list_keys handled % properly (case-sensitive $cslk)");

        @l = $mogc->list_keys("back\\");
        is_deeply(['back\slash', [ 'back\slash' ]], \@l, "list_keys handled \\ properly (case-sensitive $cslk)");
    }

    # restore default
    $sto->set_server_setting('case_sensitive_list_keys', undef);
}

ok($tmptrack->mogadm(qw(host mark hostA readonly)), "host state=readonly");

done_testing();

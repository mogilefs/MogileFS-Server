# -*-perl-*-
# some of the comments match the comments in MogileFS/Worker/Fsck.pm
# _exactly_ for reference purposes
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use Time::HiRes qw(sleep);
use MogileFS::Server;
use MogileFS::Test;
use HTTP::Request;
find_mogclient_or_skip();
use MogileFS::Admin;

my $sto = eval { temp_store(); };
if (!$sto) {
    plan skip_all => "Can't create temporary test database: $@";
    exit 0;
}

use File::Temp;
my %mogroot;
$mogroot{1} = File::Temp::tempdir( CLEANUP => 1 );
$mogroot{2} = File::Temp::tempdir( CLEANUP => 1 );
$mogroot{3} = File::Temp::tempdir( CLEANUP => 1 );
my $dev2host = { 1 => 1, 2 => 2, 3 => 2 };
foreach (sort { $a <=> $b } keys %$dev2host) {
    my $root = $mogroot{$dev2host->{$_}};
    mkdir("$root/dev$_") or die "Failed to create dev$_ dir: $!";
}

my $ms1 = create_mogstored("127.0.1.1", $mogroot{1});
ok($ms1, "got mogstored1");
my $ms2 = create_mogstored("127.0.1.2", $mogroot{2});
ok($ms2, "got mogstored2");

while (! -e "$mogroot{1}/dev1/usage" ||
       ! -e "$mogroot{2}/dev2/usage" ||
       ! -e "$mogroot{2}/dev3/usage") {
    print "Waiting on usage...\n";
    sleep(.25);
}

my $tmptrack = create_temp_tracker($sto);
ok($tmptrack);

my $admin = IO::Socket::INET->new(PeerAddr => '127.0.0.1:7001');
$admin or die "failed to create admin socket: $!";
my $moga = MogileFS::Admin->new(hosts => [ "127.0.0.1:7001" ]);
my $mogc = MogileFS::Client->new(
                                 domain => "testdom",
                                 hosts  => [ "127.0.0.1:7001" ],
                                 );
my $be = $mogc->{backend}; # gross, reaching inside of MogileFS::Client

# test some basic commands to backend
ok($tmptrack->mogadm("domain", "add", "testdom"), "created test domain");
ok($tmptrack->mogadm("class", "add", "testdom", "2copies", "--mindevcount=2"), "created 2copies class in testdom");
ok($tmptrack->mogadm("class", "add", "testdom", "1copy", "--mindevcount=1"), "created 1copy class in testdom");

ok($tmptrack->mogadm("host", "add", "hostA", "--ip=127.0.1.1", "--status=alive"), "created hostA");
ok($tmptrack->mogadm("host", "add", "hostB", "--ip=127.0.1.2", "--status=alive"), "created hostB");

ok($tmptrack->mogadm("device", "add", "hostA", 1), "created dev1 on hostA");
ok($tmptrack->mogadm("device", "add", "hostB", 2), "created dev2 on hostB");

sub wait_for_monitor {
    my $be = shift;
    my $was = $be->{timeout};  # can't use local on phash :(
    $be->{timeout} = 10;
    ok($be->do_request("clear_cache", {}), "waited for monitor")
        or die "Failed to wait for monitor";
    ok($be->do_request("clear_cache", {}), "waited for monitor")
        or die "Failed to wait for monitor";
    $be->{timeout} = $was;
}

sub watcher_wait_for {
    my ($re, $cb) = @_;
    my $line;
    my $watcher = IO::Socket::INET->new(PeerAddr => '127.0.0.1:7001');
    $watcher or die "failed to create watcher socket: $!";
    $watcher->syswrite("!watch\r\n");

    $cb->(); # usually this is to start fsck

    do {
        $line = $watcher->getline;
    } until ($line =~ /$re/);

    $watcher->close;
}

sub wait_for_empty_queue {
    my ($table, $dbh) = @_;
    my $limit = 600;
    my $delay = 0.1;
    my $i = $limit;
    my $count;
    while ($i > 0) {
        $count = $dbh->selectrow_array("SELECT COUNT(*) from $table");
        return if ($count == 0);
        sleep $delay;
    }
    my $time = $delay * $limit;
    die "$table is not empty after ${time}s!";
}

sub full_fsck {
    my ($tmptrack, $dbh) = @_;

    # this should help prevent race conditions:
    wait_for_empty_queue("file_to_queue", $dbh);

    ok($tmptrack->mogadm("fsck", "stop"), "stop fsck");
    ok($tmptrack->mogadm("fsck", "clearlog"), "clear fsck log");
    ok($tmptrack->mogadm("fsck", "reset"), "reset fsck");
    ok($tmptrack->mogadm("fsck", "start"), "started fsck");
}

sub unblock_fsck_queue {
    my ($sto, $expect) = @_;
    my $now = $sto->unix_timestamp;
    my $upd = sub { $sto->dbh->do("UPDATE file_to_queue SET nexttry = $now") };
    is($sto->retry_on_deadlock($upd), $expect, "unblocked fsck queue");
}

sub get_worker_pids {
    my ($admin, $worker) = @_;

    ok($admin->syswrite("!jobs\n"), "requested jobs");
    my @pids;

    while (my $line = $admin->getline) {
        last if $line =~ /^\.\r?\n/;

        if ($line =~ /^$worker pids (\d[\d+\s]*)\r?\n/) {
            @pids = split(/\s+/, $1);
        }
    }
    ok(scalar(@pids), "got pid(s) of $worker");

    return @pids;
}

sub shutdown_worker {
    my ($admin, $worker) = @_;

    watcher_wait_for(qr/Job $worker has only 0/, sub {
        $admin->syswrite("!to $worker :shutdown\r\n");
        like($admin->getline, qr/^Message sent to 1 children/, "tracker sent message to child");
        like($admin->getline, qr/^\./, "tracker ended transmission");
    });
}

wait_for_monitor($be);

my ($req, $rv, %opts, @paths, @fsck_log, $info);
my $ua = LWP::UserAgent->new;
my $key = "testkey";
my $dbh = $sto->dbh;

use Data::Dumper;

# upload a file and wait for replica to appear
{
    my $fh = $mogc->new_file($key, "1copy");
    print $fh "hello\n";
    ok(close($fh), "closed file");
}

# first obvious fucked-up case:  no devids even presumed to exist.
{
    $info = $mogc->file_info($key);
    is($info->{devcount}, 1, "ensure devcount is correct at start");

    # ensure repl queue is empty before destroying file_on
    wait_for_empty_queue("file_to_replicate", $dbh);

    my @devids = $sto->fid_devids($info->{fid});
    is(scalar(@devids), 1, "devids retrieved");
    is($sto->remove_fidid_from_devid($info->{fid}, $devids[0]), 1,
       "delete $key from file_on table");

    full_fsck($tmptrack, $dbh);
    do {
        @fsck_log = $sto->fsck_log_rows;
    } while (scalar(@fsck_log) < 3 && sleep(0.1));

    wait_for_empty_queue("file_to_queue", $dbh);
    @fsck_log = $sto->fsck_log_rows;

    my $nopa = $fsck_log[0];
    is($nopa->{evcode}, "NOPA", "evcode for no paths logged");

    # entering "desperate" mode
    my $srch = $fsck_log[1];
    is($srch->{evcode}, "SRCH", "evcode for start search logged");

    # wow, we actually found it!
    my $fond = $fsck_log[2];
    is($fond->{evcode}, "FOND", "evcode for start search logged");

    $info = $mogc->file_info($key);
    is($info->{devcount}, 1, "ensure devcount is correct at fsck end");
    @paths = $mogc->get_paths($key);
    is(scalar(@paths), 1, "get_paths returns correctly at fsck end");
}

# update class to require 2copies and have fsck fix it
{
    @paths = $mogc->get_paths($key);
    is(scalar(@paths), 1, "only one path exists before fsck");

    # _NOT_ using "updateclass" command since that enqueues for replication
    my $fid = MogileFS::FID->new($info->{fid});
    my $classid_2copies = $sto->get_classid_by_name($fid->dmid, "2copies");
    is($fid->update_class(classid => $classid_2copies), 1, "classid updated");

    full_fsck($tmptrack, $dbh);

    do {
        @paths = $mogc->get_paths($key);
    } while (scalar(@paths) == 1 and sleep(0.1));
    is(scalar(@paths), 2, "replicated from fsck");

    $info = $mogc->file_info($key);
    is($info->{devcount}, 2, "ensure devcount is updated by replicate");

    do {
        @fsck_log = $sto->fsck_log_rows;
    } while (scalar(@fsck_log) == 0 and sleep(0.1));

    my $povi = $fsck_log[0];
    is($povi->{evcode}, "POVI", "policy violation logged by fsck");

    my $repl = $fsck_log[1];
    is($repl->{evcode}, "REPL", "replication request logged by fsck");
}

# wrong devcount in file column, but otherwise everything is OK
{
    foreach my $wrong_devcount (13, 0, 1) {
        my $upd = sub {
            $dbh->do("UPDATE file SET devcount = ? WHERE fid = ?",
                     undef, $wrong_devcount, $info->{fid});
        };
        is($sto->retry_on_deadlock($upd), 1, "set improper devcount");

        $info = $mogc->file_info($key);
        is($info->{devcount}, $wrong_devcount, "devcount is set to $wrong_devcount");

        full_fsck($tmptrack, $dbh);

        do {
            $info = $mogc->file_info($key);
        } while ($info->{devcount} == $wrong_devcount && sleep(0.1));
        is($info->{devcount}, 2, "devcount is corrected by fsck");

        wait_for_empty_queue("file_to_queue", $dbh);
        @fsck_log = $sto->fsck_log_rows;
        is($fsck_log[0]->{evcode}, "BCNT", "bad count logged");
    }
}

# nuke a file from disk but keep the file_on row
{
    @paths = $mogc->get_paths($key);
    is(scalar(@paths), 2, "two paths returned from get_paths");
    $req = HTTP::Request->new(DELETE => $paths[0]);
    $rv = $ua->request($req);
    ok($rv->is_success, "DELETE successful");

    full_fsck($tmptrack, $dbh);
    do {
        @fsck_log = $sto->fsck_log_rows;
    } while (scalar(@fsck_log) < 2 && sleep(0.1));

    my $miss = $fsck_log[0];
    is($miss->{evcode}, "MISS", "missing file logged by fsck");

    my $repl = $fsck_log[1];
    is($repl->{evcode}, "REPL", "replication request logged by fsck");

    wait_for_empty_queue("file_to_replicate", $dbh);

    @paths = $mogc->get_paths($key);
    is(scalar(@paths), 2, "two paths returned from get_paths");
    foreach my $path (@paths) {
        $rv = $ua->get($path);
        is($rv->content, "hello\n", "GET successful on restored path");
    }
}

# change the length of a file from disk and have fsck correct it
{
    @paths = $mogc->get_paths($key);
    is(scalar(@paths), 2, "two paths returned from get_paths");
    $req = HTTP::Request->new(PUT => $paths[0]);
    $req->content("hello\r\n");
    $rv = $ua->request($req);
    ok($rv->is_success, "PUT successful");

    full_fsck($tmptrack, $dbh);
    do {
        @fsck_log = $sto->fsck_log_rows;
    } while (scalar(@fsck_log) < 2 && sleep(0.1));

    my $blen = $fsck_log[0];
    is($blen->{evcode}, "BLEN", "missing file logged by fsck");

    my $repl = $fsck_log[1];
    is($repl->{evcode}, "REPL", "replication request logged by fsck");

    wait_for_empty_queue("file_to_replicate", $dbh);

    @paths = $mogc->get_paths($key);
    is(scalar(@paths), 2, "two paths returned from get_paths");
    foreach my $path (@paths) {
        $rv = $ua->get($path);
        is($rv->content, "hello\n", "GET successful on restored path");
    }
}

# nuke a file completely and irreparably
{
    @paths = $mogc->get_paths($key);
    is(scalar(@paths), 2, "two paths returned from get_paths");
    foreach my $path (@paths) {
        $req = HTTP::Request->new(DELETE => $path);
        $rv = $ua->request($req);
        ok($rv->is_success, "DELETE successful");
    }

    full_fsck($tmptrack, $dbh);
    do {
        @fsck_log = $sto->fsck_log_rows;
    } while (scalar(@fsck_log) < 4 && sleep(0.1));

    is($fsck_log[0]->{evcode}, "MISS", "missing file logged for first path");
    is($fsck_log[1]->{evcode}, "MISS", "missing file logged for second path");
    is($fsck_log[2]->{evcode}, "SRCH", "desperate search attempt logged");
    is($fsck_log[3]->{evcode}, "GONE", "inability to fix FID logged");

    wait_for_empty_queue("file_to_queue", $dbh);
    $info = $mogc->file_info($key);

    is($info->{devcount}, 0, "devcount updated to zero");
    @paths = $mogc->get_paths($key);
    is(scalar(@paths), 0, "get_paths returns nothing");
}

# upload a file and wait for replica to appear
{
    my $fh = $mogc->new_file($key, "2copies");
    print $fh "hello\n";
    ok(close($fh), "closed file");

    do {
        $info = $mogc->file_info($key);
    } while ($info->{devcount} < 2);
    is($info->{devcount}, 2, "ensure devcount is correct at start");
}

# stall fsck with a non-responsive host
{
    is(kill("STOP", -$ms1->pid), 1, "send SIGSTOP to mogstored1");
    wait_for_monitor($be) foreach (1..3);

    shutdown_worker($admin, "job_master");
    shutdown_worker($admin, "fsck");

    $sto->retry_on_deadlock(sub { $sto->dbh->do("DELETE FROM file_to_queue") });
    watcher_wait_for(qr/\[fsck\(\d+\)] Connectivity problem reaching device/, sub {
        full_fsck($tmptrack, $dbh);
    });
    is($sto->file_queue_length(MogileFS::Config::FSCK_QUEUE), 1, "fsck queue still blocked");
}

# resume fsck when host is responsive again
{
    is(kill("CONT", -$ms1->pid), 1, "send SIGCONT to mogstored1");
    wait_for_monitor($be);

    shutdown_worker($admin, "fsck");

    # force fsck to wakeup and do work again
    unblock_fsck_queue($sto, 1);

    ok($admin->syswrite("!to fsck :wake_up\n"), "force fsck to wake up");
    ok($admin->getline, "got wakeup response 1");
    ok($admin->getline, "got wakeup response 2");

    foreach my $i (1..30) {
        last if $sto->file_queue_length(MogileFS::Config::FSCK_QUEUE) == 0;

        sleep 1;
    }

    is($sto->file_queue_length(MogileFS::Config::FSCK_QUEUE), 0, "fsck queue emptied");
}

# upload a file and wait for replica to appear
{
    my $fh = $mogc->new_file($key, "2copies");
    print $fh "hello\n";
    ok(close($fh), "closed file");

    do {
        $info = $mogc->file_info($key);
    } while ($info->{devcount} < 2);
    is($info->{devcount}, 2, "ensure devcount is correct at start");
}

# stall fsck with a non-responsive host
# resume fsck when host is responsive again
{
    is(kill("STOP", -$ms1->pid), 1, "send SIGSTOP to mogstored1 to stall");
    wait_for_monitor($be);

    watcher_wait_for(qr/\[fsck\(\d+\)] Connectivity problem reaching device/, sub {
        full_fsck($tmptrack, $dbh);
    });
    is($sto->file_queue_length(MogileFS::Config::FSCK_QUEUE), 1, "fsck queue still blocked");

    is(kill("CONT", -$ms1->pid), 1, "send SIGCONT to mogstored1 to resume");
    wait_for_monitor($be);

    # force fsck to wakeup and do work again
    unblock_fsck_queue($sto, 1);
    ok($admin->syswrite("!to fsck :wake_up\n"), "force fsck to wake up");
    ok($admin->getline, "got wakeup response 1");
    ok($admin->getline, "got wakeup response 2");

    foreach my $i (1..30) {
        last if $sto->file_queue_length(MogileFS::Config::FSCK_QUEUE) == 0;

        sleep 1;
    }

    is($sto->file_queue_length(MogileFS::Config::FSCK_QUEUE), 0, "fsck queue emptied");
}

# cleanup over-replicated file
{
    $info = $mogc->file_info($key);
    is($info->{devcount}, 2, "ensure devcount is correct at start");

    # _NOT_ using "updateclass" command since that enqueues for replication
    my $fid = MogileFS::FID->new($info->{fid});
    my $classid_1copy = $sto->get_classid_by_name($fid->dmid, "1copy");
    is($fid->update_class(classid => $classid_1copy), 1, "classid updated");

    full_fsck($tmptrack, $dbh);

    sleep(1) while $mogc->file_info($key)->{devcount} == 2;
    is($mogc->file_info($key)->{devcount}, 1, "too-happy file cleaned up");

    @fsck_log = $sto->fsck_log_rows;
    is($fsck_log[0]->{evcode}, "POVI", "policy violation logged");

    # replicator is requested to delete too-happy file
    is($fsck_log[1]->{evcode}, "REPL", "replication request logged");
}

# kill a device and replace it with another, without help from reaper
# this test may become impossible if monitor + reaper are merged...
{
    ok($mogc->update_class($key, "2copies"), "request 2 replicas again");
    do {
        $info = $mogc->file_info($key);
    } while ($info->{devcount} < 2);
    is($info->{devcount}, 2, "ensure devcount is correct at start");
    wait_for_empty_queue("file_to_replicate", $dbh);

    my (@reaper_pids) = get_worker_pids($admin, "reaper");
    is(scalar(@reaper_pids), 1, "only one reaper pid");
    my $reaper_pid = $reaper_pids[0];
    ok($reaper_pid, "got pid of reaper");

    # reaper is watchdog is 240s, and it wakes up in 5s intervals right now
    # so we should be safe from watchdog for now...
    ok(kill("STOP", $reaper_pid), "stopped reaper from running");

    ok($tmptrack->mogadm("device", "mark", "hostB", 2, "dead"), "mark dev2 as dead");
    ok($tmptrack->mogadm("device", "add", "hostB", 3), "created dev3 on hostB");
    wait_for_monitor($be);

    full_fsck($tmptrack, $dbh);

    sleep 1 while MogileFS::Config->server_setting("fsck_host");

    foreach my $i (1..30) {
        last if $sto->file_queue_length(MogileFS::Config::FSCK_QUEUE) == 0;
        sleep 1;
    }
    is($sto->file_queue_length(MogileFS::Config::FSCK_QUEUE), 0, "fsck queue empty");

    # fsck should've corrected what reaper missed
    @fsck_log = $sto->fsck_log_rows;
    is(scalar(@fsck_log), 1, "fsck log populated");
    is($fsck_log[0]->{evcode}, "REPL", "replication enqueued");

    ok(kill("CONT", $reaper_pid), "resumed reaper");
}

{
    ok($tmptrack->mogadm("fsck", "stop"), "stop fsck");

    foreach my $i (1..10) {
        my $fh = $mogc->new_file("k$i", "1copy");
        print $fh "$i\n";
        ok(close($fh), "closed file ($i)");
    }
    $info = $mogc->file_info("k10");

    ok($tmptrack->mogadm("settings", "set", "queue_rate_for_fsck", 1), "set queue_rate_for_fsck to 1");
    ok($tmptrack->mogadm("settings", "set", "queue_size_for_fsck", 1), "set queue_size_for_fsck to 1");

    wait_for_monitor($be) foreach (1..3);

    shutdown_worker($admin, "job_master");
    shutdown_worker($admin, "fsck");

    ok($tmptrack->mogadm("fsck", "clearlog"), "clear fsck log");
    ok($tmptrack->mogadm("fsck", "reset"), "reset fsck");
    $sto->retry_on_deadlock(sub { $sto->dbh->do("DELETE FROM file_to_queue") });
    ok($tmptrack->mogadm("fsck", "start"), "start fsck with slow queue rate");

    ok(MogileFS::Config->server_setting("fsck_host"), "fsck_host set");
    is(MogileFS::Config->server_setting("fsck_fid_at_end"), $info->{fid}, "fsck_fid_at_end matches");

    my $highest = undef;
    foreach my $i (1..100) {
        $highest = MogileFS::Config->server_setting("fsck_highest_fid_checked");
        last if defined $highest;
        sleep 0.1;
    }
    ok(defined($highest), "fsck_highest_fid_checked is set");
    like($highest, qr/\A\d+\z/, "fsck_highest_fid_checked is a digit");
    isnt($highest, $info->{fid}, "fsck is not running too fast");

    # wait for something to get fscked
    foreach my $i (1..100) {
        last if MogileFS::Config->server_setting("fsck_highest_fid_checked") != $highest;
        sleep 0.1;
    }

    my $old_highest = $highest;
    $highest = MogileFS::Config->server_setting("fsck_highest_fid_checked");
    isnt($highest, $old_highest, "moved to next FID");

    ok($tmptrack->mogadm("fsck", "stop"), "stop fsck");
    ok(! MogileFS::Config->server_setting("fsck_host"), "fsck_host unset");
    is(MogileFS::Config->server_setting("fsck_fid_at_end"), $info->{fid}, "fsck_fid_at_end matches");

    # resume paused fsck
    ok($tmptrack->mogadm("fsck", "start"), "restart fsck");
    $highest = MogileFS::Config->server_setting("fsck_highest_fid_checked");
    cmp_ok($highest, '>=', $old_highest, "fsck resumed without resetting fsck_highest_fid_checked");

    # wait for something to get fscked
    foreach my $i (1..200) {
        last if MogileFS::Config->server_setting("fsck_highest_fid_checked") != $highest;
        sleep 0.1;
    }

    $highest = MogileFS::Config->server_setting("fsck_highest_fid_checked");
    cmp_ok($highest, '>', $old_highest, "fsck continued to higher FID");
}

# upload new files, but ensure fsck does NOT reach them
{
    my $last_fid = $sto->max_fidid;

    foreach my $i (1..10) {
        my $fh = $mogc->new_file("z$i", "1copy");
        print $fh "$i\n";
        ok(close($fh), "closed file (z$i)");
    }

    # crank up fsck speed again
    ok($tmptrack->mogadm("settings", "set", "queue_rate_for_fsck", 100), "set queue_rate_for_fsck to 100");
    ok($tmptrack->mogadm("settings", "set", "queue_size_for_fsck", 100), "set queue_size_for_fsck to 100");

    sleep 0.1 while MogileFS::Config->server_setting("fsck_host");

    my $highest = MogileFS::Config->server_setting("fsck_highest_fid_checked");
    is($highest, $last_fid, "fsck didn't advance beyond what we started with");
}

done_testing();

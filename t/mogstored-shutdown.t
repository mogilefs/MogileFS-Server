# -*-perl-*-

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use IO::Socket::INET;

use MogileFS::Test;

unless ((`netstat -nap --inet` || "") =~ m!PID/Program!) {
    plan skip_all => "netstat output not how expected; skipping test.\n";
    exit 0;
}

my $TEST_IP = '127.0.1.1';

my $rv;

use File::Temp;
my $dir = File::Temp::tempdir( CLEANUP => 1 );
my $ms = eval { create_mogstored($TEST_IP, $dir, "--daemonize") };
unless (ok($ms, "started daemonized mogstored")) {
    # Must wait a moment on startup
    select undef, undef, undef, 0.5;
    # Now safe
    my $exist = eval { exist_pid() };
    warn "exist = $exist\n";
    if ($exist) {
        warn "killing existing test mogstored pid of $exist\n";
        kill 9, $exist;
    }
    die "wasn't able to start up.";
}

# what's its pid?
my $real_pid = exist_pid();

note "real_pid = $real_pid\n";
#scalar <STDIN>;

my $sock = try(5, 0.5, sub { IO::Socket::INET->new(PeerAddr => "$TEST_IP:7501",
                                                   Timeout  => 3) });
ok($sock, "got mgmt connection") or die;


print $sock "shutdown\n";

my $rin = '';
vec($rin,fileno($sock),1) = 1;
my $rout;
my $n = select($rout=$rin,undef,undef,2);
is($n, 1, "mgmt port readable");

unless ($n == 1) {
    kill 9, $real_pid;
    die "killed pid of $real_pid\n";
}

my $tries = 0;
my $alive;
while ($tries++ < 10 && ($alive = kill(0, $real_pid))) {
    select undef, undef, undef, 0.4;
}
ok(!$alive, "gone");


# dies when not able to find
sub exist_pid {
    my $netstat = `netstat -nap --inet`;
    my $ip = $TEST_IP;
    $ip =~ s/\./\\./g;
    unless ($netstat =~ m!${ip}:750[10].+LISTEN\s+(\d+)/!) {
        die "Couldn't find pid of daemonized process.\n";
    }
    return $1;
}

sub try {
    my ($tries, $delay, $code) = @_;
    my $try = 0;
    while ($try++ < $tries) {
        my $ret = $code->();
        return $ret if $ret;
        select undef, undef, undef, $delay;
    }
    return undef;
}

done_testing();

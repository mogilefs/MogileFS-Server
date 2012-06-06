package Mogstored::ChildProcess::IOStat;
use strict;
use base 'Mogstored::ChildProcess';

my $docroot;

my $iostat_cmd = "iostat -dx 1 30";
if ($^O =~ /darwin/) { $iostat_cmd =~ s/x// }

sub pre_exec_init {
    my $class = shift;

    close STDIN;
    close STDOUT;
    close STDERR;

    my $iostat_pipe_w = Mogstored->get_iostat_writer_pipe;

    # We may not be able to see errors beyond this point
    open STDIN, '<', '/dev/null'       or die "Couldn't open STDIN for reading from /dev/null";
    open STDOUT, '>&', $iostat_pipe_w  or die "Couldn't dup pipe for use as STDOUT";
    open STDERR, '>', '/dev/null'      or die "Couldn't open STDOUT for writing to /dev/null";

    $ENV{MOG_DOCROOT} = Perlbal->service('mogstored')->{docroot};
}

sub run {
    $docroot = $ENV{MOG_DOCROOT};
    die "\$ENV{MOG_DOCROOT} not set"                unless $docroot;
    die "\$ENV{MOG_DOCROOT} not set to a directory" unless -d $docroot;

    # (runs in exec'd child process)
    $0 = "mogstored [iostat]";
    select((select(STDOUT), $|++)[0]);

    my $iostat_pid;
    $SIG{TERM} = $SIG{INT} = sub {
        kill 9, $iostat_pid if $iostat_pid;
        exit(0);
    };

    my $check_for_parent = sub {
        # shut ourselves down if our parent mogstored
        # has gone away.
        my $ppid = getppid();
        unless ($ppid && kill(0,$ppid)) {
            kill 9, $iostat_pid if $iostat_pid;
            exit(0);
        }
    };

    my $get_iostat_fh = sub {
        while (1) {
            if ($iostat_pid = open (my $fh, "$iostat_cmd|")) {
                return $fh;
            }
            # TODO: try and find other paths to iostat
            $check_for_parent->();
            warn "Failed to open iostat: $!\n"; # this will just go to /dev/null, but will be straceable
            sleep 10;
        }
    };

    while (1) {
        my $iofh = $get_iostat_fh->();
        my $mog_sysid = mog_sysid_map();  # 5 (mogdevid) -> 2340 (os devid)
        my $dev_sysid = {};  # hashref, populated lazily:  { /dev/sdg => system dev_t }
        my (%devt_util, %devt_svctm, %devt_await);  # dev_t => 52.55
        my $init = 0;
        my (@columns, %column_map); # map an iostat column name to its array index
        while (<$iofh>) {
            if (m/^Device:/) {
                (%devt_util, %devt_await, %devt_svctm) = ( (), (), () );
                $init = 1;
                @columns = split /\s+/, $_;
                my $i = 0;
                for my $column (@columns) {
                    $column_map{$column} = $i++;
                }
                next;
            }
            next unless $init;
            if (m/^ (\S+) .*? ([\d.]+) \n/x) {
                my @components = split /\s+/, $_;
                my $devnode = '/dev/' . $components[$column_map{'Device:'}];
                unless (exists $dev_sysid->{$devnode}) {
                    $dev_sysid->{$devnode} = (stat($devnode))[6]; # rdev
                }
                my $devt = $dev_sysid->{$devnode};
                $devt_util{$devt} = $components[$column_map{'%util'}];
                $devt_svctm{$devt} = $components[$column_map{'svctm'}];
                $devt_await{$devt} = $components[$column_map{'await'}];

                next;
            }
            # blank line is the end.
            if (m!^\s*\n!) {
                $init = 0;
                my $ret = "";
                foreach my $mogdevid (sort { $a <=> $b } keys %$mog_sysid) {
                    my $devt = $mog_sysid->{$mogdevid};

                    my $await = defined $devt_await{$devt} ? $devt_await{$devt} : "-";
                    my $svctm = defined $devt_svctm{$devt} ? $devt_svctm{$devt} : "-";
                    my $util = defined $devt_util{$devt} ? $devt_util{$devt} : "-";
                    $ret .= "$mogdevid\t$util\t$await\t$svctm\t\n";
                }
                $ret .= ".\n";
                print $ret;

                $check_for_parent->();
                next;
            }
        }
    }

}

#  returns hashref of { 5 => dev_t device }  # mog_devid -> os_devid
sub mog_sysid_map {
    my $path = $docroot;
    $path =~ s!/$!!;

    # find all devices below us
    my @devnum;  # integer ids
    opendir(my $d, $path) or die "Failed to open docroot: $path: $!";
    @devnum = map { /^dev(\d+)$/ ? $1 : () } readdir($d);

    my $map = {};
    foreach my $mogdevid (@devnum) {
        my ($osdevid) = (stat("$path/dev$mogdevid"))[0];
        $map->{$mogdevid} = $osdevid;
    }

    if (lc($^O) eq 'linux') {
        # name_to_number and number_to_name are the data derived from /proc/partitions
        my %name_to_number; # ( hda1 => 769,  ... )
        my %number_to_name; # ( 769  => hda1, ... )

        if (open my $partitions, '<', '/proc/partitions') {
            <$partitions>; <$partitions>; # First two lines are for humans
            while (my $line = <$partitions>) {
                next unless $line =~ m/^ \s* (\d+) \s+ (\d+) \s+ \d+ \s+ (\S+) \s* $/x;
                my ($major, $minor, $devname) = ($1, $2, $3);
                my $devno = ($major << 8) + $minor;
                $name_to_number{$devname} = $devno;
                $number_to_name{$devno} = $devname;
            }
        } else {
            warn "Unable to open /proc/partitions: $!";
        }

        # Iterate over the hash { 1 => 768 } meaning (mogile device dev1 points to os device 768)
        foreach my $mogdevid (keys %$map) {
            # Look up the original device number
            my $original = $map->{$mogdevid};

            # See if there is a mapping to turn it into a device name (eg. hda1)
            my $devname = $number_to_name{$original} or next;

            # Pull off the new device name with a regex
            if (my ($newname) = $devname =~ m/^([hs]d\w+)\d+$/) {
                # Skip if we can't map it back to a device number
                my $newnum = $name_to_number{$newname} or next;
                $map->{$mogdevid} = $newnum;
            } elsif (my ($newname, undef) = $devname =~ m/^(cciss\/c\d+d\d+)(\w+)?$/) {
                my $newnum = $name_to_number{$newname} or next;
                $map->{$mogdevid} = $newnum;
            }
        }
    }
    return $map;
}

1;

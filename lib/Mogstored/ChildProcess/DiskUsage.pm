package Mogstored::ChildProcess::DiskUsage;
use strict;
use base 'Mogstored::ChildProcess';

my $docroot;

sub pre_exec_init {
    my $class = shift;
    $SIG{TERM} = 'DEFAULT'; # override custom one from earlier
    $ENV{MOG_DOCROOT} = Perlbal->service('mogstored')->{docroot};
}

sub run {
    $docroot = $ENV{MOG_DOCROOT};
    die "\$ENV{MOG_DOCROOT} not set"                unless $docroot;
    die "\$ENV{MOG_DOCROOT} not set to a directory" unless -d $docroot;

    # (runs in exec'd child process)
    $0 = "mogstored [diskusage]";
    select((select(STDOUT), $|++)[0]);

    my $start_ppid = getppid();

    # Discover whether or not we have GNU df.
    my $gnu_df = '';
    `df -P / 2>/dev/null >/dev/null`;
    if ($? eq 0) {
       $gnu_df = '-P';
    }

    while (1) {
        look_at_disk_usage($gnu_df);
        sleep 10;

        # shut ourselves down if our parent mogstored
        # has gone away.
        my $ppid = getppid();
        exit(0) unless $ppid == $start_ppid && kill(0,$ppid);
    }
}

sub look_at_disk_usage {
    my $err = sub { warn "$_[0]\n"; };
    my $path = $ENV{MOG_DOCROOT};
    $path =~ s!/$!!;
    my $gnu_df = shift;

    # find all devices below us
    my @devnum;
    if (opendir(D, $path)) {
        @devnum = grep { /^dev\d+$/ } readdir(D);
        closedir(D);
    } else {
        return $err->("Failed to open $path: $!");
    }

    foreach my $devnum (@devnum) {
        my $rval = `df $gnu_df -k $path/$devnum`;
        my $uperK = ($rval =~ /512-blocks/i) ? 2 : 1; # units per kB
        foreach my $l (split /\r?\n/, $rval) {
            next unless $l =~ /^(.+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(.+)\s+(.+)$/;
            my ($dev, $total, $used, $avail, $useper, $disk) = ($1, $2, $3, $4, $5, $6);

            unless ($disk =~ m!$devnum/?$!) {
                $disk = "$path/$devnum";
            }

            # FIXME: We're stupidly throwing away the 'avail' value here.
            # This causes mogilefs to run aground when used with ext
            # partitions using reserved space. Drop the reserved space from
            # the total, and in the future add available to the device table
            # and just use that.
            $total = $used + $avail;

            # create string to print
            my $now = time;
            my $output = {
                time      => time(),
                device    => $dev,    # /dev/sdh1
                total     => int($total / $uperK), # integer: total KiB blocks
                used      => int($used  / $uperK), # integer: used KiB blocks
                available => int($avail / $uperK),  # integer: available KiB blocks
                'use'     => $useper, # "45%"
                disk      => $disk,   # mount point of disk (/var/mogdata/dev8), or path if not a mount
            };

            if ($ENV{MOG_DEV_USAGE_VIA_DU}) {
                my $size = `du -k -c -s $path/$devnum`;
                if ($size =~ /^(\d+)/) {
                    $output->{used} = $1;
                }
            }

            # size of old file we'll be overwriting in place (we'll want
            # to pad with newlines/spaces, before we truncate it, for
            # minimizing races)
            my $ufile    = "$disk/usage";
            my $old_size = (-s $ufile) || 0;
            my $mode     = $old_size ? "+<" : ">";

            # string we'll be writing
            my $new_data = "";
            foreach (sort keys %$output) {
                $new_data .= "$_: $output->{$_}\n";
            }

            my $new_size = length $new_data;
            my $pad_len  = $old_size > $new_size ? ($old_size - $new_size) : 0;
            $new_data   .= "\n" x $pad_len;

            # write the file, all at once (with padding) then remove padding
            my $rv = open(my $fh, $mode, $ufile);
            unless ($rv) {
                $err->("Unable to open '$ufile' for writing: $!");
                next;
            }
            unless (syswrite($fh, $new_data)) {
                close($fh);
                $err->("Error writing to '$ufile': $!");
                next;
            }
            truncate($fh, $new_size) if $pad_len;
            close($fh);
        }
    }
}


1;

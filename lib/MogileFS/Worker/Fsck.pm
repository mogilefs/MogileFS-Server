package MogileFS::Worker::Fsck;

use strict;
use base 'MogileFS::Worker';
use fields (
            'last_stop_check',     # unixtime 'should_stop_running' last called
            'last_maxcheck_write', # unixtime maxcheck written
            'size_checker',        # subref which, given a DevFID, returns size of file
            'opt_nostat',          # bool: do we trust mogstoreds? skipping size stats?
            );
use MogileFS::Util qw(every error debug);
use MogileFS::Config;
use List::Util ();
use Time::HiRes ();

use constant SUCCESS => 0;
use constant TEMPORARY => 1;
use constant PERMANENT => 2;
use constant REPLICATE => 3;

use constant EV_NO_PATHS         => "NOPA";
use constant EV_POLICY_VIOLATION => "POVI";
use constant EV_FILE_MISSING     => "MISS";
use constant EV_BAD_LENGTH       => "BLEN";
use constant EV_CANT_FIX         => "GONE";
use constant EV_START_SEARCH     => "SRCH";
use constant EV_FOUND_FID        => "FOND";
use constant EV_RE_REPLICATE     => "REPL";
use constant EV_BAD_COUNT        => "BCNT";

use POSIX ();

my $nowish;  # approximate unixtime, updated once per loop.

sub watchdog_timeout { 120 }

sub work {
    my $self = shift;

    my $run_count = 0;

    # this can be CPU-intensive.  let's nice ourselves down.
    POSIX::nice(10);

    # <debug crap>
    my $running = 0; # start time
    my $n_check = 0; # items checked
    my $start = sub {
        return if $running;
        $running = $nowish = time();
    };
    my $stats = sub {
        return unless $running;
        my $elap = $nowish - $running;
        debug(sprintf("In %d secs, %d fids, %0.02f fids/sec\n", $elap, $n_check, ($n_check / ($elap || 1))));
    };
    my $last_beat = 0;
    my $beat = sub {
        return unless $nowish >= $last_beat + 5;
        $stats->();
        $last_beat = $nowish;
    };
    my $stop = sub {
        return unless $running;
        $stats->();
        debug("done.");
        $running = 0;
    };
    # </debug crap>

    my $sto         = Mgd::get_store();
    my $max_checked = 0;

    every(2.0, sub {
        my $sleep_set = shift;
        $nowish = time();
        local $Mgd::nowish = $nowish;

        # checking doesn't go well if the monitor job hasn't actively started
        # marking things as being available
        unless ($self->monitor_has_run) {
            # only warn on runs after the first.  gives the monitor job some time to work
            # before we throw a message.
            debug("waiting for monitor job to complete a cycle before beginning")
                if $run_count++ > 0;
            return;
        }

        my $queue_todo = $self->queue_todo('fsck');
        # This counts the same as a $self->still_alive;
        $self->send_to_parent('worker_bored 50 fsck');

        my @fids = ();
        while (my $todo = shift @{$queue_todo}) {
            my $fid = MogileFS::FID->new($todo->{fid});
            unless ($fid->exists) {
                # FID stopped existing before being checked.
                $sto->delete_fid_from_file_to_queue($fid->id, FSCK_QUEUE);
            }
            push(@fids, $fid);
        }
        return unless @fids;

        $self->{opt_nostat} = MogileFS::Config->server_setting('fsck_opt_policy_only')     || 0;
        MogileFS::FID->mass_load_devids(@fids);

        $self->init_size_checker(\@fids);

        # don't sleep in loop, next round, since we found stuff to work on
        # this round...
        $sleep_set->(0);

        my $new_max;
        my $hit_problem = 0;

        foreach my $fid (@fids) {
            if (!$self->check_fid($fid)) {
                # some connectivity problem... retry this fid later.
                # (don't dequeue it)
                $self->still_alive;
                sleep 5;
                next;
            }
            $sto->delete_fid_from_file_to_queue($fid->id, FSCK_QUEUE);
            $n_check++;
            $beat->();
        }
    });
}

# only write to server_settings table our position every 5 seconds
sub set_max_checked_lazy {
    my ($self, $nmax) = @_;
    return 0 if $nowish < ($self->{last_maxcheck_write} || 0) + 5;
    $self->{last_maxcheck_write} = $nowish;
    $self->set_max_checked($nmax);
}

sub set_max_checked {
    my ($self, $nmax) = @_;
    MogileFS::Config->set_server_setting('fsck_highest_fid_checked', $nmax);
}

# this version is accurate,
sub should_be_running {
    my $self = shift;
    my $fhost = MogileFS::Config->server_setting('fsck_host')
        or return;
    return $fhost eq MogileFS::Config->hostname;
}

# this version is sloppy, optimized for speed.  only checks db every 5 seconds.
sub should_stop_running {
    my $self = shift;
    return 0 if $nowish < ($self->{last_stop_check} || 0) + 5;
    $self->{last_stop_check} = $nowish;
    return ! $self->should_be_running;
}

# given a $fid (MogileFS::FID, with pre-populated ->devids data)
# return 0 if reachability problems.
# return 1 if fid was checked (regardless of there being problems or not)
#   if no problems, no action.
#   if problems, log & enqueue fixes
use constant STALLED => 0;
use constant HANDLED => 1;
sub check_fid {
    my ($self, $fid) = @_;

    my $fix = sub {
        my $fixed = eval { $self->fix_fid($fid) };
        if (! defined $fixed) {
            error("Fsck stalled for fid $fid: $@");
            return STALLED;
        }
        $fid->fsck_log(EV_CANT_FIX) if ! $fixed;

        # that might've all taken awhile, let's update our approximate time
        $nowish = $self->still_alive;
        return HANDLED;
    };

    # first obvious fucked-up case:  no devids even presumed to exist.
    unless ($fid->devids) {
        # first, log this weird condition.
        $fid->fsck_log(EV_NO_PATHS);

        # weird, schedule a fix (which will do a search over all
        # devices as a last-ditch effort to locate it)
        return $fix->();
    }

    # first, see if the assumed devids meet the replication policy for
    # the fid's class.
    unless ($fid->devids_meet_policy) {
        # log a policy violation
        $fid->fsck_log(EV_POLICY_VIOLATION);
        return $fix->();
    }

    # This is a simple fixup case
    unless (scalar($fid->devids) == $fid->devcount) {
        # log a bad count
        $fid->fsck_log(EV_BAD_COUNT);

        # TODO: We could fix this without a complete fix pass
        # $fid->update_devcount();
        return $fix->();
    }

    # in the fast case, do nothing else (don't check if assumed file
    # locations are actually there).  in the fast case, all we do is
    # check the replication policy, which is already done, so finish.
    return HANDLED if $self->{opt_nostat};

    # stat each device to see if it's still there.  on first problem,
    # stop and go into the slow(er) fix function.
    my $err;
    my $rv = $self->parallel_check_sizes([ $fid->devfids ], sub {
        my ($dfid, $disk_size) = @_;
        if (! defined $disk_size) {
            my $dev  = $dfid->device;
            error("Connectivity problem reaching device " . $dev->id . " on host " . $dev->host->ip . "\n");
            $err = "stalled";
            return 0;
        }
        return 1 if $disk_size == $fid->length;
        $err = "needfix";
        # Note: not doing fsck_log, as fix_fid will log status for each device.
        return 0;
    });

    if ($rv) {
        return HANDLED;
    } elsif ($err eq "stalled") {
        return STALLED;
    } elsif ($err eq "needfix") {
        return $fix->();
    } else {
        die "Unknown error checking fid sizes in parallel.\n";
    }
}

sub parallel_check_sizes {
    my ($self, $dflist, $cb) = @_;
    # serial, for now: (just prepping for future parallel future,
    # getting interface right)
    foreach my $df (@$dflist) {
        my $size = $self->size_on_disk($df);
        return 0 unless $cb->($df, $size);
    }
    return 1;
}

# this is the slow path.  if something above in check_fid finds
# something amiss in any way, we went the slow path on a fid and try
# really hard to fix the situation.
#
# return true if situation handled, 0 if nothing could be done.
# die on errors (like connectivity problems).
use constant CANT_FIX => 0;
sub fix_fid {
    my ($self, $fid) = @_;
    debug(sprintf("Fixing FID %d\n", $fid->id));

    # This should happen first, since the fid gets awkwardly reloaded...
    $fid->update_devcount;

    # make devfid objects from the devids that this fid is on,
    my @dfids = map { MogileFS::DevFID->new($_, $fid) } $fid->devids;

    # track all known good copies (dev objects), as well as all bad
    # copies (places it should've been, but isn't)
    my @good_devs;
    my @bad_devs;
    my %already_checked;  # devid -> 1.

    my $check_dfids = sub {
        my $is_desperate_mode = shift;

        # stat all devices.
        foreach my $dfid (@dfids) {
            my $dev = $dfid->device;
            next if $already_checked{$dev->id}++;

            my $disk_size = $self->size_on_disk($dfid);
            die "dev " . $dev->id . " unreachable" unless defined $disk_size;

            if ($disk_size == $fid->length) {
                push @good_devs, $dfid->device;
                # if we were doing a desperate search, one is enough, we can stop now!
                return if $is_desperate_mode;
                next;
            }

            # don't log in desperate mode, as we'd have "file missing!" log entries
            # for every device in the normal case, which is expected.
            unless ($is_desperate_mode) {
                if ($disk_size == -1) {
                    $fid->fsck_log(EV_FILE_MISSING, $dev);
                } else {
                    $fid->fsck_log(EV_BAD_LENGTH, $dev);
                }
            }

            push @bad_devs, $dfid->device;
        }
    };

    $check_dfids->();

    # if we didn't find it anywhere, let's go do an exhaustive search over
    # all devices, looking for it...
    unless (@good_devs) {
        # replace @dfids with list of all (alive) devices.  dups will be ignored by
        # check_dfids
        $fid->fsck_log(EV_START_SEARCH);
        @dfids = List::Util::shuffle(
                                     map  { MogileFS::DevFID->new($_, $fid)  }
                                     grep { $_->dstate->should_fsck_search_on }
                                     MogileFS::Device->devices
                                     );
        $check_dfids->("desperate");

        # still can't fix it?
        return CANT_FIX unless @good_devs;

        # wow, we actually found it!
        $fid->fsck_log(EV_FOUND_FID);
        $fid->note_on_device($good_devs[0]); # at least one good one.

        # fall through to check policy (which will most likely be
        # wrong, with only one file_on record...) and re-replicate
    }

    # remove the file_on mappings for devices that were bogus/missing.
    foreach my $bdev (@bad_devs) {
        error("removing file_on mapping for fid=" . $fid->id . ", dev=" . $bdev->id);
        $fid->forget_about_device($bdev);
    }

    # in case the devcount or similar was fixed.
    $fid->want_reload;

    # Note: this will reload devids, if they called 'note_on_device'
    # or 'forget_about_device'
    unless ($fid->devids_meet_policy) {
        $fid->enqueue_for_replication;
        $fid->fsck_log(EV_RE_REPLICATE);
        return HANDLED;
    }
    
    # Clean up the device count if it's wrong
    unless(scalar($fid->devids) == $fid->devcount) {
        $fid->update_devcount();
        $fid->fsck_log(EV_BAD_COUNT);
    }

    return HANDLED;
}

sub init_size_checker {
    my ($self, $fidlist) = @_;

    $self->still_alive;

    my $lo_fid = $fidlist->[0]->id;
    my $hi_fid = $fidlist->[-1]->id;

    my %size;           # $devid -> { $fid -> $size }
    my %tried_bulkstat; # $devid -> 1

    $self->{size_checker} = sub {
        my $dfid  = shift;
        my $devid = $dfid->devid;

        if (my $map = $size{$devid}) {
            return $map->{$dfid->fidid} || 0;
        }

        unless ($tried_bulkstat{$devid}++) {
            my $mogconn = $dfid->device->host->mogstored_conn;
            my $sock    = $mogconn->sock(5);
            my $good = 0;
            my $unknown_cmd = 0;
            if ($sock) {
                my $cmd = "fid_sizes $lo_fid-$hi_fid $devid\n";
                print $sock $cmd;
                my $map = {};
                while (my $line = <$sock>) {
                    if ($line =~ /^\./) {
                        $good = 1;
                        last;
                    } elsif ($line =~ /^(\d+)\s+(\d+)\s+(\d+)/) {
                        my ($res_devid, $res_fid, $size) = ($1, $2, $3);
                        last unless $res_devid == $devid;
                        $map->{$res_fid} = $size;
                    } elsif ($line =~ /^ERR/) {
                        $unknown_cmd = 1;
                        last;
                    } else {
                        last;
                    }
                }

                # we only update our $nowish (approximate time) lazily, when we
                # know time might've advanced (like during potentially slow RPC call)
                $nowish = $self->still_alive;

                if ($good) {
                    $size{$devid} = $map;
                    return $map->{$dfid->fidid} || 0;
                } elsif (!$unknown_cmd) {
                    # mogstored connection is unknown state... can't
                    # trust it, so close it.
                    $mogconn->mark_dead;
                }
            }
            error("fid_sizes mogstored cmd unavailable for dev $devid; using slower method");
        }

        # slow case (not using new command)
        $nowish = $self->still_alive;
        return $dfid->size_on_disk;
    };
}

# returns 0 on missing,
# undef on connectivity error,
# else size of file on disk (after HTTP HEAD or mogstored stat)
sub size_on_disk {
    my ($self, $dfid) = @_;
    return $dfid->size_on_disk;
    # Mass checker is disabled for now... doesn't run on our production
    # hosts due to massive gaps in the fids. Instead we make the process
    # parallel and will rework it later.
    #return $self->{size_checker}->($dfid);
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:

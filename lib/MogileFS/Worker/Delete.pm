package MogileFS::Worker::Delete;
# deletes files

use strict;
use base 'MogileFS::Worker';
use MogileFS::Util qw(error);
use MogileFS::Server;

# we select 1000 but only do a random 100 of them, to allow
# for stateless parallelism
use constant LIMIT => 1000;
use constant PER_BATCH => 100;

# TODO: use LWP and persistent connections to do deletes.  less local ports used.

sub new {
    my ($class, $psock) = @_;
    my $self = fields::new($class);
    $self->SUPER::new($psock);

    return $self;
}

sub watchdog_timeout { 120 }

sub work {
    my $self = shift;

    my $sleep_for = 0; # we sleep longer and longer until we hit max_sleep
    my $sleep_max = 5; # max sleep when there's nothing to do.
    
    my $old_queue_check   = 0; # next time to check the old queue.
    my $old_queue_backoff = 0; # backoff index

    while (1) {
        $self->send_to_parent("worker_bored 50 delete");
        $self->read_from_parent(1);
        $self->validate_dbh;

        # call our workers, and have them do things
        #    RETVAL = 0; I think I am done working for now
        #    RETVAL = 1; I have more work to do
        my $tempres = $self->process_tempfiles;
        my $delres;
        if (time() > $old_queue_check) {
            $self->reenqueue_delayed_deletes;
            $delres = $self->process_deletes;
            # if we did no work, crawl the backoff.
            if ($delres) {
                $old_queue_backoff = 0;
                $old_queue_check   = 0;
            } else {
                $old_queue_check = time() + $old_queue_backoff
                    if $old_queue_backoff > 360;
                $old_queue_backoff++ unless $old_queue_backoff > 1800;
            }
        }

        my $delres2 = $self->process_deletes2;

        # unless someone did some work, let's sleep
        unless ($tempres || $delres || $delres2) {
            $sleep_for++ if $sleep_for < $sleep_max;
            sleep $sleep_for;
        } else {
            $sleep_for = 0;
        }
    }

}

sub process_tempfiles {
    my $self = shift;
    # also clean the tempfile table
    #mysql> select * from tempfile where createtime < unix_timestamp() - 86400 limit 50;
    #+--------+------------+---------+------+---------+--------+
    #| fid    | createtime | classid | dmid | dkey    | devids |
    #+--------+------------+---------+------+---------+--------+
    #|   3253 | 1149451058 |       1 |    1 | file574 | 1,2    |
    #|   4559 | 1149451156 |       1 |    1 | file83  | 1,2    |
    #|  11024 | 1149451697 |       1 |    1 | file836 | 2,1    |
    #|  19885 | 1149454542 |       1 |    1 | file531 | 1,2    |

    # BUT NOTE:
    #    the fids might exist on one of the devices in devids column if we assigned them those,
    #    they wrote some to one of them, then they died or for whatever reason didn't create_close
    #    to use, so we shouldn't delete from tempfile before going on a hunt of the missing fid.
    #    perhaps we should just add to the file_on table for both devids, and let the regular delete
    #    process discover via 404 that they're not there.
    # so we should:
    #    select fid, devids from tempfile where createtime < unix_timestamp() - 86400
    #    add file_on rows for both of those,
    #    add fid to fids_to_delete table,
    #    delete from tempfile where fid=?


    # dig up some temporary files to purge
    my $sto = Mgd::get_store();
    my $too_old = int($ENV{T_TEMPFILE_TOO_OLD} || 3600);
    my $tempfiles = $sto->old_tempfiles($too_old);
    return 0 unless $tempfiles && @$tempfiles;

    # insert the right rows into file_on and file_to_delete and remove the
    # now expunged (or soon to be) rows from tempfile
    my (@devfids, @fidids);
    foreach my $row (@$tempfiles) {

        # If FID is still loadable, we've arrived here due to a bug or race
        # condition elsewhere. Remove the tempfile row but don't delete the
        # file!
        my $fidid = $row->[0];
        my $fid = MogileFS::FID->new($fidid);
        if ($fid->exists) {
            $sto->delete_tempfile_row($fidid);
            next;
        }
        push @fidids, $fidid;

        # sanity check the string column.
        my $devids = $row->[1];
        unless ($devids =~ /^(\d+)(,\d+)*$/) {
            $devids = "";
        }

        foreach my $devid (split /,/, $devids) {
            push @devfids, MogileFS::DevFID->new($devid, $row->[0]);
        }
    }

    # We might've done no work due to discovering the tempfiles are real.
    return 0 unless @fidids;

    $sto->mass_insert_file_on(@devfids);
    $sto->enqueue_fids_to_delete2(@fidids);
    $sto->dbh->do("DELETE FROM tempfile WHERE fid IN (" . join(',', @fidids) . ")");
    return 1;
}

# new style delete queueing. I'm not putting a lot of effort into commonizing
# code between the old one and the new one. Feel free to send a patch!
sub process_deletes2 {
    my $self = shift;

    my $sto = Mgd::get_store();

    my $queue_todo = $self->queue_todo('delete');
    unless (@$queue_todo) {
        # No work.
        return 0;
    }

    while (my $todo = shift @$queue_todo) {
        $self->still_alive;

        # load all the devids related to this fid, and delete.
        my $fid    = MogileFS::FID->new($todo->{fid});
        my $fidid  = $fid->id;
        my @devids = $fid->devids;
        my %devids = map { $_ => 1 } @devids;


        for my $devid (@devids) {
            my $dev = $devid ? Mgd::device_factory()->get_by_id($devid) : undef;
            error("deleting fid $fidid, on devid ".($devid || 'NULL')."...") if $Mgd::DEBUG >= 2;
            unless ($dev) {
                next;
            }
            if ($dev->dstate->is_perm_dead) {
                $sto->remove_fidid_from_devid($fidid, $devid);
                delete $devids{$devid};
                next;
            }
            # devid is observed down/readonly: delay for at least
            # 10 minutes.
            unless ($dev->observed_writeable) {
                $sto->reschedule_file_to_delete2_relative($fidid,
                    60 * (10 + $todo->{failcount}));
                next;
            }
            # devid is marked readonly/down/etc: delay for 
            # at least 1 hour.
            unless ($dev->can_delete_from) {
                $sto->reschedule_file_to_delete2_relative($fidid,
                    60 * 60 * (1 + $todo->{failcount}));
                next;
            }

            my $dfid = MogileFS::DevFID->new($dev, $fidid);
            my $path = $dfid->url;

            # dormando: "There are cases where url can return undefined,
            # Mogile appears to try to replicate to bogus devices
            # sometimes?"
            unless ($path) {
                error("in deleter, url(devid=$devid, fid=$fidid) returned nothing");
                next;
            }

            my $urlparts = MogileFS::Util::url_parts($path);

            # hit up the server and delete it
            # TODO: (optimization) use MogileFS->get_observed_state and don't 
            # try to delete things known to be down/etc
            my $sock = IO::Socket::INET->new(PeerAddr => $urlparts->[0],
                                             PeerPort => $urlparts->[1],
                                             Timeout => 2);
            # this used to mark the device as down for the whole tracker.
            # if the device is actually down, we can struggle until the
            # monitor job figures it out... otherwise an occasional timeout
            # due to high load will prevent delete from working at all.
            unless ($sock) {
                $sto->reschedule_file_to_delete2_relative($fidid,
                    60 * 60 * (1 + $todo->{failcount}));
                next;
            }

            # send delete request
            error("Sending delete for $path") if $Mgd::DEBUG >= 2;

            $sock->write("DELETE $urlparts->[2] HTTP/1.0\r\n\r\n");
            my $response = <$sock>;
            if ($response =~ m!^HTTP/\d+\.\d+\s+(\d+)!) {
                if (($1 >= 200 && $1 <= 299) || $1 == 404) {
                    # effectively means all went well
                    $sto->remove_fidid_from_devid($fidid, $devid);
                    delete $devids{$devid};
                } else {
                    # remote file system error?  mark node as down
                    my $httpcode = $1;
                    error("Error: unlink failure: $path: HTTP code $httpcode");

                    $sto->reschedule_file_to_delete2_relative($fidid,
                        60 * 30 * (1 + $todo->{failcount}));
                    next;
                }
            } else {
                error("Error: unknown response line deleting $path: $response");
            }
        }

        # fid has no pants.
        unless (keys %devids) {
            $sto->delete_fid_from_file_to_delete2($fidid);
            next;
        }
    }

    # did work.
    return 1;
}

sub process_deletes {
    my $self = shift;

    my $sto = Mgd::get_store();
    my $dbh = $sto->dbh;

    my $delmap = $dbh->selectall_arrayref("SELECT fd.fid, fo.devid ".
                                          "FROM file_to_delete fd ".
                                          "LEFT JOIN file_on fo ON fd.fid=fo.fid ".
                                          "LIMIT " . LIMIT);
    my $count = $delmap ? scalar @$delmap : 0;
    return 0 unless $count;

    my $done = 0;
    foreach my $dm (List::Util::shuffle(@$delmap)) {
        last if ++$done > PER_BATCH;

        $self->still_alive;
        my ($fid, $devid) = @$dm;
        error("deleting fid $fid, on devid ".($devid || 'NULL')."...") if $Mgd::DEBUG >= 2;

        my $done_with_fid = sub {
            my $reason = shift;
            $dbh->do("DELETE FROM file_to_delete WHERE fid=?", undef, $fid);
            $sto->condthrow("Failure to delete from file_to_delete for fid=$fid");
        };

        my $done_with_devid = sub {
            my $reason = shift;
            $dbh->do("DELETE FROM file_on WHERE fid=? AND devid=?",
                     undef, $fid, $devid);
            $sto->condthrow("Failure to delete from file_on for $fid/$devid");
            die "Failed to delete from file_on: " . $dbh->errstr if $dbh->err;
        };

        my $reschedule_fid = sub {
            my ($secs, $reason) = (int(shift), shift);
            $sto->insert_ignore("INTO file_to_delete_later (fid, delafter) ".
                "VALUES (?,".$sto->unix_timestamp."+$secs)", undef,
                $fid);
            error("delete of fid $fid rescheduled: $reason") if $Mgd::DEBUG >= 2;
            $done_with_fid->("rescheduled");
        };

        # Cases:
        #   devid is null:  doesn't exist anywhere anymore, we're done with this fid.
        #   devid is observed down/readonly: delay for 10 minutes
        #   devid is marked readonly: delay for 2 hours
        #   devid is marked dead or doesn't exist: consider it deleted on this devid.

        # CASE: devid is null, which means we're done deleting all instances.
        unless (defined $devid) {
            $done_with_fid->("no_more_locations");
            next;
        }

        # CASE: devid is marked dead or doesn't exist: consider it deleted on this devid.
        # (Note: we're tolerant of '0' as a devid, due to old buggy version which
        # would sometimes put that in there)
        my $dev = $devid ? Mgd::device_factory()->get_by_id($devid) : undef;
        unless ($dev && $dev->exists) {
            $done_with_devid->("devid_doesnt_exist");
            next;
        }
        if ($dev->dstate->is_perm_dead) {
            $done_with_devid->("devid_marked_dead");
            next;
        }

        # CASE: devid is observed down/readonly: delay for 10 minutes
        unless ($dev->observed_writeable) {
            $reschedule_fid->(60 * 10, "not_observed_writeable");
            next;
        }

        # CASE: devid is marked readonly/down/etc: delay for 2 hours
        unless ($dev->can_delete_from) {
            $reschedule_fid->(60 * 60 * 2, "devid_marked_not_alive");
            next;
        }

        my $dfid = MogileFS::DevFID->new($dev, $fid);
        my $path = $dfid->url;

        # dormando: "There are cases where url can return undefined,
        # Mogile appears to try to replicate to bogus devices
        # sometimes?"
        unless ($path) {
            error("in deleter, url(devid=$devid, fid=$fid) returned nothing");
            next;
        }

        my $urlparts = MogileFS::Util::url_parts($path);

        # hit up the server and delete it
        # TODO: (optimization) use MogileFS->get_observed_state and don't try to delete things known to be down/etc
        my $sock = IO::Socket::INET->new(PeerAddr => $urlparts->[0],
                                         PeerPort => $urlparts->[1],
                                         Timeout => 2);
        unless ($sock) {
            # timeout or something, mark this device as down for now and move on
            $reschedule_fid->(60 * 60 * 2, "no_sock_to_hostid");
            next;
        }

        # send delete request
        error("Sending delete for $path") if $Mgd::DEBUG >= 2;

        $sock->write("DELETE $urlparts->[2] HTTP/1.0\r\n\r\n");
        my $response = <$sock>;
        if ($response =~ m!^HTTP/\d+\.\d+\s+(\d+)!) {
            if (($1 >= 200 && $1 <= 299) || $1 == 404) {
                # effectively means all went well
                $done_with_devid->("deleted");
            } else {
                # remote file system error?  mark node as down
                my $httpcode = $1;
                error("Error: unlink failure: $path: HTTP code $httpcode");
                $reschedule_fid->(60 * 30, "http_code_$httpcode");
                next;
            }
        } else {
            error("Error: unknown response line deleting $path: $response");
        }
    }

    # as far as we know, we have more work to do
    return 1;
}

sub reenqueue_delayed_deletes {
    my $self = shift;

    my $sto = Mgd::get_store();
    my $dbh = $sto->dbh;

    my @fidids = $sto->fids_to_delete_again
        or return;

    $sto->enqueue_fids_to_delete(@fidids);

    $dbh->do("DELETE FROM file_to_delete_later WHERE fid IN (" .
             join(",", @fidids) . ")");
    $sto->condthrow("reenqueue file_to_delete_later delete");
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:

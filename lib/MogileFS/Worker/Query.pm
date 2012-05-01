package MogileFS::Worker::Query;
# responds to queries from Mogile clients

use strict;
use warnings;

use base 'MogileFS::Worker';
use fields qw(querystarttime reqid callid);
use MogileFS::Util qw(error error_code first weighted_list
                      device_state eurl decode_url_args);
use MogileFS::HTTPFile;
use MogileFS::Rebalance;
use MogileFS::Config;
use MogileFS::Server;

sub new {
    my ($class, $psock) = @_;
    my $self = fields::new($class);
    $self->SUPER::new($psock);

    $self->{querystarttime} = undef;
    $self->{reqid}          = undef;
    $self->{callid}         = undef;
    return $self;
}

# no query should take 30 seconds, and we check in every 5 seconds.
sub watchdog_timeout { 30 }

# called by plugins to register a command in the namespace
sub register_command {
    my ($cmd, $sub) = @_;

    # validate the command, then convert it to the actual thing the user
    # will be calling
    return 0 unless $cmd =~ /^[\w\d]+$/;
    $cmd = "plugin_$cmd";

    # register in namespace with 'cmd_' which we will automatically find
    no strict 'refs';
    *{"cmd_$cmd"} = $sub;

    # all's well
    return 1;
}

sub work {
    my $self = shift;
    my $psock = $self->{psock};
    my $rin = '';
    vec($rin, fileno($psock), 1) = 1;
    my $buf;

    while (1) {
        my $rout;
        unless (select($rout=$rin, undef, undef, 5.0)) {
            $self->still_alive;
            next;
        }

        my $newread;
        my $rv = sysread($psock, $newread, 1024);
        if (!$rv) {
            if (defined $rv) {
                die "While reading pipe from parent, got EOF.  Parent's gone.  Quitting.\n";
            } else {
                die "Error reading pipe from parent: $!\n";
            }
        }
        $buf .= $newread;

        while ($buf =~ s/^(.+?)\r?\n//) {
            my $line = $1;
            if ($self->process_generic_command(\$line)) {
                $self->still_alive;  # no-op for watchdog
            } else {
                $self->validate_dbh;
                $self->process_line(\$line);
            }
        }
    }
}

sub process_line {
    my MogileFS::Worker::Query $self = shift;
    my $lineref = shift;

    # see what kind of command this is
    return $self->err_line('unknown_command')
        unless $$lineref =~ /^(\d+-\d+)?\s*(\S+)\s*(.*)/;

    $self->{reqid} = $1 || undef;
    my ($client_ip, $line) = ($2, $3);

    # set global variables for zone determination
    local $MogileFS::REQ_client_ip = $client_ip;

    # Use as array here, otherwise we get a string which breaks usage of
    # Time::HiRes::tv_interval further on.
    $self->{querystarttime} = [ Time::HiRes::gettimeofday() ];

    # fallback to normal command handling
    if ($line =~ /^(\w+)\s*(.*)/) {
        my ($cmd, $args) = ($1, $2);
        $cmd = lc($cmd);

        no strict 'refs';
        my $cmd_handler = *{"cmd_$cmd"}{CODE};
        my $args = decode_url_args(\$args);
        $self->{callid} = $args->{callid};
        if ($cmd_handler) {
            local $MogileFS::REQ_altzone = ($args->{zone} && $args->{zone} eq 'alt');
            eval {
                $cmd_handler->($self, $args);
            };
            if ($@) {
                my $errc = error_code($@);
                if ($errc eq "dup") {
                    return $self->err_line("dup");
                } else {
                    warn "Error: $@\n";
                    error("Error running command '$cmd': $@");
                    return $self->err_line("failure");
                }
            }
            return;
        }
    }

    return $self->err_line('unknown_command');
}

# this is a half-finished command.  in particular, errors tend to
# crash the parent or child or something.  it's a quick hack for a quick
# ops task that needs done.  note in particular how it reaches across
# package boundaries into an API that the Replicator probably doesn't
# want exposed.
sub cmd_httpcopy {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;
    my $sdevid = $args->{sdevid};
    my $ddevid = $args->{ddevid};
    my $fid    = $args->{fid};

    my $err;
    my $rv = MogileFS::Worker::Replicate::http_copy(sdevid => $sdevid,
                                                    ddevid => $ddevid,
                                                    fid    => $fid,
                                                    errref => \$err);
    if ($rv) {
        my $dfid = MogileFS::DevFID->new($ddevid, $fid);
        $dfid->add_to_db
            or return $self->err_line("copy_err", "failed to add link to database");
        return $self->ok_line;
    } else {
        return $self->err_line("copy_err", $err);
    }
}

# returns 0 on error, or dmid of domain
sub check_domain {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $domain = $args->{domain};

    return $self->err_line("no_domain") unless defined $domain && length $domain;

    # validate domain
    my $dmid = eval { Mgd::domain_factory()->get_by_name($domain)->id } or
        return $self->err_line("unreg_domain");

    return $dmid;
}

sub cmd_sleep {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;
    sleep($args->{duration} || 10);
    return $self->ok_line;
}

sub cmd_test {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;
    die "Crashed on purpose" if $args->{crash};
    return $self->ok_line;
}

sub cmd_clear_cache {
    my MogileFS::Worker::Query $self = shift;

    $self->forget_that_monitor_has_run;
    $self->send_to_parent(":refresh_monitor");
    $self->wait_for_monitor;

    return $self->ok_line(@_);
}

sub cmd_create_open {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # has to be filled out for some plugins
    $args->{dmid} = $self->check_domain($args)
        or return $self->err_line('domain_not_found');

    # first, pass this to a hook to do any manipulations needed
    eval {MogileFS::run_global_hook('cmd_create_open', $args)};

    return $self->err_line("plugin_aborted", "$@")
        if $@;

    # validate parameters
    my $dmid = $args->{dmid};
    my $key = $args->{key} || "";
    my $multi = $args->{multi_dest} ? 1 : 0;

    # optional profiling of stages, if $args->{debug_profile}
    my @profpoints;  # array of [point,hires-starttime]
    my $profstart = sub {
        my $pt = shift;
        push @profpoints, [$pt, Time::HiRes::time()];
    };
    $profstart = sub {} unless $args->{debug_profile};
    $profstart->("begin");

    # we want it to be undef if not explicit, else force to numeric
    my $exp_fidid = $args->{fid} ? int($args->{fid}) : undef;

    # get DB handle
    my $sto = Mgd::get_store();

    # figure out what classid this file is for
    my $class = $args->{class} || "";
    my $classid = 0;
    if (length($class)) {
        $classid = eval { Mgd::class_factory()->get_by_name($dmid, $class)->id }
            or return $self->err_line("unreg_class");
    }

    # if we haven't heard from the monitoring job yet, we need to chill a bit
    # to prevent a race where we tell a user that we can't create a file when
    # in fact we've just not heard from the monitor
    $profstart->("wait_monitor");
    $self->wait_for_monitor;

    $profstart->("find_deviceid");

    my @devices;

    unless (MogileFS::run_global_hook('cmd_create_open_order_devices', [Mgd::device_factory()->get_all], \@devices)) {
        @devices = sort_devs_by_freespace(Mgd::device_factory()->get_all);
    }

    # find suitable device(s) to put this file on.
    my @dests; # MogileFS::Device objects which are suitable

    while (scalar(@dests) < ($multi ? 3 : 1)) {
        my $ddev = shift @devices;

        last unless $ddev;
        next unless $ddev->not_on_hosts(map { $_->host } @dests);

        push @dests, $ddev;
    }
    return $self->err_line("no_devices") unless @dests;

    my $fidid = eval {
        $sto->register_tempfile(
                                fid     => $exp_fidid, # may be undef/NULL to mean auto-increment
                                dmid    => $dmid,
                                key     => $key,
                                classid => $classid,
                                devids  => join(',', map { $_->id } @dests),
                                );
    };
    unless ($fidid) {
        my $errc = error_code($@);
        return $self->err_line("fid_in_use") if $errc eq "dup";
        warn "Error registering tempfile: $@\n";
        return $self->err_line("db");
    }

    # make sure directories exist for client to be able to PUT into
    foreach my $dev (@dests) {
        $profstart->("vivify_dir_on_dev" . $dev->id);
        my $dfid = MogileFS::DevFID->new($dev, $fidid);
        $dfid->vivify_directories;
    }

    $profstart->("end");

    # common reply variables
    my $res = {
        fid => $fidid,
    };

    # add profiling data
    if (@profpoints) {
        $res->{profpoints} = 0;
        for (my $i=0; $i<$#profpoints; $i++) {
            my $ptnum = ++$res->{profpoints};
            $res->{"prof_${ptnum}_name"} = $profpoints[$i]->[0];
            $res->{"prof_${ptnum}_time"} =
                sprintf("%0.03f",
                        $profpoints[$i+1]->[1] - $profpoints[$i]->[1]);
        }
    }

    # add path info
    if ($multi) {
        my $ct = 0;
        foreach my $dev (@dests) {
            $ct++;
            $res->{"devid_$ct"} = $dev->id;
            $res->{"path_$ct"} = MogileFS::DevFID->new($dev, $fidid)->url;
        }
        $res->{dev_count} = $ct;
    } else {
        $res->{devid} = $dests[0]->id;
        $res->{path}  = MogileFS::DevFID->new($dests[0], $fidid)->url;
    }

    return $self->ok_line($res);
}

sub sort_devs_by_freespace {
    my @devices_with_weights = map {
        [$_, 100 * $_->percent_free]
    } sort {
        $b->percent_free <=> $a->percent_free;
    } grep {
        $_->should_get_new_files;
    } @_;

    my @list =
        MogileFS::Util::weighted_list(splice(@devices_with_weights, 0, 20));

    return @list;
}

sub cmd_create_close {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # has to be filled out for some plugins
    $args->{dmid} = $self->check_domain($args)
        or return $self->err_line('domain_not_found');

    # call out to a hook that might modify the arguments for us
    MogileFS::run_global_hook('cmd_create_close', $args);

    # late validation of parameters
    my $dmid  = $args->{dmid};
    my $key   = $args->{key};
    my $fidid = $args->{fid}    or return $self->err_line("no_fid");
    my $devid = $args->{devid}  or return $self->err_line("no_devid");
    my $path  = $args->{path}   or return $self->err_line("no_path");
    my $checksum = $args->{checksum};

    if ($checksum) {
        $checksum = eval { MogileFS::Checksum->from_string($fidid, $checksum) };
        return $self->err_line("invalid_checksum_format") if $@;
    }

    my $fid  = MogileFS::FID->new($fidid);
    my $dfid = MogileFS::DevFID->new($devid, $fid);

    # is the provided path what we'd expect for this fid/devid?
    return $self->err_line("bogus_args")
        unless $path eq $dfid->url;

    my $sto = Mgd::get_store();

    # find the temp file we're closing and making real.  If another worker
    # already has it, bail out---the client closed it twice.
    # this is racy, but the only expected use case is a client retrying.
    # should still be fixed better once more scalable locking is available.
    my $trow = $sto->delete_and_return_tempfile_row($fidid) or
        return $self->err_line("no_temp_file");

    # Protect against leaving orphaned uploads.
    my $failed = sub {
        $dfid->add_to_db;
        $fid->delete;
    };

    unless ($trow->{devids} =~ m/\b$devid\b/) {
        $failed->();
        return $self->err_line("invalid_destdev", "File uploaded to invalid dest $devid. Valid devices were: " . $trow->{devids});
    }

    # if a temp file is closed without a provided-key, that means to
    # delete it.
    unless (defined $key && length($key)) {
        $failed->();
        return $self->ok_line;
    }

    # get size of file and verify that it matches what we were given, if anything
    my $httpfile = MogileFS::HTTPFile->at($path);
    my $size = $httpfile->size;

    # size check is optional? Needs to support zero byte files.
    $args->{size} = -1 unless $args->{size};
    if (!defined($size) || $size == MogileFS::HTTPFile::FILE_MISSING) {
        # storage node is unreachable or the file is missing
        my $type    = defined $size ? "missing" : "cantreach";
        my $lasterr = MogileFS::Util::last_error();
        $failed->();
        return $self->err_line("size_verify_error", "Expected: $args->{size}; actual: 0 ($type); path: $path; error: $lasterr")
    }

    if ($args->{size} > -1 && ($args->{size} != $size)) {
        $failed->();
        return $self->err_line("size_mismatch", "Expected: $args->{size}; actual: $size; path: $path")
    }

    # checksum validation is optional as it can be very expensive
    # However, we /always/ verify it if the client wants us to, even
    # if the class does not enforce or store it.
    if ($checksum && $args->{checksumverify}) {
        my $alg = $checksum->hashname;
        my $actual = $httpfile->digest($alg, sub { $self->still_alive });
        if ($actual ne $checksum->{checksum}) {
            $failed->();
            $actual = "$alg:" . unpack("H*", $actual);
            return $self->err_line("checksum_mismatch",
                           "Expected: $checksum; actual: $actual; path: $path");
        }
    }

    # see if we have a fid for this key already
    my $old_fid = MogileFS::FID->new_from_dmid_and_key($dmid, $key);
    if ($old_fid) {
        # Fail if a file already exists for this fid.  Should never
        # happen, as it should not be possible to close a file twice.
        return $self->err_line("fid_exists")
            unless $old_fid->{fidid} != $fidid;

        $old_fid->delete;
    }

    # TODO: check for EIO?

    # insert file_on row
    $dfid->add_to_db;

    $checksum->maybe_save($dmid, $trow->{classid}) if $checksum;

    $sto->replace_into_file(
                            fidid   => $fidid,
                            dmid    => $dmid,
                            key     => $key,
                            length  => $size,
                            classid => $trow->{classid},
                            );

    # mark it as needing replicating:
    $fid->enqueue_for_replication();

    if ($fid->update_devcount) {
        # call the hook - if this fails, we need to back the file out
        my $rv = MogileFS::run_global_hook('file_stored', $args);
        if (defined $rv && ! $rv) { # undef = no hooks, 1 = success, 0 = failure
            $fid->delete;
            return $self->err_line("plugin_aborted");
        }

        # all went well
        return $self->ok_line;
    } else {
        # FIXME: handle this better
        return $self->err_line("db_error");
    }
}

sub cmd_updateclass {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    $args->{dmid} = $self->check_domain($args)
        or return $self->err_line('domain_not_found');

    my $dmid  = $args->{dmid};
    my $key   = $args->{key}        or return $self->err_line("no_key");
    my $class = $args->{class}      or return $self->err_line("no_class");

    my $classid = eval { Mgd::class_factory()->get_by_name($dmid, $class)->id }
        or return $self->err_line('class_not_found');

    my $fid = MogileFS::FID->new_from_dmid_and_key($dmid, $key)
        or return $self->err_line('invalid_key');

    my @devids = $fid->devids;
    return $self->err_line("no_devices") unless @devids;

    if ($fid->classid != $classid) {
        $fid->update_class(classid => $classid);
        $fid->enqueue_for_replication();
    }

    return $self->ok_line;
}

sub cmd_delete {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # validate domain for plugins
    $args->{dmid} = $self->check_domain($args)
        or return $self->err_line('domain_not_found');

    # now invoke the plugin, abort if it tells us to
    my $rv = MogileFS::run_global_hook('cmd_delete', $args);
    return $self->err_line('plugin_aborted')
        if defined $rv && ! $rv;

    # validate parameters
    my $dmid = $args->{dmid};
    my $key = $args->{key} or return $self->err_line("no_key");

    # is this fid still owned by this key?
    my $fid = MogileFS::FID->new_from_dmid_and_key($dmid, $key)
        or return $self->err_line("unknown_key");

    $fid->delete;

    return $self->ok_line;
}

# Takes either domain/dkey or fid and tries to return as much as possible.
sub cmd_file_debug {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;
    # Talk to the master since this is "debug mode"
    my $sto = Mgd::get_store();
    my $ret = {};

    # If a FID is provided, just use that.
    my $fid;
    my $fidid;
    if ($args->{fid}) {
        $fidid = $args->{fid}+0;
        # It's not fatal if we don't find the row here.
        $fid = $sto->file_row_from_fidid($args->{fid}+0);
    } else {
        # If not, require dmid/dkey and pick up the fid from there.
        $args->{dmid} = $self->check_domain($args)
            or return $self->err_line('domain_not_found');
        return $self->err_line("no_key") unless $args->{key};
        
        # now invoke the plugin, abort if it tells us to
        my $rv = MogileFS::run_global_hook('cmd_file_debug', $args);
        return $self->err_line('plugin_aborted')
            if defined $rv && ! $rv;

        $fid = $sto->file_row_from_dmid_key($args->{dmid}, $args->{key});
        return $self->err_line("unknown_key") unless $fid;
        $fidid = $fid->{fid};
    }

    if ($fid) {
        $fid->{domain}   = Mgd::domain_factory()->get_by_id($fid->{dmid})->name;
        $fid->{class}    = Mgd::class_factory()->get_by_id($fid->{dmid},
            $fid->{classid})->name;
    }

    # Fetch all of the queue data.
    my $tfile = $sto->tempfile_row_from_fid($fidid);
    my $repl  = $sto->find_fid_from_file_to_replicate($fidid);
    my $del   = $sto->find_fid_from_file_to_delete2($fidid);
    my $reb   = $sto->find_fid_from_file_to_queue($fidid, REBAL_QUEUE);
    my $fsck  = $sto->find_fid_from_file_to_queue($fidid, FSCK_QUEUE);

    # Fetch file_on rows, and turn into paths.
    my @devids = $sto->fid_devids($fidid);
    for my $devid (@devids) {
        # Won't matter if we can't make the path (dev is dead/deleted/etc)
        eval {
            my $dfid = MogileFS::DevFID->new($devid, $fidid);
            my $path = $dfid->get_url;
            $ret->{'devpath_' . $devid} = $path;
        };
    }
    $ret->{devids} = join(',', @devids) if @devids;

    # Always look for a checksum
    my $checksum = Mgd::get_store()->get_checksum($fidid);
    if ($checksum) {
        $checksum = MogileFS::Checksum->new($checksum);
        $ret->{checksum} = $checksum->info;
    } else {
        $ret->{checksum} = 'NONE';
    }

    # Return file row (if found) and all other data.
    my %toret = (fid => $fid, tempfile => $tfile, replqueue => $repl,
        delqueue => $del, rebqueue => $reb, fsckqueue => $fsck);
    while (my ($key, $hash) = each %toret) {
        while (my ($name, $val) = each %$hash) {
            $ret->{$key . '_' . $name} = $val;
        }
    }

    return $self->err_line("unknown_fid") unless keys %$ret;
    return $self->ok_line($ret);
}

sub cmd_file_info {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # validate domain for plugins
    $args->{dmid} = $self->check_domain($args)
        or return $self->err_line('domain_not_found');

    # now invoke the plugin, abort if it tells us to
    my $rv = MogileFS::run_global_hook('cmd_file_info', $args);
    return $self->err_line('plugin_aborted')
        if defined $rv && ! $rv;

    # validate parameters
    my $dmid = $args->{dmid};
    my $key = $args->{key} or return $self->err_line("no_key");

    my $fid;
    Mgd::get_store()->slaves_ok(sub {
        $fid = MogileFS::FID->new_from_dmid_and_key($dmid, $key);
    });
    $fid or return $self->err_line("unknown_key");

    my $ret = {};
    $ret->{fid}      = $fid->id;
    $ret->{domain}   = Mgd::domain_factory()->get_by_id($fid->dmid)->name;
    my $class = Mgd::class_factory()->get_by_id($fid->dmid, $fid->classid);
    $ret->{class}    = $class->name;
    if ($class->{hashtype}) {
        my $checksum = Mgd::get_store()->get_checksum($fid->id);
        if ($checksum) {
            $checksum = MogileFS::Checksum->new($checksum);
            $ret->{checksum} = $checksum->info;
        } else {
            $ret->{checksum} = "MISSING";
        }
    }
    $ret->{key}      = $key;
    $ret->{'length'} = $fid->length;
    $ret->{devcount} = $fid->devcount;
    # Only if requested, also return the raw devids.
    # Caller should use get_paths if they intend to fetch the file.
    if ($args->{devices}) {
        $ret->{devids} = join(',', $fid->devids);
    }

    return $self->ok_line($ret);
}

sub cmd_list_fids {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # validate parameters
    my $fromfid = ($args->{from} || 0)+0;
    my $count = ($args->{to} || 0)+0;
    $count ||= 100;
    $count = 500 if $count > 500 || $count < 0;

    my $rows = Mgd::get_store()->file_row_from_fidid_range($fromfid, $count);
    return $self->err_line('failure') unless $rows;
    return $self->ok_line({ fid_count => 0 }) unless @$rows;

    # setup temporary storage of class/host
    my (%domains, %classes);

    # now iterate over our data rows and construct result
    my $ct = 0;
    my $ret = {};
    foreach my $r (@$rows) {
        $ct++;
        my $fid = $r->{fid};
        $ret->{"fid_${ct}_fid"} = $fid;
        $ret->{"fid_${ct}_domain"} = ($domains{$r->{dmid}} ||=
            Mgd::domain_factory()->get_by_id($r->{dmid})->name);
        $ret->{"fid_${ct}_class"} = ($classes{$r->{dmid}}{$r->{classid}} ||=
            Mgd::class_factory()->get_by_id($r->{dmid}, $r->{classid})->name);
        $ret->{"fid_${ct}_key"} = $r->{dkey};
        $ret->{"fid_${ct}_length"} = $r->{length};
        $ret->{"fid_${ct}_devcount"} = $r->{devcount};
    }
    $ret->{fid_count} = $ct;
    return $self->ok_line($ret);
}

sub cmd_list_keys {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # validate parameters
    my $dmid = $self->check_domain($args)
        or return $self->err_line('domain_not_found');
    my ($prefix, $after, $limit) = ($args->{prefix}, $args->{after}, $args->{limit});

    if (defined $prefix and $prefix ne '') {
        # now validate that after matches prefix
        return $self->err_line('after_mismatch')
            if $after && $after !~ /^$prefix/;

        # verify there are no % or \ characters
        return $self->err_line('invalid_chars')
            if $prefix =~ /[%\\]/;

        # escape underscores
        $prefix =~ s/_/\\_/g;
    }

    $limit ||= 1000;
    $limit += 0;
    $limit = 1000 if $limit > 1000;

    my $keys = Mgd::get_store()->get_keys_like($dmid, $prefix, $after, $limit);

    # if we got nothing, say so
    return $self->err_line('none_match') unless $keys && @$keys;

    # construct the output and send
    my $ret = { key_count => 0, next_after => '' };
    foreach my $key (@$keys) {
        $ret->{key_count}++;
        $ret->{next_after} = $key
            if $key gt $ret->{next_after};
        $ret->{"key_$ret->{key_count}"} = $key;
    }
    return $self->ok_line($ret);
}

sub cmd_rename {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # validate parameters
    my $dmid = $self->check_domain($args)
        or return $self->err_line('domain_not_found');
    my ($fkey, $tkey) = ($args->{from_key}, $args->{to_key});
    return $self->err_line("no_key") unless $fkey && $tkey;

    my $fid = MogileFS::FID->new_from_dmid_and_key($dmid, $fkey)
        or return  $self->err_line("unknown_key");

    $fid->rename($tkey) or
        $self->err_line("key_exists");

    return $self->ok_line;
}

sub cmd_get_hosts {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $ret = { hosts => 0 };
    for my $host (Mgd::host_factory()->get_all) {
        next if defined $args->{hostid} && $host->id != $args->{hostid};
        my $n = ++$ret->{hosts};
        my $fields = $host->fields(qw(hostid status hostname hostip http_port
            http_get_port altip altmask));
        while (my ($key, $val) = each %$fields) {
            # must be regular data so copy it in
            $ret->{"host${n}_$key"} = $val;
        }
    }

    return $self->ok_line($ret);
}

sub cmd_get_devices {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $ret = { devices => 0 };
    for my $dev (Mgd::device_factory()->get_all) {
        next if defined $args->{devid} && $dev->id != $args->{devid};
        my $n = ++$ret->{devices};

        my $sum = $dev->fields;
        while (my ($key, $val) = each %$sum) {
            $ret->{"dev${n}_$key"} = $val;
        }
    }

    return $self->ok_line($ret);
}

sub cmd_create_device {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $status = $args->{state} || "alive";
    return $self->err_line("invalid_state") unless
        device_state($status);

    my $devid = $args->{devid};
    return $self->err_line("invalid_devid") unless $devid && $devid =~ /^\d+$/;

    my $hostid;

    my $sto = Mgd::get_store();
    if ($args->{hostid} && $args->{hostid} =~ /^\d+$/) {
        $hostid = $sto->get_hostid_by_id($args->{hostid});
        return $self->err_line("unknown_hostid") unless $hostid;
    } elsif (my $hname = $args->{hostname}) {
        $hostid = $sto->get_hostid_by_name($hname);
        return $self->err_line("unknown_host") unless $hostid;
    } else {
        return $self->err_line("bad_args", "No hostid/hostname parameter");
    }

    if (eval { $sto->create_device($devid, $hostid, $status) }) {
        return $self->cmd_clear_cache;
    }

    my $errc = error_code($@);
    return $self->err_line("existing_devid") if $errc;
    die $@;  # rethrow;
}

sub cmd_create_domain {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $domain = $args->{domain} or
        return $self->err_line('no_domain');

    my $dom = eval { Mgd::get_store()->create_domain($domain); };
    if ($@) {
        if (error_code($@) eq "dup") {
            return $self->err_line('domain_exists');
        }
        return $self->err_line('failure', "$@");
    }

    return $self->cmd_clear_cache({ domain => $domain });
}

sub cmd_delete_domain {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $domain = $args->{domain} or
        return $self->err_line('no_domain');

    my $sto = Mgd::get_store();
    my $dmid = $sto->get_domainid_by_name($domain) or
        return $self->err_line('domain_not_found');

    if (eval { $sto->delete_domain($dmid) }) {
        return $self->cmd_clear_cache({ domain => $domain });
    }

    my $err = error_code($@);
    return $self->err_line('domain_has_files') if $err eq "has_files";
    return $self->err_line('domain_has_classes') if $err eq "has_classes";
    return $self->err_line("failure");
}

sub cmd_create_class {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $domain = $args->{domain};
    return $self->err_line('no_domain') unless length $domain;

    my $class = $args->{class};
    return $self->err_line('no_class') unless length $class;

    my $mindevcount = $args->{mindevcount}+0;
    return $self->err_line('invalid_mindevcount') unless $mindevcount > 0;

    my $replpolicy = $args->{replpolicy} || '';
    if ($replpolicy) {
        eval {
            MogileFS::ReplicationPolicy->new_from_policy_string($replpolicy);
        };
        return $self->err_line('invalid_replpolicy', $@) if $@;
    }

    my $hashtype = $args->{hashtype};
    if ($hashtype && $hashtype ne 'NONE') {
        my $tmp = $MogileFS::Checksum::NAME2TYPE{$hashtype};
        return $self->err_line('invalid_hashtype') unless $tmp;
        $hashtype = $tmp;
    }

    my $sto = Mgd::get_store();
    my $dmid  = $sto->get_domainid_by_name($domain) or
        return $self->err_line('domain_not_found');

    my $clsid = $sto->get_classid_by_name($dmid, $class);
    if (!defined $clsid && $args->{update} && $class eq 'default') {
        $args->{update} = 0;
    }
    if ($args->{update}) {
        return $self->err_line('class_not_found') if ! defined $clsid;
        $sto->update_class_name(dmid => $dmid, classid => $clsid,
            classname => $class);
    } else {
        $clsid = eval { $sto->create_class($dmid, $class); };
        if ($@) {
            if (error_code($@) eq "dup") {
                return $self->err_line('class_exists');
            }
            return $self->err_line('failure', "$@");
        }
    }
    $sto->update_class_mindevcount(dmid => $dmid, classid => $clsid,
        mindevcount => $mindevcount);
    # don't erase an existing replpolicy if we're not setting a new one.
    $sto->update_class_replpolicy(dmid => $dmid, classid => $clsid,
        replpolicy => $replpolicy) if $replpolicy;
    if ($hashtype) {
        $sto->update_class_hashtype(dmid => $dmid, classid => $clsid,
            hashtype => $hashtype eq 'NONE' ? undef : $hashtype);
    }

    # return success
    return $self->cmd_clear_cache({ class => $class, mindevcount => $mindevcount, domain => $domain });
}

sub cmd_update_class {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # simply passes through to create_class with update set
    $self->cmd_create_class({ %$args, update => 1 });
}

sub cmd_delete_class {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $domain = $args->{domain};
    return $self->err_line('no_domain') unless length $domain;
    my $class = $args->{class};
    return $self->err_line('no_class') unless length $domain;

    return $self->err_line('nodel_default_class') if $class eq 'default';

    my $sto = Mgd::get_store();
    my $dmid  = $sto->get_domainid_by_name($domain) or
        return $self->err_line('domain_not_found');
    my $clsid = $sto->get_classid_by_name($dmid, $class);
    return $self->err_line('class_not_found') unless defined $clsid;

    if (eval { Mgd::get_store()->delete_class($dmid, $clsid) }) {
        return $self->cmd_clear_cache({ domain => $domain, class => $class });
    }

    my $errc = error_code($@);
    return $self->err_line('class_has_files') if $errc eq "has_files";
    return $self->err_line('failure');
}

sub cmd_create_host {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $hostname = $args->{host} or
        return $self->err_line('no_host');

    my $sto = Mgd::get_store();
    my $hostid = $sto->get_hostid_by_name($hostname);

    # if we're creating a new host, require ip/port, and default to
    # host being down if client didn't specify
    if ($args->{update}) {
        return $self->err_line('host_not_found') unless $hostid;
    } else {
        return $self->err_line('host_exists') if $hostid;
        return $self->err_line('no_ip') unless $args->{ip};
        return $self->err_line('no_port') unless $args->{port};
        $args->{status} ||= 'down';
    }

    if ($args->{status}) {
        return $self->err_line('unknown_state')
            unless MogileFS::Host->valid_state($args->{status});
    }

    # arguments all good, let's do it.

    $hostid ||= $sto->create_host($hostname, $args->{ip});

    # Protocol mismatch data fixup.
    $args->{hostip} = delete $args->{ip} if exists $args->{ip};
    $args->{http_port} = delete $args->{port} if exists $args->{port};
    $args->{http_get_port} = delete $args->{getport} if exists $args->{getport};
    my @toupdate = grep { exists $args->{$_} } qw(status hostip http_port
        http_get_port altip altmask);
    $sto->update_host($hostid, { map { $_ => $args->{$_} } @toupdate });

    # return success
    return $self->cmd_clear_cache({ hostid => $hostid, hostname => $hostname });
}

sub cmd_update_host {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # simply passes through to create_host with update set
    $self->cmd_create_host({ %$args, update => 1 });
}

sub cmd_delete_host {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $sto = Mgd::get_store();
    my $hostid = $sto->get_hostid_by_name($args->{host})
        or return $self->err_line('unknown_host');

    # TODO: $sto->delete_host should have a "has_devices" test internally
    for my $dev ($sto->get_all_devices) {
        return $self->err_line('host_not_empty')
            if $dev->{hostid} == $hostid;
    }

    $sto->delete_host($hostid);

    return $self->cmd_clear_cache;
}

sub cmd_get_domains {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $ret = {};
    my $dm_n = 0;
    for my $dom (Mgd::domain_factory()->get_all) {
        $dm_n++;
        $ret->{"domain${dm_n}"} = $dom->name;
        my $cl_n = 0;
        foreach my $cl ($dom->classes) {
            $cl_n++;
            $ret->{"domain${dm_n}class${cl_n}name"}        = $cl->name;
            $ret->{"domain${dm_n}class${cl_n}mindevcount"} = $cl->mindevcount;
            $ret->{"domain${dm_n}class${cl_n}replpolicy"}  =
                $cl->repl_policy_string;
            $ret->{"domain${dm_n}class${cl_n}hashtype"} = $cl->hashtype_string;
        }
        $ret->{"domain${dm_n}classes"} = $cl_n;
    }
    $ret->{"domains"} = $dm_n;

    return $self->ok_line($ret);
}

sub cmd_get_paths {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # memcache mappings are as follows:
    #  mogfid:<dmid>:<dkey> -> fidid
    #  mogdevids:<fidid>    -> \@devids  (and TODO: invalidate when the replication or deletion is run!)

    # if you specify 'noverify', that means a correct answer isn't needed and memcache can
    # be used.
    my $memc          = MogileFS::Config->memcache_client;
    my $get_from_memc = $memc && $args->{noverify};
    my $memcache_ttl  = MogileFS::Config->server_setting_cached("memcache_ttl") || 3600;

    # validate domain for plugins
    $args->{dmid} = $self->check_domain($args)
        or return $self->err_line('domain_not_found');

    # now invoke the plugin, abort if it tells us to
    my $rv = MogileFS::run_global_hook('cmd_get_paths', $args);
    return $self->err_line('plugin_aborted')
        if defined $rv && ! $rv;

    # validate parameters
    my $dmid = $args->{dmid};
    my $key = $args->{key} or return $self->err_line("no_key");

    # We default to returning two possible paths.
    # but the client may ask for more if they want.
    my $pathcount = $args->{pathcount} || 2;
    $pathcount = 2 if $pathcount < 2;

    # get DB handle
    my $fid;
    my $need_fid_in_memcache = 0;
    my $mogfid_memkey = "mogfid:$args->{dmid}:$key";
    if ($get_from_memc) {
        if (my $fidid = $memc->get($mogfid_memkey)) {
            $fid = MogileFS::FID->new($fidid);
        } else {
            $need_fid_in_memcache = 1;
        }
    }
    unless ($fid) {
        Mgd::get_store()->slaves_ok(sub {
            $fid = MogileFS::FID->new_from_dmid_and_key($dmid, $key);
        });
        $fid or return $self->err_line("unknown_key");
    }

    # add to memcache, if needed.  for an hour.
    $memc->set($mogfid_memkey, $fid->id, $memcache_ttl ) if $need_fid_in_memcache || ($memc && !$get_from_memc);

    my $dmap = Mgd::device_factory()->map_by_id;

    my $ret = {
        paths => 0,
    };

    # find devids that FID is on in memcache or db.
    my @fid_devids;
    my $need_devids_in_memcache = 0;
    my $devid_memkey = "mogdevids:" . $fid->id;
    if ($get_from_memc) {
        if (my $list = $memc->get($devid_memkey)) {
            @fid_devids = @$list;
        } else {
            $need_devids_in_memcache = 1;
        }
    }
    unless (@fid_devids) {
        Mgd::get_store()->slaves_ok(sub {
            @fid_devids = $fid->devids;
        });
        $memc->set($devid_memkey, \@fid_devids, $memcache_ttl ) if $need_devids_in_memcache || ($memc && !$get_from_memc);
    }

    my @devices = map { $dmap->{$_} } @fid_devids;

    my @sorted_devs;
    unless (MogileFS::run_global_hook('cmd_get_paths_order_devices', \@devices, \@sorted_devs)) {
        @sorted_devs = sort_devs_by_utilization(@devices);
    }

    # keep one partially-bogus path around just in case we have nothing else to send.
    my $backup_path;

    # construct result paths
    foreach my $dev (@sorted_devs) {
        next unless $dev && ($dev->can_read_from);

        my $host = $dev->host;
        next unless $dev && $host;
        my $dfid = MogileFS::DevFID->new($dev, $fid);
        my $path = $dfid->get_url;
        my $currently_down =
            $host->observed_unreachable || $dev->observed_unreachable;

        if ($currently_down) {
            $backup_path = $path;
            next;
        }

        # only verify size one first one, and never verify if they've asked not to
        next unless
            $ret->{paths}        ||
            $args->{noverify}    ||
            $dfid->size_matches;

        my $n = ++$ret->{paths};
        $ret->{"path$n"} = $path;
        last if $n == $pathcount;   # one verified, one likely seems enough for now.  time will tell.
    }

    # use our backup path if all else fails
    if ($backup_path && ! $ret->{paths}) {
        $ret->{paths} = 1;
        $ret->{path1} = $backup_path;
    }

    return $self->ok_line($ret);
}

sub sort_devs_by_utilization {
    my @devices_with_weights;

    # is this fid still owned by this key?
    foreach my $dev (@_) {
        my $weight;
        my $util = $dev->observed_utilization;

        if (defined($util) and $util =~ /\A\d+\Z/) {
            $weight = 102 - $util;
            $weight ||= 100;
        } else {
            $weight = $dev->weight;
            $weight ||= 100;
        }
        push @devices_with_weights, [$dev, $weight];
    }

    # randomly weight the devices
    my @list = MogileFS::Util::weighted_list(@devices_with_weights);

    return @list;
}

# ------------------------------------------------------------
#
# NOTE: cmd_edit_file is EXPERIMENTAL. Please see the documentation
# for edit_file in L<MogileFS::Client>.
# It is not recommended to use cmd_edit_file on production systems.
#
# cmd_edit_file is similar to cmd_get_paths, except we:
# - take the device of the first path we would have returned
# - get a tempfile with a new fid (pointing to nothing) on the same device
#   the tempfile has the same key, so will replace the old contents on
#   create_close
# - detach the old fid from that device (leaving the file in place)
# - attach the new fid to that device
# - returns only the first path to the old fid and a path to new fid
# (the client then DAV-renames the old path to the new path)
#
# TODO - what to do about situations where we would be reducing the
# replica count to zero?
# TODO - what to do about pending replications where we remove the source?
# TODO - the current implementation of cmd_edit_file is based on a copy
#   of cmd_get_paths. Once proven mature, consider factoring out common
#   code from the two functions.
# ------------------------------------------------------------
sub cmd_edit_file {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $memc = MogileFS::Config->memcache_client;

    # validate domain for plugins
    $args->{dmid} = $self->check_domain($args)
        or return $self->err_line('domain_not_found');

    # now invoke the plugin, abort if it tells us to
    my $rv = MogileFS::run_global_hook('cmd_get_paths', $args);
    return $self->err_line('plugin_aborted')
        if defined $rv && ! $rv;

    # validate parameters
    my $dmid = $args->{dmid};
    my $key = $args->{key} or return $self->err_line("no_key");

    # get DB handle
    my $fid;
    my $need_fid_in_memcache = 0;
    my $mogfid_memkey = "mogfid:$args->{dmid}:$key";
    if (my $fidid = $memc->get($mogfid_memkey)) {
        $fid = MogileFS::FID->new($fidid);
    } else {
        $need_fid_in_memcache = 1;
    }
    unless ($fid) {
        Mgd::get_store()->slaves_ok(sub {
            $fid = MogileFS::FID->new_from_dmid_and_key($dmid, $key);
        });
        $fid or return $self->err_line("unknown_key");
    }

    # add to memcache, if needed.  for an hour.
    $memc->add($mogfid_memkey, $fid->id, 3600) if $need_fid_in_memcache;

    my $dmap = Mgd::device_factory()->map_by_id;

    my @devices_with_weights;

    # find devids that FID is on in memcache or db.
    my @fid_devids;
    my $need_devids_in_memcache = 0;
    my $devid_memkey = "mogdevids:" . $fid->id;
    if (my $list = $memc->get($devid_memkey)) {
        @fid_devids = @$list;
    } else {
        $need_devids_in_memcache = 1;
    }
    unless (@fid_devids) {
        Mgd::get_store()->slaves_ok(sub {
            @fid_devids = $fid->devids;
        });
        $memc->add($devid_memkey, \@fid_devids, 3600) if $need_devids_in_memcache;
    }

    # is this fid still owned by this key?
    foreach my $devid (@fid_devids) {
        my $weight;
        my $dev = $dmap->{$devid};
        my $util = $dev->observed_utilization;

        if (defined($util) and $util =~ /\A\d+\Z/) {
            $weight = 102 - $util;
            $weight ||= 100;
        } else {
            $weight = $dev->weight;
            $weight ||= 100;
        }
        push @devices_with_weights, [$devid, $weight];
    }

    # randomly weight the devices
    # TODO - should we reverse the order, to leave the best
    # one there for get_paths?
    my @list = MogileFS::Util::weighted_list(@devices_with_weights);

    # Filter out bad devs
    @list = grep {
        my $devid = $_;
        my $dev = $dmap->{$devid};
        my $host = $dev ? $dev->host : undef;

        $dev
        && $host
        && $dev->can_read_from
        && !($host->observed_unreachable || $dev->observed_unreachable);
    } @list;

    # Take first remaining device from list
    my $devid = $list[0];

    my $classid = $fid->classid;
    my $newfid = eval {
        Mgd::get_store()->register_tempfile(
            fid     => undef,   # undef => let the store pick a fid
            dmid    => $dmid,
            key     => $key,    # This tempfile will ultimately become this key
            classid => $classid,
            devids  => $devid,
        );
    };
    unless ($newfid) {
        my $errc = error_code($@);
        return $self->err_line("fid_in_use") if $errc eq "dup";
        warn "Error registering tempfile: $@\n";
        return $self->err_line("db");
    }
    unless (Mgd::get_store()->remove_fidid_from_devid($fid->id, $devid)) {
        warn "Error removing fidid from devid";
        return $self->err_line("db");
    }
    unless (Mgd::get_store()->add_fidid_to_devid($newfid, $devid)) {
        warn "Error removing fidid from devid";
        return $self->err_line("db");
    }

    my @paths = map {
        my $dfid = MogileFS::DevFID->new($devid, $_);
        my $path = $dfid->get_url;
    } ($fid, $newfid);
    my $ret;
    $ret->{oldpath} = $paths[0];
    $ret->{newpath} = $paths[1];
    $ret->{fid} = $newfid;
    $ret->{devid} = $devid;
    $ret->{class} = $classid;
    return $self->ok_line($ret);
}

sub cmd_set_weight {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # figure out what they want to do
    my ($hostname, $devid, $weight) = ($args->{host}, $args->{device}+0, $args->{weight}+0);
    return $self->err_line('bad_params')
        unless $hostname && $devid && $weight >= 0;

    my $dev = Mgd::device_factory()->get_by_id($devid);
    return $self->err_line('no_device') unless $dev;
    return $self->err_line('host_mismatch')
        unless $dev->host->hostname eq $hostname;

    Mgd::get_store()->set_device_weight($dev->id, $weight);

    return $self->cmd_clear_cache;
}

sub cmd_set_state {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    # figure out what they want to do
    my ($hostname, $devid, $state) = ($args->{host}, $args->{device}+0, $args->{state});

    my $dstate = device_state($state);
    return $self->err_line('bad_params')
        unless $hostname && $devid && $dstate;

    my $dev = Mgd::device_factory()->get_by_id($devid);
    return $self->err_line('no_device') unless $dev;
    return $self->err_line('host_mismatch')
        unless $dev->host->hostname eq $hostname;

    # make sure the destination state isn't too high
    return $self->err_line('state_too_high')
        unless $dev->can_change_to_state($state);

    Mgd::get_store()->set_device_state($dev->id, $state);
    return $self->cmd_clear_cache;
}

sub cmd_noop {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;
    return $self->ok_line;
}

sub cmd_replicate_now {
    my MogileFS::Worker::Query $self = shift;

    my $rv = Mgd::get_store()->replicate_now;
    return $self->ok_line({ count => int($rv) });
}

sub cmd_set_server_setting {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;
    my $key = $args->{key} or
        return $self->err_line("bad_params");
    my $val = $args->{value};

    my $chk  = MogileFS::Config->server_setting_is_writable($key) or
        return $self->err_line("not_writable");

    my $cleanval = eval { $chk->($val); };
    return $self->err_line("invalid_format", $@) if $@;

    MogileFS::Config->set_server_setting($key, $cleanval);

    # GROSS HACK: slave settings are managed directly by MogileFS::Client, but
    # I need to add a version key, so we check and inject that code here.
    # FIXME: Move this when slave keys are managed by query worker commands!
    if ($key =~ /^slave_/) {
        Mgd::get_store()->incr_server_setting('slave_version', 1);
    }

    return $self->ok_line;
}

sub cmd_server_setting {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;
    my $key = $args->{key};
    return $self->err_line("bad_params") unless $key;
    my $value = MogileFS::Config->server_setting($key);
    return $self->ok_line({key => $key, value => $value});
}

sub cmd_server_settings {
    my MogileFS::Worker::Query $self = shift;
    my $ss = Mgd::get_store()->server_settings;
    my $ret = {};
    my $n = 0;
    while (my ($k, $v) = each %$ss) {
        next unless MogileFS::Config->server_setting_is_readable($k);
        $ret->{"key_count"} = ++$n;
        $ret->{"key_$n"}    = $k;
        $ret->{"value_$n"}  = $v;
    }
    return $self->ok_line($ret);
}

sub cmd_do_monitor_round {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;
    $self->forget_that_monitor_has_run;
    $self->wait_for_monitor;
    return $self->ok_line;
}

sub cmd_fsck_start {
    my MogileFS::Worker::Query $self = shift;
    my $sto = Mgd::get_store();

    my $fsck_host  = MogileFS::Config->server_setting("fsck_host");
    my $rebal_host = MogileFS::Config->server_setting("rebal_host");

    return $self->err_line("fsck_running", "fsck is already running") if $fsck_host;
    return $self->err_line("rebal_running", "rebalance running; cannot run fsck at same time") if $rebal_host;

    # reset position, if a previous fsck was already completed.
    my $intss       = sub { MogileFS::Config->server_setting($_[0]) || 0 };
    my $checked_fid = $intss->("fsck_highest_fid_checked");
    my $final_fid   = $intss->("fsck_fid_at_end");
    if (($checked_fid && $final_fid && $checked_fid >= $final_fid) ||
        (!$final_fid && !$checked_fid)) {
        $self->_do_fsck_reset or return $self->err_line;
    }

    # set params for stats:
    $sto->set_server_setting("fsck_start_time", $sto->get_db_unixtime);
    $sto->set_server_setting("fsck_stop_time", undef);
    $sto->set_server_setting("fsck_fids_checked", 0);
    my $start_fid =
        MogileFS::Config->server_setting('fsck_highest_fid_checked') || 0;
    $sto->set_server_setting("fsck_start_fid", $start_fid);

    # and start it:
    $sto->set_server_setting("fsck_host", MogileFS::Config->hostname);
    MogileFS::ProcManager->wake_a("fsck");

    return $self->ok_line;
}

sub cmd_fsck_stop {
    my MogileFS::Worker::Query $self = shift;
    my $sto = Mgd::get_store();
    $sto->set_server_setting("fsck_host", undef);
    $sto->set_server_setting("fsck_stop_time", $sto->get_db_unixtime);
    return $self->ok_line;
}

sub cmd_fsck_reset {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $sto = Mgd::get_store();
    $sto->set_server_setting("fsck_opt_policy_only",
        ($args->{policy_only} ? "1" : undef));
    $sto->set_server_setting("fsck_highest_fid_checked", 
        ($args->{startpos} ? $args->{startpos} : "0"));

    $self->_do_fsck_reset or return $self->err_line;
    return $self->ok_line;
}

sub _do_fsck_reset {
    my MogileFS::Worker::Query $self = shift;
    my $sto = Mgd::get_store();
    $sto->set_server_setting("fsck_start_time",       undef);
    $sto->set_server_setting("fsck_stop_time",        undef);
    $sto->set_server_setting("fsck_fids_checked",     0);
    $sto->set_server_setting("fsck_fid_at_end",       $sto->max_fidid);

    # clear existing event counts summaries.
    my $ss = $sto->server_settings;
    foreach my $k (keys %$ss) {
        next unless $k =~ /^fsck_sum_evcount_/;
        $sto->set_server_setting($k, undef);
    }
    my $logid = $sto->max_fsck_logid;
    $sto->set_server_setting("fsck_start_maxlogid", $logid);
    $sto->set_server_setting("fsck_logid_processed", $logid);
}

sub cmd_fsck_clearlog {
    my MogileFS::Worker::Query $self = shift;
    my $sto = Mgd::get_store();
    $sto->clear_fsck_log;
    return $self->ok_line;
}

sub cmd_fsck_getlog {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $sto = Mgd::get_store();
    my @rows = $sto->fsck_log_rows($args->{after_logid}, 100);
    my $ret;
    my $n = 0;
    foreach my $row (@rows) {
        $n++;
        foreach my $k (keys %$row) {
            $ret->{"row_${n}_$k"} = $row->{$k} if defined $row->{$k};
        }
    }
    $ret->{row_count} = $n;
    return $self->ok_line($ret);
}

sub cmd_fsck_status {
    my MogileFS::Worker::Query $self = shift;

    my $sto        = Mgd::get_store();
    # Kick up the summary before we read the values
    $sto->fsck_log_summarize;
    my $fsck_host  = MogileFS::Config->server_setting('fsck_host');
    my $intss      = sub { MogileFS::Config->server_setting($_[0]) || 0 };
    my $ret = {
        running         => ($fsck_host ? 1 : 0),
        host            => $fsck_host,
        max_fid_checked => $intss->('fsck_highest_fid_checked'),
        policy_only     => $intss->('fsck_opt_policy_only'),
        end_fid         => $intss->('fsck_fid_at_end'),
        start_time      => $intss->('fsck_start_time'),
        stop_time       => $intss->('fsck_stop_time'),
        current_time    => $sto->get_db_unixtime,
        max_logid       => $sto->max_fsck_logid,
    };

    # throw some stats in.
    my $ss = $sto->server_settings;
    foreach my $k (keys %$ss) {
        next unless $k =~ /^fsck_sum_evcount_(.+)/;
        $ret->{"num_$1"} += $ss->{$k};
    }

    return $self->ok_line($ret);
}

sub cmd_rebalance_status {
    my MogileFS::Worker::Query $self = shift;

    my $sto = Mgd::get_store();

    my $rebal_state = MogileFS::Config->server_setting('rebal_state');
    return $self->err_line('no_rebal_state') unless $rebal_state;
    return $self->ok_line({ state => $rebal_state });
}

sub cmd_rebalance_start {
    my MogileFS::Worker::Query $self = shift;

    my $rebal_host = MogileFS::Config->server_setting("rebal_host");
    my $fsck_host  = MogileFS::Config->server_setting("fsck_host");

    return $self->err_line("rebal_running", "rebalance is already running") if $rebal_host;
    return $self->err_line("fsck_running", "fsck running; cannot run rebalance at same time") if $fsck_host;

    my $rebal_state = MogileFS::Config->server_setting('rebal_state');
    unless ($rebal_state) {
        my $rebal_pol = MogileFS::Config->server_setting('rebal_policy');
        return $self->err_line('no_rebal_policy') unless $rebal_pol;

        my $rebal = MogileFS::Rebalance->new;
        $rebal->policy($rebal_pol);
        my @devs  = Mgd::device_factory()->get_all;
        $rebal->init(\@devs);
        my $sdevs = $rebal->source_devices;

        $rebal_state = $rebal->save_state;
        MogileFS::Config->set_server_setting('rebal_state', $rebal_state);
    }
    # TODO: register start time somewhere.
    MogileFS::Config->set_server_setting('rebal_host', MogileFS::Config->hostname);
    return $self->ok_line({ state => $rebal_state });
}

sub cmd_rebalance_test {
    my MogileFS::Worker::Query $self = shift;
    my $rebal_pol   = MogileFS::Config->server_setting('rebal_policy');
    my $rebal_state = MogileFS::Config->server_setting('rebal_state');
    return $self->err_line('no_rebal_policy') unless $rebal_pol;

    my $rebal = MogileFS::Rebalance->new;
    my @devs  = Mgd::device_factory()->get_all;
    $rebal->policy($rebal_pol);
    $rebal->init(\@devs);

    # client should display list of source, destination devices.
    # FIXME: can probably avoid calling this twice by pulling state?
    # *or* not running init.
    my $sdevs = $rebal->filter_source_devices(\@devs);
    my $ddevs = $rebal->filter_dest_devices(\@devs);
    my $ret   = {};
    $ret->{sdevs} = join(',', @$sdevs);
    $ret->{ddevs} = join(',', @$ddevs);

    return $self->ok_line($ret);
}

sub cmd_rebalance_reset {
    my MogileFS::Worker::Query $self = shift;
    my $host = MogileFS::Config->server_setting('rebal_host');
    if ($host) {
        return $self->err_line("rebal_running", "rebalance is running") if $host;
    }
    MogileFS::Config->set_server_setting('rebal_state', undef);
    return $self->ok_line;
}

sub cmd_rebalance_stop {
    my MogileFS::Worker::Query $self = shift;
    my $host = MogileFS::Config->server_setting('rebal_host');
    unless ($host) {
        return $self->err_line('rebal_not_started');
    }
    MogileFS::Config->set_server_setting('rebal_signal', 'stop');
    return $self->ok_line;
}

sub cmd_rebalance_set_policy {
    my MogileFS::Worker::Query $self = shift;
    my $args = shift;

    my $rebal_host = MogileFS::Config->server_setting("rebal_host");
    return $self->err_line("no_set_rebal", "cannot change rebalance policy while rebalance is running") if $rebal_host;

    # load policy object, test policy, set policy.
    my $rebal = MogileFS::Rebalance->new;
    eval {
        $rebal->policy($args->{policy});
    };
    if ($@) {
        return $self->err_line("bad_rebal_pol", $@);
    }

    MogileFS::Config->set_server_setting('rebal_policy', $args->{policy});
    MogileFS::Config->set_server_setting('rebal_state', undef);
    return $self->ok_line;
}

sub ok_line {
    my MogileFS::Worker::Query $self = shift;

    my $delay = '';
    if ($self->{querystarttime}) {
        $delay = sprintf("%.4f ", Time::HiRes::tv_interval( $self->{querystarttime} ));
        $self->{querystarttime} = undef;
    }

    my $id = defined $self->{reqid} ? "$self->{reqid} " : '';

    my $args = shift || {};
    $args->{callid} = $self->{callid} if defined $self->{callid};
    my $argline = join('&', map { eurl($_) . "=" . eurl($args->{$_}) } keys %$args);
    $self->send_to_parent("${id}${delay}OK $argline");
    return 1;
}

# first argument: error code.
# second argument: optional error text.  text will be taken from code if no text provided.
sub err_line {
    my MogileFS::Worker::Query $self = shift;

    my $err_code = shift;
    my $err_text = shift || {
        'dup' => "Duplicate name/number used.",
        'after_mismatch' => "Pattern does not match the after-value?",
        'bad_params' => "Invalid parameters to command; please see documentation",
        'class_exists' => "That class already exists in that domain",
        'class_has_files' => "Class still has files, unable to delete",
        'class_not_found' => "Class not found",
        'db' => "Database error",
        'domain_has_files' => "Domain still has files, unable to delete",
        'domain_exists' => "That domain already exists",
        'domain_not_empty' => "Domain still has classes, unable to delete",
        'domain_not_found' => "Domain not found",
        'failure' => "Operation failed",
        'host_exists' => "That host already exists",
        'host_mismatch' => "The device specified doesn't belong to the host specified",
        'host_not_empty' => "Unable to delete host; it contains devices still",
        'host_not_found' => "Host not found",
        'invalid_chars' => "Patterns must not contain backslashes (\\) or percent signs (%).",
        'invalid_checker_level' => "Checker level invalid.  Please see documentation on this command.",
        'invalid_mindevcount' => "The mindevcount must be at least 1",
        'key_exists' => "Target key name already exists; can't overwrite.",
        'no_class' => "No class provided",
        'no_devices' => "No devices found to store file",
        'no_device' => "Device not found",
        'no_domain' => "No domain provided",
        'no_host' => "No host provided",
        'no_ip' => "IP required to create host",
        'no_port' => "Port required to create host",
        'no_temp_file' => "No tempfile or file already closed",
        'none_match' => "No keys match that pattern and after-value (if any).",
        'plugin_aborted' => "Action aborted by plugin",
        'state_too_high' => "Status cannot go from dead to alive; must use down",
        'unknown_command' => "Unknown server command",
        'unknown_host' => "Host not found",
        'unknown_state' => "Invalid/unknown state",
        'unreg_domain' => "Domain name invalid/not found",
        'rebal_not_started' => "Rebalance not running",
        'no_rebal_state' => "No available rebalance status",
        'no_rebal_policy' => "No rebalance policy available",
        'nodel_default_class' => "Cannot delete the default class",
    }->{$err_code} || $err_code;

    my $delay = '';
    if ($self->{querystarttime}) {
        $delay = sprintf("%.4f ", Time::HiRes::tv_interval($self->{querystarttime}));
        $self->{querystarttime} = undef;
    }

    my $id = defined $self->{reqid} ? "$self->{reqid} " : '';
    my $callid = defined $self->{callid} ? ' ' . eurl($self->{callid}) : '';

    $self->send_to_parent("${id}${delay}ERR $err_code " . eurl($err_text) . $callid);
    return 0;
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:

__END__

=head1 NAME

MogileFS::Worker::Query -- implements the MogileFS client protocol

=head1 SEE ALSO

L<MogileFS::Worker>



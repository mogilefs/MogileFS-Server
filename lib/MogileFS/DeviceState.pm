package MogileFS::DeviceState;
use strict;

# properties are:
#    read:  can it serve traffic?
#    drain: should its file_on be drained?
#    new_files: does it get new files
#    write:  is it writable?  (for instance, for deletes)
#    dead:  permanently dead, files lost, not coming back to service
my $singleton = {
    'alive' => bless({
        read => 1,
        write => 1,
        monitor => 1,
        new_files => 1,
    }),
    'dead' => bless({
        # Note that 'dead' doesn't include 'drain', since that's
        # handled (specially) by the reap job.
        dead => 1,
    }),
    'down' => bless({
    }),
    'readonly' => bless({
        read => 1,
        monitor => 1,
    }),
    'replicateonly' => bless({
        replicateonly => 1,
        write => 1,
        monitor => 1,
        new_files => 1,
    }),
    'drain' => bless({
        read => 1,
        write => 1,
        drain => 1,
        monitor => 1,
    }),
};

# returns undef if unknown state
sub of_string {
    my ($class, $state) = @_;
    return $state ? $singleton->{$state} : undef;
}

sub should_drain      { $_[0]->{drain}     }
sub can_delete_from   { $_[0]->{write}     }
sub can_read_from     { $_[0]->{read}      }
sub is_replicateonly  { $_[0]->{replicateonly} }
sub should_get_new_files { $_[0]->{new_files} }
sub should_get_repl_files { $_[0]->{new_files} }
sub should_have_files { ! $_[0]->{dead} }
sub should_monitor    { $_[0]->{monitor}   }

# named inconveniently so it's not taken to mean equalling string
# "dead"
sub is_perm_dead      { $_[0]->{dead}   }
sub should_wake_reaper { $_[0]->{dead}   }

sub should_fsck_search_on {
    my $ds = shift;
    return $ds->can_read_from || $ds->should_have_files;
}

1;


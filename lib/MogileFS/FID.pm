package MogileFS::FID;
use strict;
use warnings;
use Carp qw(croak);
use MogileFS::ReplicationRequest qw(rr_upgrade);
use MogileFS::Server;
use overload '""' => \&as_string;

sub new {
    my ($class, $fidid) = @_;
    croak("Invalid fidid") unless $fidid;
    return bless {
        fidid    => $fidid,
        dmid     => undef,
        dkey     => undef,
        length   => undef,
        classid  => undef,
        devcount => undef,
        _loaded  => 0,
        _devids  => undef,   # undef, or pre-loaded arrayref devid list
    }, $class;
}

sub as_string {
    my $self = shift;
    "FID[f=$self->{fidid}]";
}

# mutates/blesses given row.
sub new_from_db_row {
    my ($class, $row) = @_;
    # TODO: sanity check provided row more?
    $row->{fidid}   = delete $row->{fid} or die "Missing 'fid' column";
    $row->{_loaded} = 1;
    return bless $row, $class;
}

# quick port of old API.  perhaps not ideal.
sub new_from_dmid_and_key {
    my ($class, $dmid, $key) = @_;
    my $row = Mgd::get_store()->read_store->file_row_from_dmid_key($dmid, $key)
        or return undef;
    return $class->new_from_db_row($row);
}

# given a bunch of ::FID objects, populates their devids en-masse
# (for the fsck worker, which doesn't want to do many database
# round-trips)
sub mass_load_devids {
    my ($class, @fids) = @_;
    my $sto = Mgd::get_store();
    my $locs = $sto->fid_devids_multiple(map { $_->id } @fids);
    my @ret;
    foreach my $fid (@fids) {
        $fid->{_devids} = $locs->{$fid->id} || [];
    }
}
# --------------------------------------------------------------------------

sub exists {
    my $self = shift;
    $self->_tryload;
    return $self->{_loaded};
}

sub classid {
    my $self = shift;
    $self->_load;
    return $self->{classid};
}

sub dmid {
    my $self = shift;
    $self->_load;
    return $self->{dmid};
}

sub length {
    my $self = shift;
    $self->_load;
    return $self->{length};
}

sub devcount {
    my $self = shift;
    $self->_load;
    return $self->{devcount};
}

sub id { $_[0]{fidid} }

# force loading, or die.
sub _load {
    return 1 if $_[0]{_loaded};
    my $self = shift;
    croak("FID\#$self->fidid} doesn't exist") unless $self->_tryload;
}

# return 1 if loaded, or 0 if not exist
sub _tryload {
    return 1 if $_[0]{_loaded};
    my $self = shift;
    my $row = Mgd::get_store()->file_row_from_fidid($self->{fidid})
        or return 0;
    $self->{$_} = $row->{$_} foreach qw(dmid dkey length classid devcount);
    $self->{_loaded} = 1;
    return 1;
}

sub update_devcount {
    my ($self, %opts) = @_;

    my $no_lock = delete $opts{no_lock};
    croak "Bogus options" if %opts;

    my $fidid = $self->{fidid};

    my $sto = Mgd::get_store();
    if ($no_lock) {
        return $sto->update_devcount($fidid);
    } else {
        return $sto->update_devcount_atomic($fidid);
    }
}

sub update_class {
    my ($self, %opts) = @_;

    my $classid = delete $opts{classid};
    croak "Bogus options" if %opts;

    my $sto = Mgd::get_store();
    return $sto->update_classid($self->{fidid}, $classid);
}

sub enqueue_for_replication {
    my ($self, %opts) = @_;
    my $in       = delete $opts{in};
    my $from_dev = delete $opts{from_device};  # devid or Device object
    croak("Unknown options to enqueue_for_replication") if %opts;
    my $from_devid = (ref $from_dev ? $from_dev->id : $from_dev) || undef;
    Mgd::get_store()->enqueue_for_replication($self->id, $from_devid, $in);
}

sub mark_unreachable {
    my $self = shift;
    # update database table
    Mgd::get_store()->mark_fidid_unreachable($self->id);
}

sub delete {
    my $fid = shift;
    my $sto = Mgd::get_store();
    $sto->delete_fidid($fid->id);
}

# returns 1 on success, 0 on duplicate key error, dies on exception
sub rename {
    my ($fid, $to_key) = @_;
    my $sto = Mgd::get_store();
    return $sto->rename_file($fid->id, $to_key);
}

# returns array of devids that this fid is on
# NOTE: TODO: by default, this doesn't cache.  callers might be surprised from
#   having an old version later on.  before caching is added, auditing needs
#   to be done.
sub devids {
    my $self = shift;

    # if it was mass-loaded and stored in _devids arrayref, use
    # that instead of going to db...
    return @{$self->{_devids}} if $self->{_devids};

    # else get it from the database
    return Mgd::get_store()->read_store->fid_devids($self->id);
}

sub devs {
    my $self = shift;
    return map { Mgd::device_factory()->get_by_id($_) } $self->devids;
}

sub devfids {
    my $self = shift;
    return map { MogileFS::DevFID->new($_, $self) } $self->devids;
}


# return FID's class
sub class {
    my $self = shift;
    return Mgd::class_factory()->get_by_id($self->dmid, $self->classid);
}

# Get reloaded the next time we're bothered.
sub want_reload {
    my $self = shift;
    $self->{_loaded} = 0;
}

# returns bool: if fid's presumed-to-be-on devids meet the file class'
# replication policy rules.  dies on failure to load class, world
# info, etc.
sub devids_meet_policy {
    my $self = shift;
    my $cls  = $self->class;

    my $polobj = $cls->repl_policy_obj;

    my $alldev = Mgd::device_factory()->map_by_id
        or die "No global device map";

    my @devs = $self->devs;
    # This is a little heavy handed just to fix the 'devcount' cache, but
    # doing it here ensures we get the error logged.
    if (@devs != $self->devcount) {
        return 0;
    }

    my %rep_args = (
                    fid       => $self->id,
                    on_devs   => [@devs],
                    all_devs  => $alldev,
                    failed    => {},
                    min       => $cls->mindevcount,
                    );
    my $rr = rr_upgrade($polobj->replicate_to(%rep_args));
    return $rr->is_happy && ! $rr->too_happy;
}

sub fsck_log {
    my ($self, $code, $dev) = @_;
    Mgd::get_store()->fsck_log(
                               code  => $code,
                               fid   => $self->id,
                               devid => ($dev ? $dev->id : undef),
                               );

}

sub forget_cached_devids {
    my $self = shift;
    $self->{_devids} = undef;
}

# returns MogileFS::DevFID object, after noting in the db that this fid is on this DB.
# it trusts you that it is, and that you've verified it.
sub note_on_device {
    my ($fid, $dev) = @_;
    my $dfid = MogileFS::DevFID->new($dev, $fid);
    $dfid->add_to_db;
    $fid->forget_cached_devids;
    return $dfid;
}

sub forget_about_device {
    my ($fid, $dev) = @_;
    $dev->forget_about($fid);
    $fid->forget_cached_devids;
    return 1;
}

1;

__END__

=head1 NAME

MogileFS::FID - represents a unique, immutable version of a file

=head1 ABOUT

This class represents a "fid", or "file id", which is a unique
revision of a file.  If you upload a file with the same key
("filename") a dozen times, each one has a unique "fid".  Fids are
immutable, and are what are replicated around the MogileFS farm.

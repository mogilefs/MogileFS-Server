package MogileFS::DevFID;
use strict;
use warnings;
use MogileFS::Server;
use overload '""' => \&as_string;
use Carp qw(croak);

sub new {
    my ($class, $devarg, $fidarg) = @_;
    return bless {
        devid => ref $devarg ? $devarg->id : $devarg,
        dev   => ref $devarg ? $devarg     : undef,
        fidid => ref $fidarg ? $fidarg->id : $fidarg,
        fid   => ref $fidarg ? $fidarg     : undef,
    }, $class;
}

# --------------------------------------------------------------------------

sub devid { $_[0]{devid} }
sub fidid { $_[0]{fidid} }

sub as_string {
    "DevFID[d=" . $_[0]{devid} . ";f=" . $_[0]{fidid} . "]";
}

sub device {
    my $self = shift;
    return $self->{dev} ||= Mgd::device_factory()->get_by_id($self->{devid});
}

sub fid {
    my $self = shift;
    return $self->{fid} ||= MogileFS::FID->new($self->{fidid});
}

# returns true if DevFID actually exists in database
sub exists {
    my $self = shift;
    my $fid  = $self->fid;
    return (grep { $_ == $self->{devid} } $fid->devids) ? 1 : 0;
}

sub url {
    my $self = shift;
    return $self->_make_full_url(0);
}

sub get_url {
    my $self = shift;
    return $self->_make_full_url(1);
}

sub vivify_directories {
    my $self = shift;
    my $url = $self->url;
    $self->device()->vivify_directories($url);
}

# returns 0 on missing,
# undef on connectivity error,
# else size of file on disk (after HTTP HEAD or mogstored stat)
sub size_on_disk {
    my $self = shift;
    my $url = $self->get_url;

    # check that it has size (>0) and is reachable (not undef)
    return MogileFS::HTTPFile->at($url)->size;
}

# returns true if size seen matches fid's length
sub size_matches {
    my $self = shift;
    my $fid = $self->fid;
    my $disk_size = $self->size_on_disk;

    # Temporary connectivity error with that disk/machine..
    return 0 unless defined $disk_size;
    return 0 if $disk_size == MogileFS::HTTPFile::FILE_MISSING;

    return $disk_size == $fid->length;
}

# returns just the URI path component without scheme/host
sub uri_path {
    my $self = shift;
    my $devid = $self->{devid};
    my $fidid = $self->{fidid};

    my $nfid;
    my $len = length $fidid;
    if ($len < 10) {
        $nfid = '0' x (10 - $len) . $fidid;
    } else {
        $nfid = $fidid;
    }
    my ( $b, $mmm, $ttt, $hto ) = ( $nfid =~ m{(\d)(\d{3})(\d{3})(\d{3})} );

    return "/dev$devid/$b/$mmm/$ttt/$nfid.fid";
}

sub _make_full_url {
    # set use_get_port to be true to specify to use the get port
    my ($self, $use_get_port) = @_;

    # get some information we'll need
    my $dev  = $self->device   or return undef;
    my $host = $dev->host      or return undef;

    my $path   = $self->uri_path;
    my $hostip = $host->ip;
    my $port   = $use_get_port ? $host->http_get_port : $host->http_port;

    return "http://$hostip:$port$path";
}

sub add_to_db {
    my ($self, $no_lock) = @_;
    croak("fidid not non-zero") unless $self->{fidid};
    croak("devid not non-zero") unless $self->{devid};

    my $sto = Mgd::get_store();
    if ($sto->add_fidid_to_devid($self->{fidid}, $self->{devid})) {
        return $self->fid->update_devcount(no_lock => $no_lock);
    } else {
        # was already on that device
        return 1;
    }
}

# Destroy a particular replica of a file via HTTP, remove it
# from the tracker, and update the replication counts to be
# accurate again.
sub destroy {
    my $self = shift;
    my %opts = @_;

    my $httpfile = MogileFS::HTTPFile->at($self->url)
        or die "Creation of HTTPFile object failed.";

    my %delete_opts;

    $delete_opts{ignore_missing} = 1
        if $opts{ignore_missing};

    $httpfile->delete(%delete_opts)
        or die "Deletion of file via HTTP failed.";

    my $sto = Mgd::get_store();
    $sto->remove_fidid_from_devid($self->fidid, $self->devid);
    $sto->update_devcount($self->fidid);
}

1;

__END__

=head1 NAME

MogileFS::DevFID - represents a FID on a device

=head1 ABOUT

This class represents the (devid, fidid) tuple.  That is, a specific
version on a file on a specific device.  See L<MogileFS::Device> and
L<MogileFS::FID>.

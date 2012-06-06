package MogileFS::Device;
use strict;
use warnings;
use Carp qw/croak/;
use MogileFS::Server;
use MogileFS::Util qw(throw);
use MogileFS::Util qw(okay_args device_state error);

=head1

MogileFS::Device - device class

=cut

BEGIN {
    my $testing = $ENV{TESTING} ? 1 : 0;
    eval "sub TESTING () { $testing }";
}

my @observed_fields = qw/observed_state utilization reject_bad_md5 await svctm/;
my @fields = (qw/hostid status weight mb_total mb_used mb_asof devid/,
    @observed_fields);

sub new_from_args {
    my ($class, $args, $host_factory) = @_;
    my $self = bless {
        host_factory => $host_factory,
        %{$args},
    }, $class;

    # FIXME: No guarantee (as of now?) that hosts get loaded before devs.
    #$self->host || die "No host for $self->{devid} (host $self->{hostid})";

    croak "invalid device observed state '$self->{observed_state}', valid: writeable, readable, unreachable"
        if $self->{observed_state} && $self->{observed_state} !~ /^(?:writeable|readable|unreachable)$/;

    return $self;
}

# Instance methods

sub id     { return $_[0]{devid} }
sub devid  { return $_[0]{devid} }
sub name   { return $_[0]{devid} }
sub status { return $_[0]{status} }
sub weight { return $_[0]{weight} }
sub hostid { return $_[0]{hostid} }

sub host {
    my $self = shift;
    return $self->{host_factory}->get_by_id($self->{hostid});
}

# returns 0 if not known, else [0,1]
sub percent_free {
    my $self = shift;
    return 0 unless $self->{mb_total} && defined $self->{mb_used};
    return 1 - ($self->{mb_used} / $self->{mb_total});
}

# returns undef if not known, else [0,1]
sub percent_full {
    my $self = shift;
    return undef unless $self->{mb_total} && defined $self->{mb_used};
    return $self->{mb_used} / $self->{mb_total};
}

# FIXME: $self->mb_free?
sub fields {
    my $self = shift;
    my @tofetch = @_ ? @_ : @fields;
    my $ret = { (map { $_ => $self->{$_} } @tofetch),
        'mb_free' => $self->mb_free };
    return $ret;
}

sub observed_fields {
    return $_[0]->fields(@observed_fields);
}

sub observed_utilization {
    my $self = shift;

    if (TESTING) {
        my $weight_varname = 'T_FAKE_IO_DEV' . $self->id;
        return $ENV{$weight_varname} if defined $ENV{$weight_varname};
    }

    return $self->{utilization};
}

sub observed_await {
    my $self = shift;

    if (TESTING) {
        my $weight_varname = 'T_FAKE_IO_DEV' . $self->id;
        return $ENV{$weight_varname} if defined $ENV{$weight_varname};
    }

    return $self->{await};
}

sub observed_svctm {
    my $self = shift;

    if (TESTING) {
        my $weight_varname = 'T_FAKE_IO_DEV' . $self->id;
        return $ENV{$weight_varname} if defined $ENV{$weight_varname};
    }

    return $self->{svctm};
}

sub observed_writeable {
    my $self = shift;
    return 0 unless $self->{observed_state} && $self->{observed_state} eq 'writeable';
    my $host = $self->host or return 0;
    return 0 unless $host->observed_reachable;
    return 1;
}

sub observed_readable {
    my $self = shift;
    return $self->{observed_state} && $self->{observed_state} eq 'readable';
}

sub observed_unreachable {
    my $self = shift;
    return $self->{observed_state} && $self->{observed_state} eq 'unreachable';
}

# FIXME: This pattern is weird. Store the object on new?
sub dstate {
    my $ds = device_state($_[0]->status);
    return $ds if $ds;
    error("dev$_[0]->{devid} has bogus status '$_[0]->{status}', pretending 'down'");
    return device_state("down");
}

sub can_delete_from {
    return $_[0]->dstate->can_delete_from;
}

sub can_read_from {
    return $_[0]->dstate->can_read_from;
}

# FIXME: Is there a (unrelated to this code) bug where new files aren't tested
# against the free space limit before being stored or replicated somewhere?
sub should_get_new_files {
    my $self   = shift;
    my $dstate = $self->dstate;

    return 0 unless $dstate->should_get_new_files;
    return 0 unless $self->observed_writeable;
    return 0 unless $self->host->should_get_new_files;
    # have enough disk space? (default: 100MB)
    my $min_free = MogileFS->config("min_free_space");
    return 0 if $self->{mb_total} &&
        $self->mb_free < $min_free;

    return 1;
}

sub mb_free {
    my $self = shift;
    return $self->{mb_total} - $self->{mb_used}
        if $self->{mb_total} && defined $self->{mb_used};
}

sub mb_used {
    return $_[0]->{mb_used};
}

# currently the same policy, but leaving it open for differences later.
sub should_get_replicated_files {
    return $_[0]->should_get_new_files;
}

sub not_on_hosts {
    my ($self, @hosts) = @_;
    my @hostids   = map { ref($_) ? $_->id : $_ } @hosts;
    my $my_hostid = $self->id;
    return (grep { $my_hostid == $_ } @hostids) ? 0 : 1;
}

# "cached" by nature of the monitor worker testing this.
sub doesnt_know_mkcol {
    return $_[0]->{no_mkcol};
}

# Gross class-based singleton cache.
my %dir_made;  # /dev<n>/path -> $time
my $dir_made_lastclean = 0;
# returns 1 on success, 0 on failure
sub create_directory {
    my ($self, $uri) = @_;
    return 1 if $self->doesnt_know_mkcol || MogileFS::Config->server_setting_cached('skip_mkcol');

    # rfc2518 says we "should" use a trailing slash. Some servers
    # (nginx) appears to require it.
    $uri .= '/' unless $uri =~ m/\/$/;

    return 1 if $dir_made{$uri};

    my $hostid = $self->hostid;
    my $host   = $self->host;
    my $hostip = $host->ip        or return 0;
    my $port   = $host->http_port or return 0;
    my $peer = "$hostip:$port";

    my $sock = IO::Socket::INET->new(PeerAddr => $peer, Timeout => 1)
        or return 0;

    print $sock "MKCOL $uri HTTP/1.0\r\n".
        "Content-Length: 0\r\n\r\n";

    my $ans = <$sock>;

    # if they don't support this method, remember that
    if ($ans && $ans =~ m!HTTP/1\.[01] (400|501)!) {
        $self->{no_mkcol} = 1;
        # TODO: move this into method in *monitor* worker
        return 1;
    }

    return 0 unless $ans && $ans =~ m!^HTTP/1.[01] 2\d\d!;

    my $now = time();
    $dir_made{$uri} = $now;

    # cleanup %dir_made occasionally.
    my $clean_interval = 300;  # every 5 minutes.
    if ($dir_made_lastclean < $now - $clean_interval) {
        $dir_made_lastclean = $now;
        foreach my $k (keys %dir_made) {
            delete $dir_made{$k} if $dir_made{$k} < $now - 3600;
        }
    }
    return 1;
}

sub fid_list {
    my ($self, %opts) = @_;
    my $limit = delete $opts{limit};
    croak("No limit specified") unless $limit && $limit =~ /^\d+$/;
    croak("Unknown options to fid_list") if %opts;

    my $sto = Mgd::get_store();
    my $fidids = $sto->get_fidids_by_device($self->devid, $limit);
    return map {
        MogileFS::FID->new($_)
    } @{$fidids || []};
}

sub fid_chunks {
    my ($self, %opts) = @_;

    my $sto = Mgd::get_store();
    # storage function does validation.
    my $fidids = $sto->get_fidid_chunks_by_device(devid => $self->devid, %opts);
    return map {
        MogileFS::FID->new($_)
    } @{$fidids || []};
}

sub forget_about {
    my ($self, $fid) = @_;
    Mgd::get_store()->remove_fidid_from_devid($fid->id, $self->id);
    return 1;
}

sub usage_url {
    my $self = shift;
    my $host     = $self->host;
    my $get_port = $host->http_get_port;
    my $hostip   = $host->ip;
    return "http://$hostip:$get_port/dev$self->{devid}/usage";
}

sub can_change_to_state {
    my ($self, $newstate) = @_;
    # don't allow dead -> alive transitions.  (yes, still possible
    # to go dead -> readonly -> alive to bypass this, but this is
    # all more of a user-education thing than an absolute policy)
    return 0 if $self->dstate->is_perm_dead && $newstate eq 'alive';
    return 1;
}

sub vivify_directories {
    my ($self, $path) = @_;

    # $path is something like:
    #    http://10.0.0.26:7500/dev2/0/000/148/0000148056.fid

    # three directories we'll want to make:
    #    http://10.0.0.26:7500/dev2/0
    #    http://10.0.0.26:7500/dev2/0/000
    #    http://10.0.0.26:7500/dev2/0/000/148

    croak "non-HTTP mode no longer supported" unless $path =~ /^http/;
    return 0 unless $path =~ m!/dev(\d+)/(\d+)/(\d\d\d)/(\d\d\d)/\d+\.fid$!;
    my ($devid, $p1, $p2, $p3) = ($1, $2, $3, $4);

    die "devid mismatch" unless $self->id == $devid;

    $self->create_directory("/dev$devid/$p1");
    $self->create_directory("/dev$devid/$p1/$p2");
    $self->create_directory("/dev$devid/$p1/$p2/$p3");
}

# FIXME: Remove this once vestigial code is removed.
sub set_observed_utilization {
    return 1;
}

# Compatibility interface since this old routine is unfortunately called
# internally within plugins. This data should be passed into any hooks which
# may need it?
# Currently an issue with MogileFS::Network + ZoneLocal
# Remove this in 2012.
sub devices {
    return Mgd::device_factory()->get_all;
}

sub reject_bad_md5 {
    return $_[0]->{reject_bad_md5};
}

1;

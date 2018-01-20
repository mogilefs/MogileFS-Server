package MogileFS::HTTPFile;
use strict;
use warnings;
use Carp qw(croak);
use Digest;
use MogileFS::Server;
use MogileFS::Util qw(error undeferr wait_for_readability wait_for_writeability);

my %sidechannel_nexterr;    # host => next error log time

# create a new MogileFS::HTTPFile instance from a URL.  not called
# "new" because I don't want to imply that it's creating anything.
sub at {
    my ($class, $url) = @_;
    my $self = bless {}, $class;

    unless ($url =~ m!^http://([^:/]+)(?::(\d+))?(/.+)$!) {
        croak "Bogus URL.\n";
    }

    $self->{url}  = $url;
    $self->{host} = $1;
    $self->{port} = $2;
    $self->{uri}  = $3;
    return $self;
}

sub device_id {
    my $self = shift;
    return $self->{devid} if $self->{devid};
    $self->{url} =~ /\bdev(\d+)\b/
        or die "Can't find device from URL: $self->{url}\n";
    return $self->{devid} = $1;
}

sub host_id {
    my $self = shift;
    return $self->device->hostid;
}

# return MogileFS::Device object
sub device {
    my $self = shift;
    return Mgd::device_factory()->get_by_id($self->device_id);
}

# return MogileFS::Host object
sub host {
    my $self = shift;
    return $self->device->host;
}

# returns true on success, dies on failure
sub delete {
    my $self = shift;
    my %opts = @_;
    my ($host, $port) = ($self->{host}, $self->{port});
    my %http_opts = ( port => $port );
    my $res;

    $self->host->http("DELETE", $self->{uri}, \%http_opts, sub { ($res) = @_ });

    Danga::Socket->SetPostLoopCallback(sub { !defined $res });
    Danga::Socket->EventLoop;

    if ($res->code == 204 || ($res->code == 404 && $opts{ignore_missing})) {
        return 1;
    }
    my $line = $res->status_line;
    die "Bad response on DELETE $self->{url}: [$line]";
}

# returns size of file, (doing a HEAD request and looking at content-length)
# returns -1 on file missing (404),
# returns undef on connectivity error
#
# If an optional callback is supplied, the return value is given to the
# callback.
#
# workers running Danga::Socket->EventLoop must supply a callback
# workers NOT running Danga::Socket->EventLoop msut not supply a callback
use constant FILE_MISSING => -1;
sub size {
    my ($self, $cb) = @_;
    my %opts = ( port => $self->{port} );

    if ($cb) { # run asynchronously
        if (defined $self->{_size}) {
            Danga::Socket->AddTimer(0, sub { $cb->($self->{_size}) });
        } else {
            $self->host->http("HEAD", $self->{uri}, \%opts, sub {
                $cb->($self->on_size_response(@_));
            });
        }
        return undef;
    } else { # run synchronously
        return $self->{_size} if defined $self->{_size};

        my $res;
        $self->host->http("HEAD", $self->{uri}, \%opts, sub { ($res) = @_ });

        Danga::Socket->SetPostLoopCallback(sub { !defined $res });
        Danga::Socket->EventLoop;

        return $self->on_size_response($res);
    }
}

sub on_size_response {
    my ($self, $res) = @_;

    if ($res->is_success) {
        my $size = $res->header('content-length');
        if (! defined $size &&
            $res->header('server') =~ m/^lighttpd|^Apache/) {
            # lighttpd 1.4.x (main release) and apache 2.x does not return content-length for
            # 0 byte files.
            $self->{_size} = 0;
            return 0;
        }
        $self->{_size} = $size;
        return $size;
    } else {
        if ($res->code == 404) {
            return FILE_MISSING;
        }
        return undeferr("Failed HEAD check for $self->{url} (" . $res->code . "): "
            . $res->message); 
    }
}

sub digest_mgmt {
    my ($self, $alg, $ping_cb, $reason) = @_;
    my $mogconn = $self->host->mogstored_conn;
    my $node_timeout = MogileFS->config("node_timeout");
    my $sock;
    my $rv;
    my $expiry;

    # assuming the storage node can checksum at >=2MB/s, low expectations here
    my $response_timeout = $self->size / (2 * 1024 * 1024);
    if ($reason && $reason eq "fsck") {
        # fsck has low priority in mogstored and is concurrency-limited,
        # so this may be queued indefinitely behind digest requests for
        # large files
        $response_timeout += 3600;
    } else {
        # account for disk/network latency:
        $response_timeout += $node_timeout;
    }

    $reason = defined($reason) ? " $reason" : "";
    my $uri = $self->{uri};
    my $req = "$alg $uri$reason\r\n";
    my $reqlen = length $req;

    # a dead/stale socket may not be detected until we try to recv on it
    # after sending a request
    my $retries = 2;

    my $host = $self->{host};

retry:
    $sock = eval { $mogconn->sock($node_timeout) };
    if (defined $sock) {
        delete $sidechannel_nexterr{$host};
    } else {
        # avoid flooding logs with identical messages
        my $err = $@;
        my $next = $sidechannel_nexterr{$host} || 0;
        my $now = time();
        return if $now < $next;
        $sidechannel_nexterr{$host} = $now + 300;
        return undeferr("sidechannel failure on $alg $uri: $err");
    }

    $rv = send($sock, $req, 0);
    if ($! || $rv != $reqlen) {
        my $err = $!;
        $mogconn->mark_dead;
        if ($retries-- <= 0) {
            $req =~ tr/\r\n//d;
            $err = $err ? "send() error ($req): $err" :
                          "short send() ($req): $rv != $reqlen";
            $err = $mogconn->{ip} . ":" . $mogconn->{port} . " $err";
            return undeferr($err);
        }
        goto retry;
    }

    $expiry = Time::HiRes::time() + $response_timeout;
    while (!wait_for_readability(fileno($sock), 1.0) &&
           (Time::HiRes::time() < $expiry)) {
        $ping_cb->();
    }

    $rv = <$sock>;
    if (! $rv) {
        $mogconn->mark_dead;
        return undeferr("EOF from mogstored") if ($retries-- <= 0);
        goto retry;
    } elsif ($rv =~ /^\Q$uri\E \Q$alg\E=([a-f0-9]{32,128})\r\n/) {
        my $hexdigest = $1;

        my $checksum = eval {
            MogileFS::Checksum->from_string(0, "$alg:$hexdigest")
        };
        return undeferr("$alg failed for $uri: $@") if $@;
        return $checksum->{checksum};
    } elsif ($rv =~ /^\Q$uri\E \Q$alg\E=-1\r\n/) {
        # FIXME, this could be another error like EMFILE/ENFILE
        return FILE_MISSING;
    } elsif ($rv =~ /^ERROR /) {
        return; # old server, fallback to HTTP
    }

    chomp($rv);
    return undeferr("mogstored failed to handle ($alg $uri): $rv");
}

sub digest_http {
    my ($self, $alg, $ping_cb) = @_;

    my $digest = Digest->new($alg);
    my %opts = (
        port => $self->{port},
        # default (4K) is tiny, use 1M like replicate
        read_size_hint => 0x100000,
        content_cb => sub {
            $digest->add($_[0]);
            $ping_cb->();
        },
    );

    my $res;
    $self->host->http("GET", $self->{uri}, \%opts, sub { ($res) = @_ });

    # TODO: async interface for workers already running Danga::Socket->EventLoop
    Danga::Socket->SetPostLoopCallback(sub { !defined $res });
    Danga::Socket->EventLoop;

    return $digest->digest if $res->is_success;
    return FILE_MISSING if $res->code == 404;
    return undeferr("Failed $alg (GET) check for $self->{url} (" . $res->code . "): "
                    . $res->message);
}

sub digest {
    my ($self, $alg, $ping_cb, $reason) = @_;
    my $digest = $self->digest_mgmt($alg, $ping_cb, $reason);

    return $digest if ($digest && $digest ne FILE_MISSING);

    $self->digest_http($alg, $ping_cb);
}

1;

package MogileFS::HTTPFile;
use strict;
use warnings;
use Carp qw(croak);
use Socket qw(PF_INET IPPROTO_TCP SOCK_STREAM);
use MogileFS::Util qw(error undeferr wait_for_readability wait_for_writeability);

# (caching the connection used for HEAD requests)
my %http_socket;                # host:port => [$pid, $time, $socket]

# get size of file, return 0 on error.
# tries to finish in 2.5 seconds, under the client's default 3 second timeout.  (configurable)
my %last_stream_connect_error;  # host => $hirestime.

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
    return MogileFS::Device->of_devid($self->device_id);
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

    my $httpsock = IO::Socket::INET->new(PeerAddr => $host, PeerPort => $port, Timeout => 2)
        or die "can't connect to $host:$port in 2 seconds";

    $httpsock->write("DELETE $self->{uri} HTTP/1.0\r\nConnection: keep-alive\r\n\r\n");

    my $keep_alive = 0;
    my $did_del    = 0;

    while (defined (my $line = <$httpsock>)) {
        $line =~ s/[\s\r\n]+$//;
        last unless length $line;
        if ($line =~ m!^HTTP/\d+\.\d+\s+(\d+)!) {
            my $rescode = $1;
            # make sure we get a good response
            if ($rescode == 404 && $opts{ignore_missing}) {
                $did_del = 1;
                next;
            }
            unless ($rescode == 204) {
                delete $http_socket{"$host:$port"};
                die "Bad response from $host:$port: [$line]";
            }
            $did_del = 1;
            next;
        }
        die "Unexpected HTTP response line during DELETE from $host:$port: [$line]" unless $did_del;
    }
    die "Didn't get valid HTTP response during DELETE from $host:port" unless $did_del;

    return 1;
}

# returns size of file, (doing a HEAD request and looking at content-length, or side-channel to mogstored)
# returns -1 on file missing (404 or -1 from sidechannel),
# returns undef on connectivity error
use constant FILE_MISSING => -1;
sub size {
    my $self = shift;
    my ($host, $port, $uri, $path) = map { $self->{$_} } qw(host port uri url);

    # don't SIGPIPE us
    my $flag_nosignal = MogileFS::Sys->flag_nosignal;
    local $SIG{'PIPE'} = "IGNORE" unless $flag_nosignal;

    # setup for sending size request to cached host
    my $req = "size $uri\r\n";
    my $reqlen = length $req;
    my $rv = 0;

    my $mogconn = $self->host->mogstored_conn;
    my $sock    = $mogconn->sock_if_connected;

    my $start_time = Time::HiRes::time();

    my $httpsock;
    my $start_connecting_to_http = sub {
        return if $httpsock;  # don't allow starting connecting twice

        # try to reuse cached socket
        if (my $cached = $http_socket{"$host:$port"}) {
            my ($pid, $conntime, $cachesock) = @{ $cached };
            # see if it's still connected
            if ($pid == $$ && getpeername($cachesock) &&
                $conntime > $start_time - 15 &&
                # readability would indicated conn closed, or garbage:
                ! wait_for_readability(fileno($cachesock), 0.00))
            {
                $httpsock = $cachesock;
                return;
            }
        }

        socket $httpsock, PF_INET, SOCK_STREAM, IPPROTO_TCP;
        IO::Handle::blocking($httpsock, 0);
        connect $httpsock, Socket::sockaddr_in($port, Socket::inet_aton($host));
    };

    # sub to parse the response from $sock.  returns undef on error,
    # or otherwise the size of the $path in bytes.
    my $node_timeout = MogileFS->config("node_timeout");
    my $stream_response_timeout = 1.0;
    my $read_timed_out = 0;

    # returns defined on a real answer (-1 = file missing, >=0 = file length),
    # returns undef on connectivity problems.
    my $parse_response = sub {
        # give the socket 1 second to become readable until we get
        # scared of no reply and start connecting to HTTP to do a HEAD
        # request.  if both timeout, we know the machine is gone, but
        # we don't want to wait 2 seconds + 2 seconds... prefer to do
        # connects in parallel to reduce overall latency.
        unless (wait_for_readability(fileno($sock), $stream_response_timeout)) {
            $start_connecting_to_http->();
            # give the socket its final time to get to 2 seconds
            # before we really give up on it
            unless (wait_for_readability(fileno($sock), $node_timeout - $stream_response_timeout)) {
                $read_timed_out = 1;
                close($sock);
                return undef;
            }
        }

        # now we know there's readable data (pseudo-gross: we assume
        # if we were readable, the whole line is ready.  this is a
        # poor mix of low-level IO and buffered, blocking stdio but in
        # practice it works...)
        my $line = <$sock>;
        return undef unless defined $line;
        return undef unless $line =~ /^(\S+)\s+(-?\d+)/; # expected format: "uri size"
        return undeferr("get_file_size() requested size of $path, got back size of $1 ($2 bytes)")
            if $1 ne $uri;
        # backchannel sends back -1 on non-existent file, which we map to the defined value '-1'
        return FILE_MISSING if $2 < 0;
        # otherwise, return byte size of file
        return $2+0;
    };

    my $conn_timeout = MogileFS->config("conn_timeout") || 2;

    # try using the cached socket
    if ($sock) {
        $rv = send($sock, $req, $flag_nosignal);
        if ($!) {
            $mogconn->mark_dead;
        } elsif ($rv != $reqlen) {
            # FIXME: perhaps we shouldn't error here, but instead
            # treat the cached socket as bogus and reconnect?  never
            # seen that happen, though.
            return undeferr("send() didn't return expected length ($rv, not $reqlen) for $path");
        } else {
            # success
            my $size = $parse_response->();
            return $size if defined $size;
            $mogconn->mark_dead;
        }
    }
    # try creating a connection to the stream
    elsif (($last_stream_connect_error{$host} ||= 0) < $start_time - 15.0)
    {
        $sock = $mogconn->sock($conn_timeout);

        if ($sock) {
            $rv = send($sock, $req, $flag_nosignal);
            if ($!) {
                return undeferr("error talking to mogstored stream ($path): $!");
            } elsif ($rv != $reqlen) {
                return undeferr("send() didn't return expected length ($rv, not $reqlen) for $path");
            } else {
                # success
                my $size = $parse_response->();
                return $size if defined $size;
                $mogconn->mark_dead;
            }
        } else {
            # see if we timed out connecting.
            my $elapsed = Time::HiRes::time() - $start_time;
            if ($elapsed > $conn_timeout - 0.2) {
                return undeferr("node $host seems to be down in get_file_size");
            } else {
                # cache that we can't connect to the mogstored stream
                # port for people using only apache/lighttpd (dav) on
                # the storage nodes
                $last_stream_connect_error{$host} = Time::HiRes::time();
            }

        }
    }

    # failure case: use a HEAD request to get the size of the file:
    # give them 2 seconds to connect to server, unless we'd already timed out earlier
    my $time_remain = 2.5 - (Time::HiRes::time() - $start_time);
    return undeferr("timed out on stream size check of $path, not doing HEAD")
        if $time_remain <= 0;

    # try HTTP (this will only work once anyway, if we already started above)
    $start_connecting_to_http->();

    # did we timeout?
    unless (wait_for_writeability(fileno($httpsock), $time_remain)) {
        if (my $worker = MogileFS::ProcManager->is_child) {
            $worker->broadcast_host_unreachable($self->host_id);
        }
        return undeferr("get_file_size() connect timeout for HTTP HEAD for size of $path");
    }

    # did we fail to connect?  (got a RST, etc)
    unless (getpeername($httpsock)) {
        if (my $worker = MogileFS::ProcManager->is_child) {
            $worker->broadcast_device_unreachable($self->device_id);
        }
        return undeferr("get_file_size() connect failure for HTTP HEAD for size of $path");
    }

    $time_remain = 2.5 - (Time::HiRes::time() - $start_time);
    return undeferr("no time remaining to write HEAD request to $path") if $time_remain <= 0;

    $rv = syswrite($httpsock, "HEAD $uri HTTP/1.0\r\nConnection: keep-alive\r\n\r\n");
    # FIXME: we don't even look at $rv ?
    return undeferr("get_file_size() read timeout ($time_remain) for HTTP HEAD for size of $path")
        unless wait_for_readability(fileno($httpsock), $time_remain);

    my $first = <$httpsock>;
    return undeferr("get_file_size()'s HEAD request hung up on us")
        unless $first;
    my ($code) = $first =~ m!^HTTP/1\.\d (\d\d\d)! or
        return undeferr("HEAD response to get_file_size looks bogus");
    return FILE_MISSING if $code == 404;
    return undeferr("get_file_size()'s HEAD request wasn't a 200 OK, got: $code")
        unless $code == 200;

    # FIXME: this could block too probably, if we don't get a whole
    # line.  in practice, all headers will come at once, though in same packet/read.
    my $cl = undef;
    my $keep_alive = 0;
    while (defined (my $line = <$httpsock>)) {
        if ($line eq "\r\n") {
            if ($keep_alive) {
                $http_socket{"$host:$port"} = [ $$, Time::HiRes::time(), $httpsock ];
            } else {
                delete $http_socket{"$host:$port"};
            }
            return $cl;
        }
        $cl = $1        if $line =~ /^Content-length: (\d+)/i;
        $keep_alive = 1 if $line =~ /^Connection:.+\bkeep-alive\b/i;
    }
    delete $http_socket{"$host:$port"};

    # no content length found?
    return undeferr("get_file_size() found no content-length header in response for $path");
}


1;

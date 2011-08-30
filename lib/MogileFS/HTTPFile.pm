package MogileFS::HTTPFile;
use strict;
use warnings;
use Carp qw(croak);
use Socket qw(PF_INET IPPROTO_TCP SOCK_STREAM);
use MogileFS::Server;
use MogileFS::Util qw(error undeferr wait_for_readability wait_for_writeability);

# (caching the connection used for HEAD requests)
my $user_agent;

my %size_check_retry_after; # host => $hirestime.
my %size_check_failcount;   # host => $count.

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

# returns size of file, (doing a HEAD request and looking at content-length)
# returns -1 on file missing (404),
# returns undef on connectivity error
use constant FILE_MISSING => -1;
sub size {
    my $self = shift;
    my ($host, $port, $uri, $path) = map { $self->{$_} } qw(host port uri url);

    return undef if (exists $size_check_retry_after{$host}
        && $size_check_retry_after{$host} > Time::HiRes::time());

    # don't SIGPIPE us
    my $flag_nosignal = MogileFS::Sys->flag_nosignal;
    local $SIG{'PIPE'} = "IGNORE" unless $flag_nosignal;

    my $node_timeout = MogileFS->config("node_timeout");
    # Hardcoded connection cache size of 20 :(
    $user_agent ||= LWP::UserAgent->new(timeout => $node_timeout, keep_alive => 20);
    my $res = $user_agent->head($path);
    if ($res->is_success) {
        delete $size_check_failcount{$host} if exists $size_check_failcount{$host};
        return $res->header('content-length');
    } else {
        if ($res->code == 404) {
            delete $size_check_failcount{$host} if exists $size_check_failcount{$host};
            return FILE_MISSING;
        }
        if ($res->message =~ m/connect:/) {
            my $count = $size_check_failcount{$host};
            $count ||= 1;
            $count *= 2 unless $count > 360;
            $size_check_retry_after{$host} = Time::HiRes::time() + $count;
            $size_check_failcount{$host}   = $count;
        }
        return undeferr("Failed HEAD check for $path (" . $res->code . "): "
            . $res->message); 
    }
}

1;

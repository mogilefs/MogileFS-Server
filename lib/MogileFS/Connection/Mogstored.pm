package MogileFS::Connection::Mogstored;
use strict;
use IO::Socket::INET;
use Socket qw(SO_KEEPALIVE);

sub new {
    my ($class, $ip, $port) = @_;
    return bless {
        sock => undef,  # undef if not yet connected, else socket to host
        ip   => $ip,
        port => $port,
    }, $class;
}

# returns (or connects to & returns) raw socket to mogstored.
sub sock {
    my ($self, $timeout) = @_;
    return $self->{sock} if $self->{sock};
    $self->{sock} = IO::Socket::INET->new(PeerAddr => $self->{ip},
                                          PeerPort => $self->{port},
                                          Timeout  => $timeout) or die "Could not connect to mogstored on ".$self->{ip}.":".$self->{port};
    $self->{sock}->sockopt(SO_KEEPALIVE, 1);
    return $self->{sock};
}

sub mark_dead {
    my $self = shift;
    $self->{sock} = undef;
}

1;

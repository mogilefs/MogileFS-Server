package MogileFS::Cache::Redis;
use strict;
use base 'MogileFS::Cache';
use Redis;

# --------------------------------------------------------------------------
# Redis mappings:
#   mogf:<dmid>:<dkey> -> fidid
#   mogd:<fidid> -> \@devids (Redis set)
# --------------------------------------------------------------------------

my $cache;

sub init {
    my $self = shift;
    $self->SUPER::init;

    my $server = $self->{servers};
    $server =~ s/^\s+//;
    $server =~ s/\s+$//;
    $server ||= '127.0.0.1:6379';

    if ($server =~ m!^/!) {
        $cache = Redis->new(sock => $server, encoding => undef, reconnect => 60);
    } else {
        $cache = Redis->new(server => $server, encoding => undef, reconnect => 60);
    }
    return $self;
}

sub refresh {
    my $self = shift;
    return $self;
}

sub set {
    # We use simple keys and sets since Redis only supports
    # expiry based on key rather than individual elements of
    # an advanced data structure like hashes.
    my ($self, $key, $value) = @_;
    my $hash = $self->hash($key);
    my $response;
    if ($key->{type} eq 'devid') {
        # requires Redis >= 2.4
        $response = $cache->sadd($hash, @$value);
    } else {
        $response = $cache->set($hash => $value);
    }
    # Unlike memcache, setting ttl to 0 will clear the key
    if ($self->{ttl}) {
        $cache->expire($hash, $self->{ttl});
    }
    return $response;
}

sub get {
    my ($self, $key) = @_;
    my $hash = $self->hash($key);
    if ($key->{type} eq 'devid') {
        my $members = $cache->smembers($hash);
        return @$members ? $members : undef;
    }
    return $cache->get($hash);
}

sub delete {
    my ($self, $key) = @_;
    return $cache->del($self->hash($key));
}

1;

__END__

=head1 NAME

MogileFS::Cache::Redis - Redis path cache for MogileFS

=head1 SEE ALSO

L<MogileFS::Cache>



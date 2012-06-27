package MogileFS::Cache::Redis;
use strict;
use base 'MogileFS::Cache';
use Redis;

# --------------------------------------------------------------------------
# Cache-related things we override
# --------------------------------------------------------------------------

my $cache;

sub init {
    my $self = shift;
    $self->SUPER::init;

    my $server = $self->{servers} || '127.0.0.1:6379';

    if ($server =~ m!^/!) {
        $cache = Redis->new(sock => $server, encoding => undef, reconnect => 60);
    } else {
        $cache = Redis->new(server => $server, encoding => undef, reconnect => 60);
    }
    return $self;
}

sub set {
    my ($self, $key, $value) = @_;
    my $hash = $self->hash($key);
    if ($key->{type} eq 'devid') {
        foreach my $devid (@{$value}) {
            $cache->sadd($hash, $devid);
        }
    } else {
        $cache->set($hash => $value);
    }
    return $cache->expire($hash, $self->{ttl});
}

sub get {
    my ($self, $key) = @_;
    my $hash = $self->hash($key);
    if ($key->{type} eq 'devid') {
        my $members = $cache->smembers($hash);
        return undef unless @$members;
        return $members;
    }
    return $cache->get($hash);
}

sub delete {
    my ($self, $key) = @_;
    return $cache->del($self->hash($key));
}

sub hash {
    my ($self, $key) = @_;
    if ($key->{type} eq 'fid') {
        return "f:$key->{domain}:$key->{key}";
    } elsif ($key->{type} eq 'devid') {
        return "d:$key->{fid}";
    }
    return $key;
}

1;

__END__

=head1 NAME

MogileFS::Cache::Redis - Redis path cache for MogileFS

=head1 SEE ALSO

L<MogileFS::Cache>



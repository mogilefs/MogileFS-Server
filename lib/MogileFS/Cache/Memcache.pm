package MogileFS::Cache::Memcache;
use strict;
use base 'MogileFS::Cache';
use Cache::Memcached;

# memcache mappings are as follows:
#   mogfid:<dmid>:<dkey> -> fidid
#   mogdevids:<fidid>    -> \@devids  (and TODO: invalidate when deletion is run!)

my $cache;

sub init {
    my $self = shift;
    $self->SUPER::init;

    my @servers = split(/\s*,\s*/, $self->{servers} || '127.0.0.1:11211');

    $cache = Cache::Memcached->new;
    $cache->set_servers(\@servers);
    return $self;
}

sub set {
    my ($self, $key, $value) = @_;
    return $cache->set($self->hash($key), $value, $self->{ttl});
}

sub get {
    my ($self, $key) = @_;
    return $cache->get($self->hash($key));
}

sub delete {
    my ($self, $key) = @_;
    return $cache->delete($self->hash($key));
}

sub hash {
    my ($self, $key) = @_;
    if ($key->{type} eq 'fid') {
        return "mogfid:$key->{domain}:$key->{key}";
    } elsif ($key->{type} eq 'devid') {
        return "mogdevids:$key->{fid}";
    }
    return $key;
}

1;

__END__

=head1 NAME

MogileFS::Cache::Memcache - Memcache path cache for MogileFS

=head1 SEE ALSO

L<MogileFS::Cache>



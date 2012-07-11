package MogileFS::Cache::Memcache;
use strict;
use base 'MogileFS::Cache';
use Cache::Memcached;

# --------------------------------------------------------------------------
# Memcache mappings are as follows:
#   mogf:<dmid>:<dkey> -> fidid
#   mogd:<fidid> -> \@devids (and TODO: invalidate when deletion is run!)
# --------------------------------------------------------------------------

my $cache;

sub init {
    my $self = shift;
    $self->SUPER::init;

    my @servers = grep(!/^$/, grep(s/^\s*|\s*$//g, split(',', $self->{servers})));
    @servers = ('127.0.0.1:11211') unless @servers;

    $cache = Cache::Memcached->new;
    $cache->set_servers(\@servers);
    return $self;
}

sub refresh {
    my $self = shift;

    # backwards compatibility with previous cache implementation
    my @servers = grep(!/^$/, grep(s/^\s*|\s*$//g, split(',', MogileFS::Config->server_setting_cached("memcache_servers"))));
    return undef unless @servers;

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

1;

__END__

=head1 NAME

MogileFS::Cache::Memcache - Memcache path cache for MogileFS

=head1 SEE ALSO

L<MogileFS::Cache>



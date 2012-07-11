package MogileFS::Cache;
use strict;
use MogileFS::Util qw(error);

my $have_memc_module = eval "use Cache::Memcached; 1;";
my $have_redis_module = eval "use Redis; 1;";

sub new {
    my ($class) = @_;
    return $class->new_from_config;
}

sub new_from_config {
    my ($class) = @_;
    return undef unless ($have_memc_module || $have_redis_module);

    my ($type, $servers, $cache_ttl);

    if ($servers = MogileFS::Config->server_setting_cached('memcache_servers')) {
        $type = 'memcache';
        $cache_ttl = MogileFS::Config->server_setting_cached('memcache_ttl') || 3600;
    } else {
        $servers = MogileFS->config('cache_servers');
        $type = MogileFS->config('cache_type');
        $cache_ttl = MogileFS->config('cache_ttl') || 3600;
    }

    my $subclass;
    if ($type eq 'none' || $type eq '') {
        return undef;
    } elsif ($type eq 'memcache' && $have_memc_module) {
        $subclass = 'MogileFS::Cache::Memcache';
    } elsif ($type eq 'redis' && $have_redis_module) {
        $subclass = 'MogileFS::Cache::Redis';
    } else {
        error("Cache type not supported: $type");
        return undef;
    }
    unless (eval "use $subclass; 1") {
        error("Error loading $subclass: $@");
        return undef;
    }

    my $self = bless {
        servers => $servers,
        ttl     => $cache_ttl,
    }, $subclass;
    $self->init;
    return $self;
}

sub init { 1 }

sub refresh {
    my $self = shift;
    return $self;
}

sub set {
    my ($self, $key, $value) = @_;
    die "set not implemented for $self";
}

sub get {
    my ($self, $key) = @_;
    die "get not implemented for $self";
}

sub delete {
    my ($self, $key) = @_;
    die "delete not implemented for $self";
}

sub hash {
    my ($self, $key) = @_;
    if ($key->{type} eq 'fid') {
        return 'mogf:' . $key->{domain} . ':' . $key->{key};
    } elsif ($key->{type} eq 'devid') {
        return 'mogd:' . $key->{fid};
    }
    return $key;
}

1;

__END__

=head1 NAME

MogileFS::Cache - path cache provider.  base class.

=head1 ABOUT

Caches key-path mappings for faster lookup.

=head1 SEE ALSO

L<MogileFS::Cache::Memcache>



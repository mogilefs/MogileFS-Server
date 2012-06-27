package MogileFS::Cache;
use strict;
use MogileFS::Util qw(error);

use constant CACHE_DEFAULT_TTL => 3600;

my $have_memc_module = eval "use Cache::Memcached; 1;";
my $have_redis_module = eval "use Redis; 1;";

sub new {
    my ($class) = @_;
    return $class->new_from_config;
}

sub new_from_config {
    my ($class) = @_;

    return undef unless ($have_memc_module || $have_redis_module);

    my ($type, $servers) = (MogileFS->config('cache_type'), MogileFS->config('cache_servers'));
    return undef unless defined($type);

    my $subclass;
    if ($type eq "none") {
        return undef;
    } elsif ($type eq "memcache" && $have_memc_module) {
        $subclass = "MogileFS::Cache::Memcache";
    } elsif ($type eq "redis" && $have_redis_module) {
        $subclass = "MogileFS::Cache::Redis";
    } else {
        error("Cache type not supported: $type");
        return undef;
    }
    unless (eval "use $subclass; 1") {
        error("Error loading $subclass: $@");
        return undef;
    }

    my $cache_ttl = MogileFS->config('cache_ttl') || CACHE_DEFAULT_TTL;

    my $self = bless {
        servers => $servers,
        ttl     => $cache_ttl,
    }, $subclass;
    $self->init;
    return $self;
}

sub init { 1 }

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

1;

__END__

=head1 NAME

MogileFS::Cache - path cache provider.  base class.

=head1 ABOUT

Caches key-path mappings for faster lookup.

=head1 SEE ALSO

L<MogileFS::Cache::Memcache>



# private base class for poolable HTTP/Mogstored sidechannel connections
# This is currently only used by HTTP, but is intended for Mogstored
# connections, too.
package MogileFS::Connection::Poolable;
use strict;
use warnings;
use Danga::Socket;
use base qw(Danga::Socket);
use fields (
    'mfs_pool',       # owner of the connection (MogileFS::ConnectionPool)
    'mfs_hostport',   # [ ip, port ]
    'mfs_expire',     # Danga::Socket::Timer object
    'mfs_expire_cb',  # Danga::Socket::Timer callback
    'mfs_requests',   # number of requests made on this object
    'mfs_err',        # used to propagate an error to start()
    'mfs_writeq',     # arrayref if connecting, undef otherwise
);
use Socket qw(SO_KEEPALIVE);
use Time::HiRes;

# subclasses (MogileFS::Connection::{HTTP,Mogstored}) must call this sub
sub new {
    my ($self, $sock, $ip, $port) = @_;
    $self->SUPER::new($sock); # Danga::Socket->new

    # connection may not be established, yet
    # so Danga::Socket->peer_addr_string can't be used here
    $self->{mfs_hostport} = [ $ip, $port ];
    $self->{mfs_requests} = 0;

    # newly-created socket, we buffer writes until event_write is triggered
    $self->{mfs_writeq} = [];

    return $self;
}

# used by ConnectionPool for tracking per-hostport connection counts
sub key { join(':', @{$_[0]->{mfs_hostport}}); }

# backwards compatibility
sub host_port { $_[0]->key; }

sub ip_port { @{$_[0]->{mfs_hostport}}; }

sub fd { fileno($_[0]->sock); }

# marks a connection as idle, call this before putting it in a connection
# pool for eventual reuse.
sub mark_idle {
    my ($self) = @_;

    $self->watch_read(0);

    # set the keepalive flag the first time we're idle
    $self->sock->sockopt(SO_KEEPALIVE, 1) if $self->{mfs_requests} == 0;

    $self->{mfs_requests}++;
}

sub write {
    my ($self, $arg) = @_;
    my $writeq = $self->{mfs_writeq};

    if (ref($writeq) eq "ARRAY") {
        # if we're still connecting, we must buffer explicitly for *BSD
        # and not attempt a real write() until event_write is triggered
        push @$writeq, $arg;
        $self->watch_write(1); # enable event_write triggering
        0; # match Danga::Socket::write return value
    } else {
        $self->SUPER::write($arg);
    }
}

# Danga::Socket will trigger this when a socket is writable
sub event_write {
    my ($self) = @_;

    # we may have buffered writes in mfs_writeq during non-blocking connect(),
    # this is needed on *BSD but unnecessary (but harmless) on Linux.
    my $writeq = delete $self->{mfs_writeq};
    if ($writeq) {
        $self->watch_write(0); # ->write will re-enable if needed
        foreach my $queued (@$writeq) {
            $self->write($queued);
        }
    } else {
        $self->SUPER::event_write();
    }
}

# the request running on this connection is retryable if this socket
# has ever been marked idle.  The connection pool can never be 100%
# reliable for detecting dead sockets, and all HTTP requests made by
# MogileFS are idempotent.
sub retryable {
    my ($self, $reason) = @_;
    return ($reason !~ /timeout/ && $self->{mfs_requests} > 0);
}

# Sets (or updates) the timeout of the connection
# timeout_key is "node_timeout" or "conn_timeout"
# clears the current timeout if timeout_key is undef
sub set_timeout {
    my ($self, $timeout_key) = @_;
    my $mfs_pool = $self->{mfs_pool};

    $self->SetPostLoopCallback(undef);
    if ($timeout_key) {
        my $timeout;

        if ($timeout_key =~ /\A[a-z_]+\z/) {
            $timeout = MogileFS->config($timeout_key) || 2;
        } else {
            $timeout = $timeout_key;
            $timeout_key = "timeout";
        }

        my $t0 = Time::HiRes::time();
        $self->{mfs_expire} = $t0 + $timeout;
        $self->{mfs_expire_cb} = sub {
            my ($now) = @_;
            my $elapsed = $now - $t0;

            # for HTTP, this will fake an HTTP error response like LWP does
            $self->err("$timeout_key: $timeout (elapsed: $elapsed)");
        };
        $mfs_pool->register_timeout($self, $timeout) if $mfs_pool;
    } else {
        $self->{mfs_expire} = $self->{mfs_expire_cb} = undef;
        $mfs_pool->register_timeout($self, undef) if $mfs_pool;
    }
}

# returns the expiry time of the connection
sub expiry { $_[0]->{mfs_expire} }

# runs expiry callback and returns true if time is up,
# returns false if there is time remaining
sub expired {
    my ($self, $now) = @_;
    my $expire = $self->{mfs_expire} or return 0;
    $now ||= Time::HiRes::time();

    if ($now >= $expire) {
        my $expire_cb = delete $self->{mfs_expire_cb};
        if ($expire_cb && $self->sock) {
            $self->SetPostLoopCallback(sub { $expire_cb->($now); 1 });
        }
        return 1;
    }
    return 0;
}

# may be overridden in subclass, called only on errors
# The HTTP version of this will fake an HTTP response for LWP compatibility
sub err {
    my ($self, $close_reason) = @_;

    $self->inflight_expire; # ensure we don't call new_err on eventual close()

    if ($close_reason =~ /\A:event_(?:hup|err)\z/) {
        # there's a chance this can be invoked while inflight,
        # conn_drop will handle this case appropriately
        $self->{mfs_pool}->conn_drop($self, $close_reason) if $self->{mfs_pool};
    } else {
        $self->close($close_reason);
    }
}

# sets the pool this connection belongs to, only call from ConnectionPool
sub set_pool {
    my ($self, $pool) = @_;

    $self->{mfs_pool} = $pool;
}

# closes a connection, and may reschedule the inflight callback if
# close_reason is ":retry"
sub close {
    my ($self, $close_reason) = @_;

    delete $self->{mfs_expire_cb}; # avoid circular ref

    my $mfs_pool = delete $self->{mfs_pool}; # avoid circular ref
    my $inflight_cb;

    if ($mfs_pool) {
        $mfs_pool->schedule_queued;
        $inflight_cb = $mfs_pool->conn_close_prepare($self, $close_reason);
    }
    $self->SUPER::close($close_reason); # Danga::Socket->close

    if ($inflight_cb && $close_reason) {
        if ($close_reason eq ":retry") {
            my ($ip, $port) = $self->ip_port;

            $mfs_pool->enqueue($ip, $port, $inflight_cb);
        } else {
            # Danga::Socket-scheduled write()s which fail with ECONNREFUSED,
            # EPIPE, or "write_error" after an initial (non-blocking)
            # connect()
            $mfs_pool->on_next_tick(sub {
                ref($self)->new_err($close_reason || "error", $inflight_cb);
            });
        }
    }
}

# Marks a connection as no-longer inflight.  Calling this prevents retries.
sub inflight_expire {
    my ($self) = @_;
    my $mfs_pool = $self->{mfs_pool};
    die "BUG: expiring without MogileFS::ConnectionPool\n" unless $mfs_pool;
    $mfs_pool->inflight_cb_expire($self);
}

# Danga::Socket callbacks
sub event_hup { $_[0]->err(':event_hup'); }
sub event_err { $_[0]->err(':event_err'); }

# called when we couldn't create a socket, but need to create an object
# anyways for errors (creating fake, LWP-style error responses)
sub new_err {
    my ($class, $err, $start_cb) = @_;
    my $self = fields::new($class);
    $self->{mfs_err} = $err;
    # on socket errors
    $start_cb->($self);
}

# returns this connection back to its associated pool.
# Returns false if not successful (pool is full)
sub persist {
    my ($self) = @_;
    my $mfs_pool = $self->{mfs_pool};

    return $mfs_pool ? $mfs_pool->conn_persist($self) : 0;
}

1;

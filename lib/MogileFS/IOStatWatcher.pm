package MogileFS::IOStatWatcher;
use strict;
use Sys::Syscall 0.22; # We use it indirectly, and trigger bugs in earlier versions.
use Danga::Socket;
use IO::Socket::INET;

=head1 Methods

=head2 $iow = MogileFS::IOStatWatcher->new()

Returns a new IOStatWatcher object.

=cut

sub new {
    my ($class) = @_;
    my $self = bless {
        hosts => {},
    }, $class;
    $self->on_stats; # set an empty handler.
    return $self;
}

=head2 $iow->set_hosts( host1 [, host2 [, ...] ] )

Sets the list of hosts to connect to for collecting IOStat information. This call can block if you
pass it hostnames instead of ip addresses.

Upon successful connection, the on_stats callback will be called each time the statistics are
collected. Error states (failed connections, etc.) will trigger retries on 60 second intervals, and
disconnects will trigger an immediate reconnect.

=cut

sub set_hosts {
    my ($self, @ips) = @_;
    my $old_hosts = $self->{hosts};
    my $new_hosts = {};
    foreach my $host (@ips) {
        $new_hosts->{$host} = (delete $old_hosts->{$host}) || MogileFS::IOStatWatch::Client->new($host, $self);
    }
    # TODO: close hosts that were removed (things in %$old_hosts)
    $self->{hosts} = $new_hosts;
}

=head2 $iow->on_stats( coderef )

Sets the coderef called for the C<on_stats> callback.

=cut

sub on_stats {
    my ($self, $cb) = @_;

    unless (ref $cb eq 'CODE') {
        $cb = sub {};
    }

    $self->{on_stats} = $cb;
}

=head1 Callbacks

=head2 on_stats->( host, stats )

Called each time device use statistics are collected. The C<host>
argument is the value passed in to the C<set_hosts> method. The
C<stats> object is a hashref of mogile device numbers (without leading
"dev") to their corresponding utilization percentages.

=cut

# Everything beyond here is internal.

sub got_stats {
    my ($self, $host, $stats) = @_;
    $self->{on_stats}->($host, $stats);
}

sub restart_monitoring_if_needed {
    my ($self, $host) = @_;
    return unless $self->{hosts}->{$host} && $self->{hosts}->{$host}->{closed};
    $self->{hosts}->{$host} = MogileFS::IOStatWatch::Client->new($host, $self);
}

sub got_error {
    my ($self, $host) = @_;
    Danga::Socket->AddTimer(60, sub {
        $self->restart_monitoring_if_needed($host);
    });
}

sub got_disconnect {
    my ($self, $host) = @_;
    $self->{hosts}->{$host} = MogileFS::IOStatWatch::Client->new($host, $self);
}

# Support class that does the communication with individual hosts.
package MogileFS::IOStatWatch::Client;

use strict;
use warnings;

use base 'Danga::Socket';
use fields qw(host watcher buffer active);

sub new {
    my MogileFS::IOStatWatch::Client $self = shift;
    my $hostspec = shift;
    my $watcher = shift;

    my $sock = IO::Socket::INET->new(
                                     PeerAddr => $hostspec,
                                     PeerPort => MogileFS->config("mogstored_stream_port"),
                                     Proto    => 'tcp',
                                     Blocking => 0,
                                     );
    return unless $sock;

    $self = fields::new($self) unless ref $self;
    $self->SUPER::new($sock);
    $self->watch_write(1);
    $self->watch_read(1);

    $self->{watcher} = $watcher;
    $self->{buffer} = '';
    $self->{host} = $hostspec;

    return $self;
}

sub event_write {
    my MogileFS::IOStatWatch::Client $self = shift;
    $self->{active} = 1;
    $self->write("watch\n");
    $self->watch_write(0); # I hope I can safely assume that 6 characters will write properly.
}

sub event_read {
    my MogileFS::IOStatWatch::Client $self = shift;

    my $bref = $self->read(10240);
    return $self->close unless defined $bref;

    $self->{buffer} .= $$bref;

    if ($self->{buffer} =~ m/^ERR\s+(.*?)\s* $ /x) {
        # There was an error on the way to watching this machine, close it and stay quiet.
        $self->close;
    }

    # If we can yank off lines till there is one by itself with a . on it, we've gotten a full set of stats.
    while ($self->{buffer} =~ s/^(.*?\n)?\.\n//s) {
        my %stats;
        foreach my $line (split /\n+/, $1) {
            next unless $line;
            my ($devnum, $util, $await, $svctm) = split /\s+/, $line;
            $stats{$devnum} = (
                await => $await,
                svctm => $svctm,
                util => $util
            );
        }
        $self->{watcher}->got_stats($self->{host}, \%stats);
    }
}

sub event_err {
    my MogileFS::IOStatWatch::Client $self = shift;
    $self->{watcher}->got_error($self->{host});
}

sub event_hup {
    my MogileFS::IOStatWatch::Client $self = shift;
    $self->{watcher}->got_error($self->{host});
}

sub close {
    my MogileFS::IOStatWatch::Client $self = shift;
    if ($self->{active}) {
        $self->{watcher}->got_disconnect($self->{host});
    } else {
        $self->{watcher}->got_error($self->{host});
    }
    $self->SUPER::close(@_);
}
1;


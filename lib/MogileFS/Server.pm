package MogileFS::Server;
use strict;
use warnings;
use vars qw($VERSION);
$VERSION = "2.72";

=head1 NAME

MogileFS::Server - MogileFS (distributed filesystem) server

=head1 SYNOPSIS

 $s = MogileFS::Server->server;
 $s->run;

=cut

use IO::Socket;
use Symbol;
use POSIX;
use File::Copy ();
use Carp;
use File::Basename ();
use File::Path ();
use Sys::Syslog ();
use Time::HiRes ();
use Net::Netmask;
use List::Util;
use Socket qw(SO_KEEPALIVE IPPROTO_TCP TCP_NODELAY);

use MogileFS::Util qw(daemonize);
use MogileFS::Config;

use MogileFS::ProcManager;
use MogileFS::Connection::Client;
use MogileFS::Connection::Worker;

use MogileFS::Worker::Query;
use MogileFS::Worker::Delete;
use MogileFS::Worker::Replicate;
use MogileFS::Worker::Reaper;
use MogileFS::Worker::Monitor;
use MogileFS::Worker::Fsck;
use MogileFS::Worker::JobMaster;

use MogileFS::Factory::Domain;
use MogileFS::Factory::Class;
use MogileFS::Factory::Host;
use MogileFS::Factory::Device;
use MogileFS::Domain;
use MogileFS::Class;
use MogileFS::Host;
use MogileFS::Device;

use MogileFS::HTTPFile;
use MogileFS::FID;
use MogileFS::DevFID;

use MogileFS::Store;

use MogileFS::ReplicationPolicy::MultipleHosts;

my $server; # server singleton
sub server {
    my ($pkg) = @_;
    return $server ||= bless {}, $pkg;
}

# --------------------------------------------------------------------------
# instance methods:
# --------------------------------------------------------------------------

sub run {
    my $self = shift;

    MogileFS::Config->load_config;

    # don't run as root
    die "mogilefsd cannot be run as root\n"
        if $< == 0 && MogileFS->config('user') ne "root";

    MogileFS::Config->check_database;
    daemonize() if MogileFS->config("daemonize");

    MogileFS::ProcManager->set_min_workers('monitor'     => 1);

    # open up our log
    Sys::Syslog::openlog('mogilefsd', 'pid', 'daemon');
    Mgd::log('info', 'beginning run');

    unless (MogileFS::ProcManager->write_pidfile) {
        Mgd::log('info', "Couldn't write pidfile, ending run");
        Sys::Syslog::closelog();
        exit 1;
    }

    # Install signal handlers.
    $SIG{TERM}  = sub {
        my @children = MogileFS::ProcManager->child_pids;
        print STDERR scalar @children, " children to kill.\n" if $DEBUG;
        my $count = kill( 'TERM' => @children );
        print STDERR "Sent SIGTERM to $count children.\n" if $DEBUG;
        MogileFS::ProcManager->remove_pidfile;
        Mgd::log('info', 'ending run due to SIGTERM');
        Sys::Syslog::closelog();

        exit 0;
    };

    $SIG{INT}  = sub {
        my @children = MogileFS::ProcManager->child_pids;
        print STDERR scalar @children, " children to kill.\n" if $DEBUG;
        my $count = kill( 'INT' => @children );
        print STDERR "Sent SIGINT to $count children.\n" if $DEBUG;
        MogileFS::ProcManager->remove_pidfile;
        Mgd::log('info', 'ending run due to SIGINT');
        exit 0;
    };
    $SIG{PIPE} = 'IGNORE';  # catch them by hand

    # setup server sockets to listen for client connections
    my @servers;
    foreach my $listen (@{ MogileFS->config('listen') }) {
        my $server = IO::Socket::INET->new(LocalAddr => $listen,
                                           Type      => SOCK_STREAM,
                                           Proto     => 'tcp',
                                           Blocking  => 0,
                                           Reuse     => 1,
                                           Listen    => 1024 )
            or die "Error creating socket: $@\n";
        $server->sockopt(SO_KEEPALIVE, 1);
        $server->setsockopt(IPPROTO_TCP, TCP_NODELAY, 1);

        # save sub to accept a client
        push @servers, $server;
        Danga::Socket->AddOtherFds( fileno($server) => sub {
                while (my $csock = $server->accept) {
                    MogileFS::Connection::Client->new($csock);
                }
            } );
    }

    MogileFS::ProcManager->push_pre_fork_cleanup(sub {
        # so children don't hold server connection open
        close($_) foreach @servers;
    });

    # setup the post event loop callback to spawn jobs, and the timeout
    Danga::Socket->DebugLevel(3);
    Danga::Socket->SetLoopTimeout( 250 ); # 250 milliseconds
    Danga::Socket->SetPostLoopCallback(MogileFS::ProcManager->PostEventLoopChecker);

    # and now, actually start listening for events
    eval {
        print( "Starting event loop for frontend job on pid $$.\n" ) if $DEBUG;
        Danga::Socket->EventLoop();
    };

    if ($@) {
        Mgd::log('err', "crash log: $@");
        exit 1;
    }
    Mgd::log('info', 'ending run');
    Sys::Syslog::closelog();
    exit(0);
}

# --------------------------------------------------------------------------

package MogileFS;
# just so MogileFS->config($key) will work:
use MogileFS::Config qw(config);

my %hooks;

sub register_worker_command {
    # just pass this through to the Worker class
    return MogileFS::Worker::Query::register_command(@_);
}

sub register_global_hook {
    $hooks{$_[0]} = $_[1];
    return 1;
}

sub unregister_global_hook {
    delete $hooks{$_[0]};
    return 1;
}

sub run_global_hook {
    my $hookname = shift;
    my $ref = $hooks{$hookname};
    return $ref->(@_) if defined $ref;
    return undef;
}

# --------------------------------------------------------------------------

package Mgd;  # conveniently short name
use strict;
use warnings;
use MogileFS::Config;
use MogileFS::Util qw(error fatal debug); # for others calling Mgd::foo()
use Socket qw(SOL_SOCKET SO_RCVBUF AF_UNIX SOCK_STREAM PF_UNSPEC);
BEGIN {
    # detect the receive buffer size for Unix domain stream sockets,
    # we assume the size is identical across all Unix domain sockets.
    socketpair(my $s1, my $s2, AF_UNIX, SOCK_STREAM, PF_UNSPEC)
        or die( "socketpair failed: $!" );

    my $r = getsockopt($s1, SOL_SOCKET, SO_RCVBUF);
    defined $r or die "getsockopt: $!";
    $r = unpack('i', $r) if defined $r;
    $r = (defined $r && $r > 0) ? $r : 8192;
    close $s1;
    close $s2;
    eval 'use constant UNIX_RCVBUF_SIZE => $r';
}

sub server {
    return MogileFS::Server->server;
}

# database checking/connecting
sub validate_dbh { 
    my $sto = Mgd::get_store();
    my $had_dbh = $sto->have_dbh;
    $sto->recheck_dbh();
    my $dbh;
    eval { $dbh = $sto->dbh };
    # Doesn't matter what the failure was; workers should retry later.
    error("Error validating master DB: $@") if $@ && $had_dbh;
    return $dbh;
}

# the eventual replacement for callers asking for a dbh directly:
# they'll ask for the current store, which is a database abstraction
# layer.
my ($store, $store_pid);
sub get_store {
    return $store if $store && $store_pid == $$;
    $store_pid = $$;
    return $store = MogileFS::Store->new;
}

sub close_store {
    if ($store) {
        $store->dbh->disconnect();
        $store = undef;
        return 1;
    }
    return 0;
}

# only for t/ scripts to explicitly set a store, without loading in a config
sub set_store {
    my ($s) = @_;
    $store = $s;
    $store_pid = $$;
}

sub domain_factory {
    return MogileFS::Factory::Domain->get_factory;
}

sub class_factory {
    return MogileFS::Factory::Class->get_factory;
}

sub host_factory {
    return MogileFS::Factory::Host->get_factory;
}

sub device_factory {
    return MogileFS::Factory::Device->get_factory;
}

# log stuff to syslog or the screen
sub log {
    # simple logging functionality
    if (! $MogileFS::Config::daemonize) {
        $| = 1;
        # syslog acts like printf so we have to use printf and append a \n
        shift; # ignore the first parameter (info, warn, critical, etc)
        my $mask = shift; # format string
        $mask .= "\n" unless $mask =~ /\n$/;
        my $message = @_ ? sprintf($mask, @_) : $mask;
        print '[', scalar localtime(), '] ', $message;
    } else {
        # just pass the parameters to syslog
        Sys::Syslog::syslog(@_);
    }
}

1;
__END__
#Just for MakeMaker's kinda lame regexp for ABSTRACT_FROM
=pod

mogilefs::server - MogileFS (distributed filesystem) server.

=cut


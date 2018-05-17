package Mogstored::HTTPServer::Lighttpd;
use strict;
use base 'Mogstored::HTTPServer';
use File::Temp ();

sub start {
    my $self = shift;
    my $exe = $self->{bin};

    if ($exe && ! -x $exe) {
        die "Provided lighttpd path $exe not valid.\n";
    }
    unless ($exe) {
        my @loc = qw(/usr/local/sbin/lighttpd
                     /usr/sbin/lighttpd
                     /usr/local/bin/lighttpd
                     /usr/bin/lighttpd
                     );
        foreach my $loc (@loc) {
            $exe = $loc;
            last if -x $exe;
        }
        unless (-x $exe) {
            die "Can't find lighttpd in @loc\n";
        }
    }

    my $pid = fork();
    die "Can't fork: $!" unless defined $pid;

    if ($pid) {
        $self->{pid} = $pid;
        Mogstored->on_pid_death($pid => sub {
            die "lighttpd died";
        });
        return;
    }

    my ($fh, $filename) = File::Temp::tempfile();
    $self->{temp_conf_file} = $filename;

    my $portnum = $self->listen_port;
    my $bind_ip = $self->bind_ip;
    
    my $include_line = sprintf('include "%s"', $self->{include})
        if $self->{include};

    print $fh qq{
server.document-root = "$self->{docroot}"
server.port = $portnum
server.bind = "$bind_ip"
server.modules = ( "mod_webdav", "mod_status" )
webdav.activate = "enable"
status.status-url  = "/"
$include_line
};

    exec $exe, "-D", "-f", $filename;
}

sub stop {
    my $self = shift;
    if ($self->{pid}) {
        kill 'INT', $self->{pid};
    }
    unlink $self->{temp_conf_file} if $self->{temp_conf_file};
}

1;

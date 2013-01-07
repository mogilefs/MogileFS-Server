package Mogstored::HTTPServer::Nginx;
use strict;
use base 'Mogstored::HTTPServer';

sub start {
    my $self = shift;

    $self->{pid_file}  = "/var/run/mogstored/nginx.pid";
    $self->{conf_file} = "/var/run/mogstored/nginx.conf";

    my $exe = $self->{bin};
    if ($exe && ! -x $exe) {
        die "Provided nginx path $exe not valid.\n";
    }
    unless ($exe) {
        my @loc = qw(/usr/sbin/nginx
            /usr/local/bin/nginx
            /usr/bin/nginx
        );
        foreach my $loc (@loc) {
            $exe = $loc;
            last if -x $exe;
        }
        unless (-x $exe) {
            die "Can't find nginx in @loc\n";
        }
    }

    my $pid = _getpid($self->{pid_file});
    if ($pid) {
        my $killed = kill 'TERM', $pid;
        if ($killed > 0) {
            print "Killed nginx on PID $pid";
        }
    }
    
    my $listen_port = $self->listen_port;
    my $bind_ip = $self->bind_ip;

    my $client_max_body_size = "0";
    $client_max_body_size = $self->{client_max_body_size} if $self->{client_max_body_size};

    my @devdirs = _devs($self->{docroot});
    my $config_devices = '';
    foreach my $devdir (@devdirs) {
        $config_devices .= qq{
        location /$devdir {
            root $self->{docroot};
            client_body_temp_path $self->{docroot}/$devdir/.tmp;
            dav_methods put delete;
            dav_access user:rw group:r all:r;
            create_full_put_path on;
        }
        };
    }
   
    open FH, ">$self->{conf_file}"; 
    print FH qq{pid $self->{pid_file};
error_log /var/log/nginx-mogile/error.log;
worker_processes 15;
events {
    worker_connections 1024;
}
http {
    default_type application/octet-stream;
    sendfile on;
    keepalive_timeout 0;
    tcp_nodelay on;
    client_max_body_size $client_max_body_size;
    server_tokens off;
    access_log /var/log/nginx-mogile/mogile-access.log;
    error_log /var/log/nginx-mogile/mogile-error.log;
    server {
        listen $bind_ip:$listen_port;
        charset utf-8;

        location / {
            autoindex on;
            root $self->{docroot};
        }
        $config_devices
    }
}
};

    close FH;
    system $exe, "-c", $self->{conf_file};

    return 1;
}

sub stop {
	my $self = shift;
    my $pid = _getpid($self->{pid_file});
    if ($pid) {
        kill 'TERM', $pid;
    }
	unlink $self->{conf_file};
}

sub _devs {
    my $root = shift;
    opendir(my $dh, $root) or die "Failed to open docroot: $root: $!";
    return grep { /^dev\d+$/ } readdir($dh);
}

sub _getpid {
    my $pid_file = shift;
    local $/ = undef;
    open FILE, $pid_file or return;
    binmode FILE;
    my $pid = <FILE>;
    close FILE;
    return $pid;
}

sub DESTROY {
    my $self = shift;
    unlink $self->{conf_file} if $self->{conf_file};
}

1;
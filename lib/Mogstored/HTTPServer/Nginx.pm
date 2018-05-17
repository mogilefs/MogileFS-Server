package Mogstored::HTTPServer::Nginx;

use strict;
use base 'Mogstored::HTTPServer';
use File::Temp ();

# returns an version number suitable for numeric comparison
sub ngx_version {
    my ($major, $minor, $point) = @_;
    return ($major << 16) + ($minor << 8) + $point;
}

sub start {
    my $self = shift;
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

    # get meta-data about nginx binary
    my $nginxMeta = `$exe -V 2>&1`;
    my $ngxVersion = ngx_version(0,0,0);
    if($nginxMeta =~ /nginx\/(\d+)\.(\d+)\.(\d+)/sog) {
        $ngxVersion = ngx_version($1,$2,$3);
    }

    # determine if nginx can be run in non-daemon mode, supported in $version >= 1.0.9 (non-daemon provides better shutdown/crash support)
    # See: http://nginx.org/en/docs/faq/daemon_master_process_off.html
    my $nondaemon = $ngxVersion >= ngx_version(1, 0, 9);

    # create tmp directory
    my $tmpDir = $self->{docroot} . '/.tmp';
    mkdir $tmpDir;
    mkdir $tmpDir.'/logs';

    $self->{pid_file} = $tmpDir . '/nginx.pid';

    # fork if nginx supports non-daemon mode
    if($nondaemon) {
        my $pid = fork();
        die "Can't fork: $!" unless defined $pid;

        if ($pid) {
            $self->{pid} = $pid;
            Mogstored->on_pid_death($pid => sub {
                die "nginx died";
            });
            return;
        }
    }
    # otherwise, try killing previous instance of nginx
    else {
        my $nginxpid = _getpid($self->{pid_file});
        # TODO: Support reloading of nginx instead?
        if ($nginxpid) {
            my $killed = kill 15,$nginxpid;
            if ($killed > 0) {
                print "Killed nginx on PID # $nginxpid";
            }
        }
    }

    my ($fh, $filename) = File::Temp::tempfile();
    $self->{temp_conf_file} = $filename;

    my $portnum = $self->listen_port;
    my $bind_ip = $self->bind_ip;

    my $client_max_body_size = "0";
    $client_max_body_size = $self->{client_max_body_size}
        if $self->{client_max_body_size};

    # TODO: Pull from config file?
    #print "client_max_body_size = $client_max_body_size\n";

    my @devdirs = _disks($self->{docroot});
    my $devsection = '';

    foreach my $devid (@devdirs) {
        my $devseg = qq{
            location /$devid {
                client_body_temp_path $self->{docroot}/$devid/.tmp;
                dav_methods put delete;
                dav_access user:rw group:rw all:r;
                create_full_put_path on;
            }
        };
        $devsection .= $devseg;
    }

    # determine which temp_path directives are required to isolate this instance of nginx
    my $tempPath = "client_body_temp_path $tmpDir/client_body_temp;\n";
    unless($nginxMeta =~ /--without-http_fastcgi_module/sog) {
        $tempPath .= "fastcgi_temp_path $tmpDir/fastcgi_temp;\n";
    }
    unless($nginxMeta =~ /--without-http_proxy_module/sog) {
        $tempPath .= "proxy_temp_path $tmpDir/proxy_temp;\n";
    }

    # Debian squeeze (stable as of 2013/01) is only on nginx 0.7.67

    # uwsgi support appeared in nginx 0.8.40
    if ($ngxVersion >= ngx_version(0, 8, 40)) {
        unless($nginxMeta =~ /--without-http_uwsgi_module/sog) {
            $tempPath .= "uwsgi_temp_path $tmpDir/uwsgi_temp;\n";
        }
    }

    # scgi support appeared in nginx 0.8.42
    if ($ngxVersion >= ngx_version(0, 8, 42)) {
        unless($nginxMeta =~ /--without-http_scgi_module/sog) {
            $tempPath .= "scgi_temp_path $tmpDir/scgi_temp;\n";
        }
    }

    my $user = $> == 0 ? "user root root;" : "";

    print $fh qq{
        pid $self->{pid_file};
        worker_processes 15;
        error_log /dev/null crit;
        $user
        events {
            worker_connections 1024;
        }
        http {
            default_type application/octet-stream;
            sendfile on;
            keepalive_timeout 0;
            client_max_body_size $client_max_body_size;
            server_tokens off;
            access_log off;
            charset utf-8;
            server {
                listen $bind_ip:$portnum;
                root $self->{docroot};

                $devsection
                location /.tmp {
                    deny all;
                }
                location / {
                    autoindex on;
                }
            }

            $tempPath
        }

        lock_file $tmpDir/lock_file;
    };
    close $fh;

    # start nginx
    if($nondaemon) {
        exec $exe, '-p', $tmpDir, '-g', 'daemon off;', '-c', $filename;
        exit;
    }
    else {
        my $retval = system $exe, '-p', $tmpDir, '-c', $filename;
        die "nginx failed to start\n" if($retval != 0);
    }

    return 1;
}

sub _disks {
    my $root = shift;
    opendir(my $dh, $root) or die "Failed to open docroot: $root: $!";
    return grep { /^dev\d+$/ } readdir($dh);
}

sub _getpid {
    my ($nginxpidfile) = @_;
    local $/ = undef;
    open FILE, $nginxpidfile or return;
    binmode FILE;
    my $string = <FILE>;
    close FILE;
    return $string;
}

sub stop {
    my $self = shift;
    my $pid = _getpid($self->{pid_file});
    if ($pid) {
        kill 'QUIT', $pid;
    }
    unlink $self->{temp_conf_file} if $self->{temp_conf_file};
}

1;

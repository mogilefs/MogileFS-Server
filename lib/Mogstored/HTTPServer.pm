package Mogstored::HTTPServer;
use strict;
sub new {
    my ($class, %opts) = @_;
    my $self = bless {}, $class;
    $self->{docroot}  = delete $opts{docroot};
    $self->{listen}   = delete $opts{listen};
    $self->{maxconns} = delete $opts{maxconns};
    $self->{bin}      = delete $opts{bin};
    $self->{include}  = delete $opts{include};
    die "unknown opts" if %opts;
    return $self;
}

sub start {
    my $self = shift;
    die "start not implemented for $self";
}

sub stop {
    my $self = shift;
    die "stop not implemented for $self";
}

sub pre_daemonize {
    my $self = shift;
}

sub post_daemonize {
    my $self = shift;
}

sub listen_port {
    my $self = shift;
    my $port = $self->{listen};
    $port =~ s/^.+://;
    die "not numeric port?" unless $port =~ /^\d+$/;
    return $port;
}

sub bind_ip {
    my $self = shift;
    if ($self->{listen} =~ /^(.+):\d+$/) {
        return $1;
    } elsif ($self->{listen} =~ /^\d+$/) {
        return "0.0.0.0";
    } else {
        die "Bogus listen value?";
    }
}

1;

package MogileFS::Domain;
use strict;
use warnings;
use MogileFS::Server;
use MogileFS::Util qw(throw);

=head1

MogileFS::Domain - domain class.

=cut

sub new_from_args {
    my ($class, $args, $class_factory) = @_;
    return bless {
        class_factory => $class_factory,
        %{$args},
    }, $class;
}

# Instance methods:

sub id   { $_[0]{dmid} }
sub name { $_[0]{namespace} }

sub has_files {
    my $self = shift;
    return 1 if $Mgd::_T_DOM_HAS_FILES;
    return Mgd::get_store()->domain_has_files($self->id);
}

sub classes {
    my $self = shift;
    return $self->{class_factory}->get_all($self);
}

sub class {
    my $self = shift;
    return $self->{class_factory}->get_by_name($self, $_[0]);
}

sub observed_fields {
    return {};
}

1;

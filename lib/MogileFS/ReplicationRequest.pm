package MogileFS::ReplicationRequest;
use strict;
use MogileFS::Server;
require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(rr_upgrade ALL_GOOD TOO_GOOD TEMP_NO_ANSWER);

my $no_answer = bless { temp_fail => 1 };
sub TEMP_NO_ANSWER () { $no_answer }
my $all_good = bless { all_good => 1 };
sub ALL_GOOD () { $all_good }
my $too_good = bless { all_good => 1, too_good => 1 };
sub TOO_GOOD () { $too_good }

# upgrades the return values from old-style ReplicationPolicy classes
# to MogileFS::ReplicationRequest objects, unless they already are,
# in which case they're passed through unchanged.  provides peaceful
# upgrade path for old plugins.
sub rr_upgrade {
    my ($rv) = @_;
    return $rv            if ref $rv;
    return TEMP_NO_ANSWER if !defined $rv;
    return ALL_GOOD       if !$rv;
    return MogileFS::ReplicationRequest->replicate_to($rv);
}

# for ideal replications
sub replicate_to {
    my ($class, @devs) = @_;
    @devs = map { ref $_ ? $_ : Mgd::device_factory()->get_by_id($_) } @devs;
    return bless {
        ideal_next => \@devs,
    }, $class;
}

sub new {
    my ($class, %opts) = @_;
    my $self = bless {}, $class;
    $self->{ideal_next}     = delete $opts{ideal}     || [];
    $self->{desperate_next} = delete $opts{desperate} || [];
    Carp::croak("unknown args") if %opts;
    return $self;
}

############################################################################

sub is_happy {
    my $self = shift;
    return $self->{all_good};
}

sub too_happy {
    my $self = shift;
    return $self->{too_good};
}

sub temp_fail {
    my $self = shift;
    return $self->{temp_fail};
}

# returns array of MogileFS::Device objs, in preferred order, one of
# which (but not multiple) would satisfy the replication policy
# for its next step.  at which point the replication policy needs
# to be asked again what the next step is.
sub copy_to_one_of_ideally {
    my $self = shift;
    return @{ $self->{ideal_next} || [] };
}

# like above, but replication policy isn't happy about these choices,
# so a reevaluation of this replication decision should be made in the
# future, when new disks/hosts might be available.
sub copy_to_one_of_desperate {
    my $self = shift;
    return @{ $self->{desperate_next} || [] };
}

# for test suite..
sub t_as_string {
    my $self = shift;
    return "too_good"  if $self->{too_good};
    return "all_good"  if $self->{all_good};
    return "temp_fail" if $self->{temp_fail};
    my @devs;
    if (@devs = $self->copy_to_one_of_ideally) {
        return "ideal(" . join(",", sort {$a<=>$b} map { $_->id } @devs) . ")";
    }
    if (@devs = $self->copy_to_one_of_desperate) {
        return "desperate(" . join(",", sort {$a<=>$b}  map { $_->id } @devs) . ")";
    }
    die "unknown $self type";
}

1;


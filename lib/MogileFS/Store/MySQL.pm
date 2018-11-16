package MogileFS::Store::MySQL;
use strict;
use warnings;
use DBI 1.44;
use DBD::mysql;
use MogileFS::Util qw(throw);
use base 'MogileFS::Store';

# --------------------------------------------------------------------------
# Package methods we override
# --------------------------------------------------------------------------

sub dsn_of_dbhost {
    my ($class, $dbname, $host, $port) = @_;
    return "DBI:mysql:$dbname;host=$host" . ($port ? ";port=$port" : "");
}

sub dsn_of_root {
    my ($class, $dbname, $host, $port) = @_;
    return $class->dsn_of_dbhost('mysql', $host, $port);
}

# --------------------------------------------------------------------------
# Store-related things we override
# --------------------------------------------------------------------------

sub init {
    my $self = shift;
    $self->SUPER::init;
    $self->{lock_depth} = 0;
    $self->{slave_next_check} = 0;
}

sub post_dbi_connect {
    my $self = shift;
    $self->SUPER::post_dbi_connect;
    $self->{lock_depth} = 0;
}

sub was_deadlock_error {
    my $self = shift;
    my $dbh = $self->dbh;
    return 0 unless $dbh->err;
    # 1205 is "lock wait timeout", but we should bomb out if we've
    # already hung for that long.
    return 1 if ($dbh->err == 1213);
}

sub was_duplicate_error {
    my $self = shift;
    my $dbh = $self->dbh;
    return 0 unless $dbh->err;
    return 1 if $dbh->err == 1062 || $dbh->errstr =~ /duplicate/i;
}

sub table_exists {
    my ($self, $table) = @_;
    return eval {
        my $sth = $self->dbh->prepare("DESCRIBE $table");
        $sth->execute;
        my $rec = $sth->fetchrow_hashref;
        return $rec ? 1 : 0;
    };
}

sub can_replace      { 1 }
sub can_insertignore { 1 }
sub can_insert_multi { 1 }
sub unix_timestamp { "UNIX_TIMESTAMP()" }

sub filter_create_sql {
    my ($self, $sql) = @_;
    return $sql unless $self->fid_type eq "BIGINT";
    $sql =~ s!\bfid\s+INT\b!fid BIGINT!i;
    return $sql;
}

sub can_do_slaves { 1 }

sub check_slave {
    my $self = shift;

    return 0 unless $self->{slave};

    my $next_check = \$self->{slave}->{next_check};

    if ($$next_check > time()) {
        return 1;
    }

    #my $slave_status = eval { $self->{slave}->dbh->selectrow_hashref("SHOW SLAVE STATUS") };
    #warn "Error thrown: '$@' while trying to get slave status." if $@;

    # TODO: Check show slave status *unless* a server setting is present to
    # tell us to ignore it (like in a multi-DC setup).
    eval { $self->{slave}->dbh };
    if ($@) {
        warn "Error while checking slave: $@";
        return 0;
    }

    # call time() again here because SQL blocks.
    $$next_check = time() + 5;

    return 1;
}

# attempt to grab a lock of lockname, and timeout after timeout seconds.
# returns 1 on success and 0 on timeout
sub get_lock {
    my ($self, $lockname, $timeout) = @_;
    die "Lock recursion detected (grabbing $lockname, had $self->{last_lock}).  Bailing out." if $self->{lock_depth};

    my $lock = $self->dbh->selectrow_array("SELECT GET_LOCK(?, ?)", undef, $lockname, $timeout);
    if ($lock) {
        $self->{lock_depth} = 1;
        $self->{last_lock}  = $lockname;
    }
    return $lock;
}

# attempt to release a lock of lockname.
# returns 1 on success and 0 if no lock we have has that name.
sub release_lock {
    my ($self, $lockname) = @_;
    my $rv = $self->dbh->selectrow_array("SELECT RELEASE_LOCK(?)", undef, $lockname);
    $self->{lock_depth} = 0;
    return $rv;
}

sub lock_queue {
    my ($self, $type) = @_;
    my $lock = $self->get_lock('mfsd:' . $type, 30);
    return $lock ? 1 : 0;
}

sub unlock_queue {
    my ($self, $type) = @_;
    my $lock = $self->release_lock('mfsd:' . $type);
    return $lock ? 1 : 0;
}

# clears everything from the fsck_log table
# return 1 on success.  die otherwise.
# Under MySQL 4.1+ this is actually fast.
sub clear_fsck_log {
    my $self = shift;
    $self->dbh->do("TRUNCATE TABLE fsck_log");
    return 1;
}

# --------------------------------------------------------------------------
# Functions specific to Store::MySQL subclass.  Not in parent.
# --------------------------------------------------------------------------

sub fid_type {
    my $self = shift;
    return $self->{_fid_type} if $self->{_fid_type};

    # let people force bigint mode with environment.
    if ($ENV{MOG_FIDSIZE} && $ENV{MOG_FIDSIZE} eq "big") {
        return $self->{_fid_type} = "BIGINT";
    }

    # else, check a maybe-existing table and see if we're in bigint
    # mode already.
    my $dbh = $self->dbh;
    my @create = eval { $dbh->selectrow_array("SHOW CREATE TABLE file") };
    if (@create && $create[0] eq 'file') {
        if ($create[1] =~ /\bfid\b.+\bbigint\b/i) {
            return $self->{_fid_type} = "BIGINT";
        } else {
            return $self->{_fid_type} = "INT";
        }
    }

    # Used to default to 32bit ints, but this always bites people
    # a few years down the road. So default to 64bit.
    return $self->{_fid_type} = "BIGINT";
}

sub column_type {
    my ($self, $table, $col) = @_;
    my $sth = $self->dbh->prepare("DESCRIBE $table");
    $sth->execute;
    while (my $rec = $sth->fetchrow_hashref) {
        if ($rec->{Field} eq $col) {
            $sth->finish;
            return $rec->{Type};
        }
    }
    return undef;
}

# --------------------------------------------------------------------------
# Test suite things we override
# --------------------------------------------------------------------------

sub new_temp {
    my $self = shift;
    my %args = @_;
    my $dbname = $args{dbname} || "tmp_mogiletest";
    my $host = $args{dbhost} || 'localhost';
    my $port = $args{dbport} || 3306;
    my $user = $args{dbuser} || 'root';
    my $pass = $args{dbpass} || '';
    my $rootuser = $args{dbrootuser} || $args{dbuser} || 'root';
    my $rootpass = $args{dbrootpass} || $args{dbpass} || '';
    my $sto =
    MogileFS::Store->new_from_dsn_user_pass("DBI:mysql:database=$dbname;host=$host;port=$port",
        $rootuser, $rootpass);

    my $dbh = $sto->dbh;
    _create_mysql_db($dbh, $dbname);

    # allow MyISAM in the test suite.
    $ENV{USE_UNSAFE_MYSQL} = 1 unless defined $ENV{USE_UNSAFE_MYSQL};

    my @args = ("$FindBin::Bin/../mogdbsetup", "--yes", 
        "--dbname=$dbname", "--type=MySQL",
        "--dbhost=$host", "--dbport=$port", 
        "--dbrootuser=$rootuser", 
        "--dbuser=$user", );
    push @args, "--dbpass=$pass" unless $pass eq ''; 
    push @args, "--dbrootpass=$rootpass" unless $rootpass eq '';
    system(@args) 
        and die "Failed to run mogdbsetup (".join(' ',map { "'".$_."'" } @args).").";

    if($user ne $rootuser) {
        $sto = MogileFS::Store->new_from_dsn_user_pass(
                "DBI:mysql:database=$dbname;host=$host;port=$port",
                $user, $pass);
        $dbh = $sto->dbh;
    }

    $dbh->do("use $dbname");
    return $sto;
}

sub _create_mysql_db {
    my $dbh    = shift;
    my $dbname = shift;
    _drop_mysql_db($dbh, $dbname);
    $dbh->do("CREATE DATABASE $dbname");
}

sub _drop_mysql_db {
    my $dbh    = shift;
    my $dbname = shift;
    $dbh->do("DROP DATABASE IF EXISTS $dbname");
}

# --------------------------------------------------------------------------
# Database creation time things we override
# --------------------------------------------------------------------------

sub create_table {
    my $self = shift;
    my ($table) = @_;

    my $dbh = $self->dbh;
    my $errmsg =
        "InnoDB backend is unavailable for use, force creation of tables " .
        "by setting USE_UNSAFE_MYSQL=1 in your environment and run this " .
        "command again.";

    unless ($ENV{USE_UNSAFE_MYSQL}) {
        my $engines = eval { $dbh->selectall_hashref("SHOW ENGINES", "Engine"); };
        if ($@ && $dbh->err == 1064) {
            # syntax error?  for MySQL 4.0.x.
            # who cares.  we'll catch it below on the double-check.
        } else {
            die $errmsg
                unless ($engines->{InnoDB} and
                        $engines->{InnoDB}->{Support} =~ m/^(YES|DEFAULT)$/i);
        }
    }

    my $existed = $self->table_exists($table);

    $self->SUPER::create_table(@_);
    return if $ENV{USE_UNSAFE_MYSQL};

    # don't alter an existing table up to InnoDB from MyISAM...
    # could be costly.  but on new tables, no problem...
    unless ($existed) {
        $dbh->do("ALTER TABLE $table ENGINE=InnoDB");
        warn "DBI reported an error of: '" . $dbh->errstr . "' when trying to " .
            "alter table type of $table to InnoDB\n" if $dbh->err;
    }

    # but in any case, let's see if it's already InnoDB or not.
    my $table_status = $dbh->selectrow_hashref("SHOW TABLE STATUS LIKE '$table'");

    # if not, either die or warn.
    unless (($table_status->{Engine} || $table_status->{Type} || "") eq "InnoDB") {
        if ($existed) {
            warn "WARNING: MySQL table that isn't InnoDB: $table\n";
        } else {
            die "MySQL didn't change table type to InnoDB as requested.\n\n$errmsg"
        }
    }

}

# --------------------------------------------------------------------------
# Data-access things we override
# --------------------------------------------------------------------------

# update the device count for a given fidid
sub update_devcount_atomic {
    my ($self, $fidid) = @_;
    my $lockname = "mgfs:fid:$fidid";

    my $lock = eval { $self->get_lock($lockname, 10) };

    # Check to make sure the lock didn't timeout, then we want to bail.
    return 0 if defined $lock && $lock == 0;

    # Checking $@ is pointless for the time because we just want to plow ahead
    # even if the get_lock trapped a recursion and threw a fatal error.

    $self->update_devcount($fidid);

    # Don't release the lock if we never got it.
    $self->release_lock($lockname) if $lock;
    return 1;
}

sub upgrade_add_host_getport {
    my $self = shift;
    # see if they have the get port, else update it
    unless ($self->column_type("host", "http_get_port")) {
        $self->dowell("ALTER TABLE host ADD COLUMN http_get_port MEDIUMINT UNSIGNED AFTER http_port");
    }

}
sub upgrade_add_host_altip {
    my $self = shift;
    unless ($self->column_type("host", "altip")) {
        $self->dowell("ALTER TABLE host ADD COLUMN altip VARCHAR(15) AFTER hostip");
        $self->dowell("ALTER TABLE host ADD COLUMN altmask VARCHAR(18) AFTER altip");
        $self->dowell("ALTER TABLE host ADD UNIQUE altip (altip)");
    }
}

sub upgrade_add_device_asof {
    my $self = shift;
    unless ($self->column_type("device", "mb_asof")) {
        $self->dowell("ALTER TABLE device ADD COLUMN mb_asof INT(10) UNSIGNED AFTER mb_used");
    }
}

sub upgrade_add_device_weight {
    my $self = shift;
    unless ($self->column_type("device", "weight")) {
        $self->dowell("ALTER TABLE device ADD COLUMN weight MEDIUMINT DEFAULT 100 AFTER status");
    }

}

sub upgrade_add_device_readonly {
    my $self = shift;
    unless ($self->column_type("device", "status") =~ /readonly/) {
        $self->dowell("ALTER TABLE device MODIFY COLUMN status ENUM('alive', 'dead', 'down', 'readonly')");
    }
}

sub upgrade_add_device_drain {
    my $self = shift;
    unless ($self->column_type("device", "status") =~ /drain/) {
        $self->dowell("ALTER TABLE device MODIFY COLUMN status ENUM('alive', 'dead', 'down', 'readonly', 'drain')");
    }
}

sub upgrade_modify_server_settings_value {
    my $self = shift;
    unless ($self->column_type("server_settings", "value") =~ /text/i) {
        $self->dowell("ALTER TABLE server_settings MODIFY COLUMN value TEXT");
    }
}

sub upgrade_add_file_to_queue_arg {
    my $self = shift;
    unless ($self->column_type("file_to_queue", "arg")) {
        $self->dowell("ALTER TABLE file_to_queue ADD COLUMN arg TEXT");
    }
}

sub upgrade_modify_device_size {
    my $self = shift;
    for my $col ('mb_total', 'mb_used') {
        if ($self->column_type("device", $col) =~ m/mediumint/i) {
            $self->dowell("ALTER TABLE device MODIFY COLUMN $col INT UNSIGNED");
        }
    }
}

sub upgrade_add_host_readonly {
    my $self = shift;
    unless ($self->column_type("host", "status") =~ /\breadonly\b/) {
        $self->dowell("ALTER TABLE host MODIFY COLUMN status ENUM('alive', 'dead', 'down', 'readonly')");
    }
}

sub pre_daemonize_checks {
    my $self = shift;
    # Jay Buffington, from the mailing lists, writes:

    # > > Is your DBI version at least 1.43? The Makefile.PL of DBD::mysql shows
    # > > that code for last_insert_it is compiled in only if DBD::mysql is built
    # > > with DBI 1.43 or newer.
    #> Yes, I have 1.53.
    #> jay@webdev:~$ perl -MDBI -le 'print $DBI::VERSION'
    #> 1.53
    #>
    #> BUT I just re-installed 2.9006 while researching this and my test
    #> script started working.  I just reran the mogile server test suite and
    #> all test passed!
    #>
    #> Problem solved!
    #>
    #> The original DBD::mysql 2.9006 was installed from a RPM.  I bet that
    #> it was built against a DBI older than 1.43, so it didn't support
    #> LAST_INSERT_ID.

    # So...
    #   since we don't know what version of DBI their DBD::mysql was built against,
    #   let's just test that last_insert_id works.

    my $id = eval {
        $self->register_tempfile(dmid => 99,
                                 key  => "_server_startup_test");
    };
    unless ($id) {
        die "MySQL self-tests failed.  Your DBD::mysql might've been built against an old DBI version.\n";
    }

    return $self->SUPER::pre_daemonize_checks();
}

sub get_keys_like_operator {
    my $bool = MogileFS::Config->server_setting_cached('case_sensitive_list_keys');
    return $bool ? "LIKE /*! BINARY */" : "LIKE";
}

sub update_device_usages {
    my ($self, $updates, $cb) = @_;
    $cb->();
    my $chunk = 10000; # in case we hit max_allowed_packet size(!)
    while (scalar @$updates) {
        my @cur = splice(@$updates, 0, $chunk);
        my @set;
        foreach my $fld (qw(mb_total mb_used mb_asof)) {
            my $s = "$fld = CASE devid\n";
            foreach my $upd (@cur) {
                my $devid = $upd->{devid};
                defined($devid) or croak("devid not set\n");
                my $val = $upd->{$fld};
                defined($val) or croak("$fld not defined for $devid\n");
                $s .= "WHEN $devid THEN $val\n";
            }
            $s .= "ELSE $fld END";
            push @set, $s;
        }
        my $sql = "UPDATE device SET ". join(",\n", @set);
        $self->dowell($sql);
        $cb->();
    }
}

1;

__END__

=head1 NAME

MogileFS::Store::MySQL - MySQL data storage for MogileFS

=head1 SEE ALSO

L<MogileFS::Store>



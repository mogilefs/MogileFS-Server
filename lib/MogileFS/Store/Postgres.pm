package MogileFS::Store::Postgres;
# vim: ts=4 sw=4 et ft=perl:
use strict;
use Digest::MD5 qw(md5); # Used for lockid
use DBI;
use DBD::Pg;
use Sys::Hostname;
use MogileFS::Util qw(throw debug error);
use MogileFS::Server;
use Carp;
use base 'MogileFS::Store';

# --------------------------------------------------------------------------
# Package methods we override
# --------------------------------------------------------------------------

sub dsn_of_dbhost {
    my ($class, $dbname, $host, $port) = @_;
    return "DBI:Pg:dbname=$dbname;host=$host" . ($port ? ";port=$port" : "");
}

sub dsn_of_root {
    my ($class, $dbname, $host, $port) = @_;
    return $class->dsn_of_dbhost('postgres', $host, $port);
}

# --------------------------------------------------------------------------
# Store-related things we override
# --------------------------------------------------------------------------

sub want_raise_errors { 1 }

# given a root DBI connection, create the named database.  succeed
# if it is made, or already exists.  die otherwise.
sub create_db_if_not_exists {
    my ($pkg, $rdbh, $dbname) = @_;
    if(not $rdbh->do("CREATE DATABASE $dbname TEMPLATE template0 ENCODING 'UTF-8'" )) {
        die "Failed to create database '$dbname': " . $rdbh->errstr . "\n" if ($rdbh->errstr !~ /already exists/);
    }
}

sub grant_privileges {
    my ($pkg, $rdbh, $dbname, $user, $pass) = @_;
    eval {
        $rdbh->do("CREATE ROLE $user LOGIN PASSWORD ?",
            undef, $pass);
    };
    die "Failed to create user '$user': ". $rdbh->errstr . "\n"
        if $rdbh->err && $rdbh->state != '42710';
    # Owning the database is postgres is important
    $rdbh->do("ALTER DATABASE $dbname OWNER TO $user")
        or die "Failed to grant privileges " . $rdbh->errstr . "\n";
}

sub can_replace { 0 }
sub can_insertignore { 0 }
sub can_insert_multi { 0 }
sub unix_timestamp { "EXTRACT(epoch FROM NOW())::int4" }

sub init {
    my $self = shift;
    $self->SUPER::init;
    my $database_version = $self->dbh->get_info(18); # SQL_DBMS_VER
    # We need >=pg-8.2 because we use SAVEPOINT and ROLLBACK TO.
    # We need >=pg-8.4 for working advisory locks
    die "Postgres is too old! Must use >=postgresql-8.4!" if($database_version =~ /\A0[0-7]\.|08\.0[0123]/);
    $self->{lock_depth} = 0;
}

sub post_dbi_connect {
    my $self = shift;
    $self->SUPER::post_dbi_connect;
    $self->{lock_depth} = 0;
}

sub can_do_slaves { 0 }

# TODO: Implement later
#sub check_slave {
#}

sub was_deadlock_error {
    my $self = shift;
    my $dbh = $self->dbh;
    return 0 unless $dbh->err;
    return 1 if $dbh->state eq '40P01';
}

sub was_duplicate_error {
    my $self = shift;
    my $dbh = $self->dbh;
    return 0 unless $dbh->err;
    return 1 if $dbh->state eq '23505' || $dbh->errstr =~ /duplicate/i;
}

sub table_exists {
    my ($self, $table) = @_;
    return eval {
        my $sth = $self->dbh->table_info(undef, undef, $table, "table");
        my $rec = $sth->fetchrow_hashref;
        return $rec ? 1 : 0;
    };
}

sub setup_database {
    my $self = shift;
    $self->add_extra_tables('lock');
    return $self->SUPER::setup_database;
}

sub filter_create_sql {
    my ($self, $sql) = @_;
    $sql =~ s/\bUNSIGNED\b//g;
    $sql =~ s/\bVARBINARY\(\d+\)/bytea/g;
    $sql =~ s/\b(?:TINY|MEDIUM)INT\b/SMALLINT/g;
    $sql =~ s/\bINT\s+NOT\s+NULL\s+AUTO_INCREMENT\b/SERIAL/g;
    $sql =~ s/# /-- /g;

    my ($table) = $sql =~ /create\s+table\s+(\S+)/i;
    die "didn't find table" unless $table;
    my $index = sprintf 'INDEXES_%s', $table;
    if ($self->can($index)) {
        $sql =~ s!,\s*INDEX\s*(\w+)?\s*\(.+?\)!!mgi;
    }

    # Allow 64-bit ids for file IDs
    $sql =~ s!\bfid\s+INT\b!fid BIGINT!i if $self->fid_type eq "BIGINT";

    return $sql;
}

sub TABLE_file {
    "CREATE TABLE file (
    fid          INT NOT NULL,
    PRIMARY KEY  (fid),

    dmid         SMALLINT NOT NULL,
    dkey         VARCHAR(255),      -- domain-defined
    UNIQUE       (dmid, dkey),

    length       BIGINT,            -- big limit
    CHECK        (length >= 0),

    classid      SMALLINT NOT NULL,
    devcount     SMALLINT NOT NULL
    )"
}

sub INDEXES_file {
    "CREATE INDEX file_devcount ON file (dmid,classid,devcount)"
}

sub INDEXES_unreachable_fids {
    "CREATE INDEX unreachable_fids_lastupdate ON unreachable_fids (lastupdate)"
}

sub INDEXES_file_on {
    "CREATE INDEX file_on_devid ON file_on (devid)"
}

sub TABLE_host {
    "CREATE TABLE host (
    hostid          SMALLINT NOT NULL,
    PRIMARY KEY     (hostid),
    CHECK           (hostid >= 0),

    status          VARCHAR(8),
    CHECK           (status IN ('alive','dead','down')),

    http_port       INT DEFAULT 7500,
    CHECK           (http_port >= 0),
    CHECK           (http_port < 65536),

    http_get_port   INT,
    CHECK           (http_get_port >= 0),
    CHECK           (http_get_port < 65536),

    hostname        VARCHAR(40),
    UNIQUE          (hostname),
    hostip          VARCHAR(15),
    UNIQUE          (hostip),
    altip           VARCHAR(15),
    UNIQUE          (altip),
    altmask         VARCHAR(18)
    )"
}

sub TABLE_device {
    "CREATE TABLE device (
    devid       SMALLINT NOT NULL,
    PRIMARY KEY (devid),
    CHECK       (devid >= 0),

    hostid      SMALLINT NOT NULL,

    status      VARCHAR(8),
    CHECK       (status IN ('alive','dead','down','readonly','drain')),
    weight      INT DEFAULT 100,

    mb_total    INT,
    CHECK       (mb_total >= 0),
    mb_used     INT,
    CHECK       (mb_used >= 0),
    mb_asof     INT
    CHECK       (mb_asof >= 0)
    )"
}

sub INDEXES_device {
    "CREATE INDEX device_status ON device (status)"
}

sub INDEXES_file_to_replicate {
    "CREATE INDEX file_to_replicate_nexttry ON file_to_replicate (nexttry)"
}

sub INDEXES_file_to_delete2 {
    "CREATE INDEX file_to_delete2_nexttry ON file_to_delete2 (nexttry)"
}

sub INDEXES_file_to_delete_later {
    "CREATE INDEX file_to_delete_later_delafter ON file_to_delete_later (delafter)"
}

sub INDEXES_fsck_log {
    "CREATE INDEX fsck_log_utime ON fsck_log (utime)"
}

sub INDEXES_file_to_queue {
    "CREATE INDEX type_nexttry ON file_to_queue (type,nexttry)"
}

# Extra table
sub TABLE_lock {
    "CREATE TABLE lock (
    lockid      INT NOT NULL,
    PRIMARY KEY (lockid),
    CHECK       (lockid >= 0),

    hostname    VARCHAR(255) NOT NULL,

    pid         INT NOT NULL,
    CHECK       (pid >= 0),

    acquiredat  INT NOT NULL,
    CHECK       (acquiredat >= 0)
    )"
}

sub upgrade_add_host_getport {
    my $self = shift;
    # see if they have the get port, else update it
    unless ($self->column_type("host", "http_get_port")) {
        $self->dowell("ALTER TABLE host ADD COLUMN http_get_port INT CHECK(http_get_port >= 0)");
    }

}
sub upgrade_add_host_altip {
    my $self = shift;
    unless ($self->column_type("host", "altip")) {
        $self->dowell("ALTER TABLE host ADD COLUMN altip VARCHAR(15)");
        $self->dowell("ALTER TABLE host ADD COLUMN altmask VARCHAR(18)");
        $self->dowell("ALTER TABLE host ADD UNIQUE altip (altip)");
    }
}

sub upgrade_add_device_asof {
    my $self = shift;
    unless ($self->column_type("device", "mb_asof")) {
        $self->dowell("ALTER TABLE device ADD COLUMN mb_asof INT CHECK(mb_asof >= 0)");
    }
}

sub upgrade_add_device_weight {
    my $self = shift;
    unless ($self->column_type("device", "weight")) {
        $self->dowell("ALTER TABLE device ADD COLUMN weight INT DEFAULT 100");
    }
}

sub upgrade_add_device_readonly {
    my $self = shift;
    unless ($self->column_constraint("device", "status") =~ /readonly/) {
        $self->dowell("ALTER TABLE device MODIFY COLUMN status VARCHAR(8) CHECK(status IN ('alive', 'dead', 'down', 'readonly'))");
    }
}

sub upgrade_add_device_drain {
    my $self = shift;
    unless ($self->column_constraint("device", "status") =~ /drain/) {
        $self->dowell("ALTER TABLE device MODIFY COLUMN status VARCHAR(8) CHECK(status IN ('alive', 'dead', 'down', 'readonly','drain'))");
    }
}

sub upgrade_add_host_readonly {
    my $self = shift;
    my $cn;
    unless ($self->column_constraint("host", "status", \$cn) =~ /\breadonly\b/) {
        $self->dbh->begin_work;
        $self->dowell("ALTER TABLE host DROP CONSTRAINT $cn");
        $self->dowell("ALTER TABLE host ADD CONSTRAINT status CHECK(".
                      "status IN ('alive', 'dead', 'down', 'readonly'))");
        $self->dbh->commit;
    }
}

sub upgrade_modify_server_settings_value {
    my $self = shift;
    unless ($self->column_type("server_settings", "value" =~ /text/i)) {
        $self->dowell("ALTER TABLE server_settings ALTER COLUMN value TYPE TEXT");
    }
}

sub upgrade_add_file_to_queue_arg {
    my $self = shift;
    unless ($self->column_type("file_to_queue", "arg")) {
        $self->dowell("ALTER TABLE file_to_queue ADD COLUMN arg TEXT");
    }
}

# Postgres doesn't have or never used a MEDIUMINT for device.
sub upgrade_modify_device_size {
    return 1;
}

sub upgrade_add_class_hashtype {
    my ($self) = @_;
    unless ($self->column_type("class", "hashtype")) {
        $self->dowell("ALTER TABLE class ADD COLUMN hashtype SMALLINT");
    }
}

# return 1 on success.  die otherwise.
sub enqueue_fids_to_delete {
    # My kingdom for a real INSERT IGNORE implementation!
    my ($self, @fidids) = @_;
    my $sql = "INSERT INTO file_to_delete (fid) VALUES (?)";

    foreach my $fidid (@fidids) {
        $self->dbh->begin_work;
        $self->condthrow;
        eval {
            $self->dbh->do($sql, undef, $fidid);
        };
        if ($@ || $self->dbh->err) {
            if ($self->was_duplicate_error) {
                # Do nothing
            } else {
                $self->condthrow;
            }
        }
        $self->dbh->commit;
    }

}

sub enqueue_fids_to_delete2 {
    # My kingdom for a real REPLACE implementation!
    my ($self, @fidids) = @_; 
    my $tbl = 'file_to_delete2';
    my $sql1 = sprintf "INSERT INTO %s (fid, nexttry) VALUES (?,%s)", $tbl, $self->unix_timestamp;
    my @dup_fids;
    
    foreach my $fidid (@fidids) {
        $self->dbh->begin_work;
        $self->condthrow;
        eval {
            $self->dbh->do($sql1, undef, $fidid);
        };
        if ($@ || $self->dbh->err) {
            if ($self->was_duplicate_error) {
                push @dup_fids, $fidid;
            } else {
                $self->condthrow;
            }
        }
        $self->dbh->commit;
    }

    my $sql2 = sprintf 'UPDATE %s SET nexttry = %s WHERE fid IN (?)', $tbl, $self->unix_timestamp;
    
    foreach my $fidid (@dup_fids) {
        $self->dbh->begin_work;
        $self->condthrow;
        eval {
            $self->dbh->do($sql2, undef, $fidid);
        };
        if ($@ || $self->dbh->err) {
            if ($self->was_duplicate_error) {
                # Ignore, no need of it
            } else {
                $self->condthrow;
            }
        }
        $self->dbh->commit;
    }

}

# --------------------------------------------------------------------------
# Functions specific to Store::Postgres subclass.  Not in parent.
# --------------------------------------------------------------------------

sub insert_or_ignore {
    my $self = shift;
    my %arg  = $self->_valid_params([qw(insert insert_vals)], @_);
    return $self->insert_or_update(
        insert => $arg{insert},
        insert_vals => $arg{insert_vals},
        update => 'IGNORE',
        update_vals => 'IGNORE',
    );
}

sub insert_or_update {
    my $self = shift;
    my %arg  = $self->_valid_params([qw(insert update insert_vals update_vals)], @_);
    my $dbh = $self->dbh;
    my $savepoint_name = $arg{insert};
    $savepoint_name =~ s/^INSERT INTO ([^\s]+).*$/$1/g;

    $dbh->begin_work;
    $dbh->do('SAVEPOINT '.$savepoint_name);
    eval {
        $dbh->do($arg{insert}, undef, @{ $arg{insert_vals} });
    };
    if ($@ || $dbh->err) {
        if ($self->was_duplicate_error) {
            $dbh->do('ROLLBACK TO '.$savepoint_name);
            if($arg{update} ne "IGNORE") {
                $dbh->do($arg{update}, undef, @{ $arg{update_vals} });
            }
        }
        $self->condthrow;
    }

    $dbh->commit;
    return 1;
}

sub column_type {
    my ($self, $table, $col) = @_;
    my $sth = $self->dbh->prepare("SELECT column_name,data_type FROM information_schema.columns WHERE table_name=? AND column_name=?");
    $sth->execute($table,$col);
    while (my $rec = $sth->fetchrow_hashref) {
        if ($rec->{column_name} eq $col) {
            $sth->finish;
            return $rec->{data_type};
        }
    }
    return undef;
}

sub column_constraint {
    my ($self, $table, $col, $cn) = @_;
    my $sth = $self->dbh->prepare("SELECT column_name,information_schema.check_constraints.check_clause,constraint_name FROM information_schema.constraint_column_usage JOIN information_schema.check_constraints USING(constraint_catalog,constraint_schema,constraint_name) WHERE table_name=? AND column_name=?");
    $sth->execute($table,$col);
    while (my $rec = $sth->fetchrow_hashref) {
        if ($rec->{column_name} eq $col) {
            $sth->finish;
            $$cn = $rec->{constraint_name} if $cn;
            return $rec->{check_clause};
        }
    }
    return undef;
}

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
    my $file_fid_type = $self->column_type("file", "fid");
    if($file_fid_type) {
        if ($file_fid_type =~ /bigint/i) {
            return $self->{_fid_type} = "BIGINT";
        } elsif($file_fid_type =~ /int/i) {
            # Old installs might not have raised the fid type size yet.
            return $self->{_fid_type} = "INT";
        }
    }

    # Used to default to 32bit ints, but this always bites people
    # a few years down the road. So default to 64bit.
    return $self->{_fid_type} = "BIGINT";
}

# --------------------------------------------------------------------------
# Test suite things we override
# --------------------------------------------------------------------------

sub new_temp {
    my $self = shift;
    my %args = @_;
    my $dbname = $args{dbname} || "tmp_mogiletest";
    my $host = $args{dbhost} || 'localhost';
    my $port = $args{dbport} || 5432;
    my $user = $args{dbuser} || 'mogile';
    my $pass = $args{dbpass} || '';
    my $rootuser = $args{dbrootuser} || $args{dbuser} || 'postgres';
    my $rootpass = $args{dbrootpass} || $args{dbpass} || '';
    _drop_db($dbname,$host,$port,$rootuser,$rootpass);
   
    my @args = ( "$FindBin::Bin/../mogdbsetup", "--yes", 
            "--dbname=$dbname", "--type=Postgres",
            "--dbhost=$host", "--dbport=$port",
            "--dbuser=$user", 
            "--dbrootuser=$rootuser", );
    push @args, "--dbpass=$pass" unless $pass eq ''; 
    push @args, "--dbrootpass=$rootpass" unless $rootpass eq '';
    system(@args) 
        and die "Failed to run mogdbsetup (".join(' ',map { "'".$_."'" } @args).").";

    return MogileFS::Store->new_from_dsn_user_pass("dbi:Pg:dbname=$dbname;host=$host;port=$port",
                                                   $user,
                                                   $pass);
}

my $rootdbh;
sub _root_dbh {
    my $host     = shift;
    my $port     = shift;
    my $rootuser = shift;
    my $rootpass = shift;
    return $rootdbh ||= DBI->connect("DBI:Pg:dbname=postgres;host=$host;port=$port", $rootuser, $rootpass, { RaiseError => 1 })
        or die "Couldn't connect to local PostgreSQL database as $rootuser";
}

sub _drop_db {
    my $dbname = shift;
    my $host     = shift;
    my $port     = shift;
    my $rootuser = shift;
    my $rootpass = shift;
    my $root_dbh = _root_dbh($host, $port, $rootuser, $rootpass);
    eval {
        $root_dbh->do("DROP DATABASE $dbname");
    };
}


# --------------------------------------------------------------------------
# Data-access things we override
# --------------------------------------------------------------------------

# returns 1 on success, 0 on duplicate key error, dies on exception
# TODO: need a test to hit the duplicate name error condition
sub rename_file {
    my ($self, $fidid, $to_key) = @_;
    my $dbh = $self->dbh;
    eval {
        $dbh->do('UPDATE file SET dkey = ? WHERE fid=?',
                 undef, $to_key, $fidid);
    };
    if ($@ || $dbh->err) {
        # first is error code for duplicates
        if ($self->was_duplicate_error) {
            return 0;
        } else {
            die $@;
        }
    }
    $self->condthrow;
    return 1;
}

# add a record of fidid existing on devid
# returns 1 on success, 0 on duplicate
sub add_fidid_to_devid {
    my ($self, $fidid, $devid) = @_;
    my $dbh = $self->dbh;
    eval {
        $dbh->do("INSERT INTO file_on (fid, devid) VALUES (?, ?)", undef, $fidid, $devid);
    };

    return 1 if !$@ && !$dbh->err;
    return 0;
}

# update the device count for a given fidid
sub update_devcount_atomic {
    my ($self, $fidid) = @_;
    my $rv;

    $self->dbh->begin_work;
    $rv = $self->dbh->do("SELECT devcount FROM file WHERE fid=? FOR UPDATE", undef, $fidid);
    $self->condthrow;
    if($rv == 0) {
        $self->dbh->rollback;
        return 1;
    }
    $rv = $self->dbh->do("UPDATE file SET devcount=(SELECT COUNT(devid) FROM file_on WHERE fid=?) WHERE fid=?", undef, $fidid, $fidid);
    $self->condthrow;
    $self->dbh->commit;
    $self->condthrow;
    return $rv;
}

# enqueue a fidid for replication, from a specific deviceid (can be undef), in a given number of seconds.
sub enqueue_for_replication {
    my ($self, $fidid, $from_devid, $in) = @_;
    my $dbh = $self->dbh;

    my $nexttry = 0;
    if ($in) {
        $nexttry = $self->unix_timestamp." + ${in}::int";
    }

    eval {
        $dbh->do("INSERT INTO file_to_replicate (fid, fromdevid, nexttry) VALUES (?, ?, $nexttry)",
                 undef, $fidid, $from_devid);
    };
}

# reschedule all deferred replication, return number rescheduled
sub replicate_now {
    my ($self) = @_;
    return $self->dbh->do("UPDATE file_to_replicate SET nexttry = ".$self->unix_timestamp." WHERE nexttry > ".$self->unix_timestamp);
}

sub reschedule_file_to_replicate_relative {
    my ($self, $fid, $in_n_secs) = @_;
    $self->dbh->do("UPDATE file_to_replicate SET nexttry = ".$self->unix_timestamp." + ?, failcount = failcount + 1 WHERE fid = ?",
                   undef, $in_n_secs, $fid);
}

# creates a new domain, given a domain namespace string.  return the dmid on success,
# throw 'dup' on duplicate name.
sub create_domain {
    my ($self, $name) = @_;
    my $dbh = $self->dbh;

    # get the max domain id
    my $maxid = $dbh->selectrow_array('SELECT MAX(dmid) FROM domain') || 0;
    my $rv = eval {
        $dbh->do('INSERT INTO domain (dmid, namespace) VALUES (?, ?)',
                 undef, $maxid + 1, $name);
    };
    if ($self->was_duplicate_error) {
        throw("dup");
    }
    return $maxid+1 if $rv;
    die "failed to make domain";  # FIXME: the above is racy.
}

sub set_server_setting {
    my ($self, $key, $val) = @_;
    my $dbh = $self->dbh;

    if (defined $val) {
        $self->insert_or_update(
            insert => "INSERT INTO server_settings (field, value) VALUES (?, ?)",
            insert_vals => [ $key, $val ],
            update => "UPDATE server_settings SET value = ? WHERE field = ?",
            update_vals => [ $val, $key ],
        );
    } else {
        $dbh->do("DELETE FROM server_settings WHERE field=?", undef, $key);
    }

    die "Error updating 'server_settings': " . $dbh->errstr if $dbh->err;
    return 1;
}

# This implementation is race-safe
sub incr_server_setting {
    my ($self, $key, $val) = @_;
    $val = 1 unless defined $val;
    return unless $val;

    $self->dbh->begin_work;
    my $value = $self->dbh->selectrow_array("SELECT value FROM server_settings WHERE field=? FOR UPDATE",undef,$key);
    if($value) {
        if($value =~ /^\d+$/) {
            $value += $val;
        } else {
            warning("Wanted to incr_server_setting by $val on field=$key but old value was $value. Setting instead.");
            $value = $val;
        }
        my $rv = $self->dbh->do("UPDATE server_settings ".
            "SET value=? ".
            "WHERE field=?", undef,
            $value, $key) > 0;
        $self->dbh->commit;
        return 1 if $rv;
    }
    $self->dbh->rollback; # Release the row-lock
    $self->set_server_setting($key, $val);
}

# return 1 on success, throw "dup" on duplicate devid or throws other error on failure
sub create_device {
    my ($self, $devid, $hostid, $status) = @_;
    my $rv = $self->conddup(sub {
        $self->dbh->do("INSERT INTO device (devid, hostid, status) VALUES (?, ?, ?)", undef,
                       $devid, $hostid, $status);
    });
    $self->condthrow;
    die "error making device $devid\n" unless $rv > 0;
    return 1;
}

sub replace_into_file {
    my $self = shift;
    my %arg  = $self->_valid_params([qw(fidid dmid key length classid devcount)], @_);
    $self->insert_or_update(
        insert => "INSERT INTO file (fid, dmid, dkey, length, classid, devcount) VALUES (?, ?, ?, ?, ?, ?)",
        insert_vals => [ @arg{'fidid', 'dmid', 'key', 'length', 'classid', 'devcount'} ],
        update => "UPDATE file SET dmid=?, dkey=?, length=?, classid=?, devcount=? WHERE fid=?",
        update_vals => [ @arg{'dmid', 'key', 'length', 'classid', 'devcount', 'fidid'} ],
    );
    $self->condthrow;
}

# given an array of MogileFS::DevFID objects, mass-insert them all
# into file_on (ignoring if they're already present)
sub mass_insert_file_on {
    my ($self, @devfids) = @_;
    my @qmarks = map { "(?,?)" } @devfids;
    my @binds  = map { $_->fidid, $_->devid } @devfids;

    my $sth = $self->dbh->prepare("INSERT INTO file_on (fid, devid) VALUES (?, ?)");
    foreach (@devfids) {
        eval {
            $sth->execute($_->fidid, $_->devid);
        };
        $self->condthrow unless $self->was_duplicate_error;
    }
    return 1;
}
sub lockid {
    my ($lockname) = @_;
    croak("Called with empty lockname! $lockname") unless (defined $lockname && length($lockname) > 0);
    my $num = unpack 'N',md5($lockname);
    return ($num & 0x7fffffff);
}

# attempt to grab a lock of lockname, and timeout after timeout seconds.
# the lock should be unique in the space of (lockid), as well the space of
# (hostname,pid).
# returns 1 on success and 0 on timeout
sub get_lock {
    my ($self, $lockname, $timeout) = @_;
    my $hostid = lockid(hostname);
    my $lockid = lockid($lockname);
    die sprintf("Lock recursion detected (grabbing %s on %s (%s/%s), had %s (%s). Bailing out.", $lockname, hostname, $hostid, $lockid, $self->{last_lock}, lockid($self->{last_lock})) if $self->{lock_depth};

    debug("$$ Locking $lockname ($lockid)\n") if $Mgd::DEBUG >= 5;

    my $lock = undef;
    while($timeout >= 0) {
        $lock = $self->dbh->selectrow_array("SELECT pg_try_advisory_lock(?, ?)", undef, $hostid, $lockid);
        $self->condthrow;
        if (defined $lock) {
            if($lock == 1) {
                $self->{lock_depth} = 1;
                $self->{last_lock}  = $lockname;
                last;
            } elsif($lock == 0) {
                sleep 1 if $timeout > 0;
                $timeout--;
                next;
            } else {
                die "Something went horribly wrong while getting lock $lockname - unknown return value";
            }
        } else {
            die "Something went horribly wrong while getting lock $lockname - undefined lock";
        }
    }
    return $lock;
}

# attempt to release a lock of lockname.
# returns 1 on success and 0 if no lock we have has that name.
sub release_lock {
    my ($self, $lockname) = @_;
    my $hostid = lockid(hostname);
    my $lockid = lockid($lockname);
    debug("$$ Unlocking $lockname ($lockid)\n") if $Mgd::DEBUG >= 5;
    my $rv = $self->dbh->selectrow_array("SELECT pg_advisory_unlock(?, ?)", undef, $hostid, $lockid);
    debug("Double-release of lock $lockname!") if $self->{lock_depth} != 0 and $rv == 0 and $Mgd::DEBUG >= 2;
    $self->condthrow;
    $self->{lock_depth} = 0;
    return $rv;
}

sub BLOB_BIND_TYPE { { pg_type => PG_BYTEA } }

sub set_checksum {
	my ($self, $fidid, $hashtype, $checksum) = @_;
    my $dbh = $self->dbh;

    $dbh->begin_work;
    eval {
        my $sth = $dbh->prepare("INSERT INTO checksum " .
                                "(fid, hashtype, checksum) ".
                                "VALUES (?, ?, ?)");
        $sth->bind_param(1, $fidid);
        $sth->bind_param(2, $hashtype);
        $sth->bind_param(3, $checksum, BLOB_BIND_TYPE);
        $sth->execute;
    };
    if ($@ || $dbh->err) {
        if ($self->was_duplicate_error) {
            eval {
                my $sth = $dbh->prepare("UPDATE checksum " .
                                        "SET hashtype = ?, checksum = ? " .
                                        "WHERE fid = ?");
                $sth->bind_param(1, $hashtype);
                $sth->bind_param(2, $checksum, BLOB_BIND_TYPE);
                $sth->bind_param(3, $fidid);
                $sth->execute;
            };
            $self->condthrow;
        }
    }
    $dbh->commit;
    $self->condthrow;
}

1;

__END__

=head1 NAME

MogileFS::Store::Postgres - PostgreSQL data storage for MogileFS

=head1 SEE ALSO

L<MogileFS::Store>



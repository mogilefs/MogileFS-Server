package MogileFS::Store;
use strict;
use warnings;
use Carp qw(croak confess);
use MogileFS::Util qw(throw max error);
use DBI;  # no reason a Store has to be DBI-based, but for now they all are.
use List::Util qw(shuffle);

# this is incremented whenever the schema changes.  server will refuse
# to start-up with an old schema version
#
# 6: adds file_to_replicate table
# 7: adds file_to_delete_later table
# 8: adds fsck_log table
# 9: adds 'drain' state to enum in device table
# 10: adds 'replpolicy' column to 'class' table
# 11: adds 'file_to_queue' table
# 12: adds 'file_to_delete2' table
# 13: modifies 'server_settings.value' to TEXT for wider values
#     also adds a TEXT 'arg' column to file_to_queue for passing arguments
# 14: modifies 'device' mb_total, mb_used to INT for devs > 16TB
# 15: adds checksum table, adds 'hashtype' column to 'class' table
use constant SCHEMA_VERSION => 15;

sub new {
    my ($class) = @_;
    return $class->new_from_dsn_user_pass(map { MogileFS->config($_) } qw(db_dsn db_user db_pass max_handles));
}

sub new_from_dsn_user_pass {
    my ($class, $dsn, $user, $pass, $max_handles) = @_;
    my $subclass;
    if ($dsn =~ /^DBI:mysql:/i) {
        $subclass = "MogileFS::Store::MySQL";
    } elsif ($dsn =~ /^DBI:SQLite:/i) {
        $subclass = "MogileFS::Store::SQLite";
    } elsif ($dsn =~ /^DBI:Oracle:/i) {
        $subclass = "MogileFS::Store::Oracle";
    } elsif ($dsn =~ /^DBI:Pg:/i) {
        $subclass = "MogileFS::Store::Postgres";
    } else {
        die "Unknown database type: $dsn";
    }
    unless (eval "use $subclass; 1") {
        die "Error loading $subclass: $@\n";
    }
    my $self = bless {
        dsn    => $dsn,
        user   => $user,
        pass   => $pass,
        max_handles => $max_handles, # Max number of handles to allow
        raise_errors => $subclass->want_raise_errors,
        slave_list_version => 0,
        slave_list_cache     => [],
        recheck_req_gen  => 0,  # incremented generation, of recheck of dbh being requested
        recheck_done_gen => 0,  # once recheck is done, copy of what the request generation was
        handles_left     => 0,  # amount of times this handle can still be verified
        connected_slaves => {},
        dead_slaves      => {},
        dead_backoff     => {}, # how many times in a row a slave has died
        connect_timeout  => 10, # High default.
    }, $subclass;
    $self->init;
    return $self;
}

# Defaults to true now.
sub want_raise_errors {
    1;
}

sub new_from_mogdbsetup {
    my ($class, %args) = @_;
    # where args is:  dbhost dbport dbname dbrootuser dbrootpass dbuser dbpass
    my $dsn = $class->dsn_of_dbhost($args{dbname}, $args{dbhost}, $args{dbport});

    my $try_make_sto = sub {
        my $dbh = DBI->connect($dsn, $args{dbuser}, $args{dbpass}, {
            PrintError => 0,
        }) or return undef;
        my $sto = $class->new_from_dsn_user_pass($dsn, $args{dbuser}, $args{dbpass});
        $sto->raise_errors;
        return $sto;
    };

    # upgrading, apparently, as this database already exists.
    my $sto = $try_make_sto->();
    return $sto if $sto;

    # otherwise, we need to make the requested database, setup permissions, etc
    $class->status("couldn't connect to database as mogilefs user.  trying root...");
    my $rootdsn = $class->dsn_of_root($args{dbname}, $args{dbhost}, $args{dbport});
    my $rdbh = DBI->connect($rootdsn, $args{dbrootuser}, $args{dbrootpass}, {
        PrintError => 0,
    }) or
        die "Failed to connect to $rootdsn as specified root user ($args{dbrootuser}): " . DBI->errstr . "\n";
    $class->status("connected to database as root user.");

    $class->confirm("Create/Upgrade database name '$args{dbname}'?");
    $class->create_db_if_not_exists($rdbh, $args{dbname});
    $class->confirm("Grant all privileges to user '$args{dbuser}', connecting from anywhere, to the mogilefs database '$args{dbname}'?");
    $class->grant_privileges($rdbh, $args{dbname}, $args{dbuser}, $args{dbpass});

    # should be ready now:
    $sto = $try_make_sto->();
    return $sto if $sto;

    die "Failed to connect to database as regular user, even after creating it and setting up permissions as the root user.";
}

# given a root DBI connection, create the named database.  succeed
# if it it's made, or already exists.  die otherwise.
sub create_db_if_not_exists {
    my ($pkg, $rdbh, $dbname) = @_;
    $rdbh->do("CREATE DATABASE IF NOT EXISTS $dbname")
        or die "Failed to create database '$dbname': " . $rdbh->errstr . "\n";
}

sub grant_privileges {
    my ($pkg, $rdbh, $dbname, $user, $pass) = @_;
    $rdbh->do("GRANT ALL PRIVILEGES ON $dbname.* TO $user\@'\%' IDENTIFIED BY ?",
             undef, $pass)
        or die "Failed to grant privileges: " . $rdbh->errstr . "\n";
    $rdbh->do("GRANT ALL PRIVILEGES ON $dbname.* TO $user\@'localhost' IDENTIFIED BY ?",
             undef, $pass)
        or die "Failed to grant privileges: " . $rdbh->errstr . "\n";
}

sub can_replace      { 0 }
sub can_insertignore { 0 }
sub can_insert_multi { 0 }
sub can_for_update   { 1 }

sub unix_timestamp { die "No function in $_[0] to return DB's unixtime." }

sub ignore_replace {
    my $self = shift;
    return "INSERT IGNORE " if $self->can_insertignore;
    return "REPLACE " if $self->can_replace;
    die "Can't INSERT IGNORE or REPLACE?";
}

my $on_status = sub {};
my $on_confirm = sub { 1 };
sub on_status  { my ($pkg, $code) = @_; $on_status  = $code; };
sub on_confirm { my ($pkg, $code) = @_; $on_confirm = $code; };
sub status     { my ($pkg, $msg)  = @_; $on_status->($msg);  };
sub confirm    { my ($pkg, $msg)  = @_; $on_confirm->($msg) or die "Aborted.\n"; };

sub latest_schema_version { SCHEMA_VERSION }

sub raise_errors {
    my $self = shift;
    $self->{raise_errors} = 1;
    $self->dbh->{RaiseError} = 1;
}

sub set_connect_timeout { $_[0]{connect_timeout} = $_[1]; }

sub dsn  { $_[0]{dsn}  }
sub user { $_[0]{user} }
sub pass { $_[0]{pass} }

sub connect_timeout { $_[0]{connect_timeout} }

sub init { 1 }
sub post_dbi_connect { 1 }

sub can_do_slaves { 0 }

sub mark_as_slave {
    my $self = shift;
    die "Incapable of becoming slave." unless $self->can_do_slaves;

    $self->{is_slave} = 1;
}

sub is_slave {
    my $self = shift;
    return $self->{is_slave};
}

sub _slaves_list_changed {
    my $self = shift;
    my $ver = MogileFS::Config->server_setting_cached('slave_version') || 0;
    if ($ver <= $self->{slave_list_version}) {
        return 0;
    }
    $self->{slave_list_version} = $ver;
    # Restart connections from scratch if the configuration changed.
    $self->{connected_slaves} = {};
    return 1;
}

# Returns a list of arrayrefs, each being [$dsn, $username, $password] for connecting to a slave DB.
sub _slaves_list {
    my $self = shift;
    my $now = time();

    my $sk = MogileFS::Config->server_setting_cached('slave_keys')
        or return ();

    my @ret;
    foreach my $key (split /\s*,\s*/, $sk) {
        my $slave = MogileFS::Config->server_setting_cached("slave_$key");

        if (!$slave) {
            error("key for slave DB config: slave_$key not found in configuration");
            next;
        }

        my ($dsn, $user, $pass) = split /\|/, $slave;
        if (!defined($dsn) or !defined($user) or !defined($pass)) {
            error("key slave_$key contains $slave, which doesn't split in | into DSN|user|pass - ignoring");
            next;
        }
        push @ret, [$dsn, $user, $pass]
    }

    return @ret;
}

sub _pick_slave {
    my $self = shift;
    my @temp = shuffle keys %{$self->{connected_slaves}};
    return unless @temp;
    return $self->{connected_slaves}->{$temp[0]};
}

sub _connect_slave {
    my $self = shift;
    my $slave_fulldsn = shift;
    my $now = time();

    my $dead_retry =
        MogileFS::Config->server_setting_cached('slave_dead_retry_timeout') || 15;

    my $dead_backoff = $self->{dead_backoff}->{$slave_fulldsn->[0]} || 0;
    my $dead_timeout = $self->{dead_slaves}->{$slave_fulldsn->[0]};
    return if (defined $dead_timeout
        && $dead_timeout + ($dead_retry * $dead_backoff) > $now);
    return if ($self->{connected_slaves}->{$slave_fulldsn->[0]});

    my $newslave = $self->{slave} = $self->new_from_dsn_user_pass(@$slave_fulldsn);
    $newslave->set_connect_timeout(
        MogileFS::Config->server_setting_cached('slave_connect_timeout') || 1);
    $self->{slave}->{next_check} = 0;
    $newslave->mark_as_slave;
    if ($self->check_slave) {
        $self->{connected_slaves}->{$slave_fulldsn->[0]} = $newslave;
        $self->{dead_backoff}->{$slave_fulldsn->[0]} = 0;
    } else {
        # Magic numbers are saddening...
        $dead_backoff++ unless $dead_backoff > 20;
        $self->{dead_slaves}->{$slave_fulldsn->[0]} = $now;
        $self->{dead_backoff}->{$slave_fulldsn->[0]} = $dead_backoff;
    }
}

sub get_slave {
    my $self = shift;

    die "Incapable of having slaves." unless $self->can_do_slaves;

    $self->{slave} = undef;
    foreach my $slave (keys %{$self->{dead_slaves}}) {
        my ($full_dsn) = grep { $slave eq $_->[0] } @{$self->{slave_list_cache}};
        unless ($full_dsn) {
            delete $self->{dead_slaves}->{$slave};
            next;
        }
        $self->_connect_slave($full_dsn);
    }

    unless ($self->_slaves_list_changed) {
        if ($self->{slave} = $self->_pick_slave) {
            $self->{slave}->{recheck_req_gen} = $self->{recheck_req_gen};
            return $self->{slave} if $self->check_slave;
        }
    }

    if ($self->{slave}) {
        my $dsn = $self->{slave}->{dsn};
        $self->{dead_slaves}->{$dsn} = time();
        $self->{dead_backoff}->{$dsn} = 0;
        delete $self->{connected_slaves}->{$dsn};
        error("Error talking to slave: $dsn");
    }
    my @slaves_list = $self->_slaves_list;

    # If we have no slaves, then return silently.
    return unless @slaves_list;

    my $slave_skip_filtering = MogileFS::Config->server_setting_cached('slave_skip_filtering');

    unless (defined $slave_skip_filtering && $slave_skip_filtering eq 'on') {
        MogileFS::run_global_hook('slave_list_filter', \@slaves_list);
    }

    $self->{slave_list_cache} = \@slaves_list;

    foreach my $slave_fulldsn (@slaves_list) {
        $self->_connect_slave($slave_fulldsn);
    }

    if ($self->{slave} = $self->_pick_slave) {
        return $self->{slave};
    }
    warn "Slave list exhausted, failing back to master.";
    return;
}

sub read_store {
    my $self = shift;

    return $self unless $self->can_do_slaves;

    if ($self->{slave_ok}) {
        if (my $slave = $self->get_slave) {
            return $slave;
        }
    }

    return $self;
}

sub slaves_ok {
    my $self = shift;
    my $coderef = shift;

    return unless ref $coderef eq 'CODE';

    local $self->{slave_ok} = 1;

    return $coderef->(@_);
}

sub recheck_dbh {
    my $self = shift;
    $self->{recheck_req_gen}++;
}

sub dbh {
    my $self = shift;
    
    if ($self->{dbh}) {
        if ($self->{recheck_done_gen} != $self->{recheck_req_gen}) {
            $self->{dbh} = undef unless $self->{dbh}->ping;
            # Handles a memory leak under Solaris/Postgres.
            # We may leak a little extra memory if we're holding a lock,
            # since dropping a connection mid-lock is fatal
            $self->{dbh} = undef if ($self->{max_handles} &&
                $self->{handles_left}-- < 0 && !$self->{lock_depth});
            $self->{recheck_done_gen} = $self->{recheck_req_gen};
        }
        return $self->{dbh} if $self->{dbh};
    }

    # Shortcut flag: if monitor thinks the master is down, avoid attempting to
    # connect to it for now. If we already have a connection to the master,
    # keep using it as above.
    if (!$self->is_slave) {
        my $flag = MogileFS::Config->server_setting_cached('_master_db_alive', 0);
        return if (defined $flag && $flag == 0);;
    }

    # auto-reconnect is unsafe if we're holding a lock
    if ($self->{lock_depth}) {
        die "DB connection recovery unsafe, lock held: $self->{last_lock}";
    }

    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm($self->connect_timeout);
        $self->{dbh} = DBI->connect($self->{dsn}, $self->{user}, $self->{pass}, {
            PrintError => 0,
            AutoCommit => 1,
            # FUTURE: will default to on (have to validate all callers first):
            RaiseError => ($self->{raise_errors} || 0),
            sqlite_use_immediate_transaction => 1,
        });
    };
    alarm(0);
    if ($@ eq "timeout\n") {
        die "Failed to connect to database: timeout";
    } elsif ($@) {
        die "Failed to connect to database: " . DBI->errstr;
    }
    $self->post_dbi_connect;
    $self->{handles_left} = $self->{max_handles} if $self->{max_handles};
    return $self->{dbh};
}

sub have_dbh { return 1 if $_[0]->{dbh}; } 

sub ping {
    my $self = shift;
    return $self->dbh->ping;
}

sub condthrow {
    my ($self, $optmsg) = @_;
    my $dbh = $self->dbh;
    return 1 unless $dbh->err;
    my ($pkg, $fn, $line) = caller;
    my $msg = "Database error from $pkg/$fn/$line: " . $dbh->errstr;
    $msg .= ": $optmsg" if $optmsg;
    # Auto rollback failures around transactions.
    if ($dbh->{AutoCommit} == 0) { eval { $dbh->rollback }; }
    croak($msg);
}

sub dowell {
    my ($self, $sql, @do_params) = @_;
    my $rv = eval { $self->dbh->do($sql, @do_params) };
    return $rv unless $@ || $self->dbh->err;
    warn "Error with SQL: $sql\n";
    Carp::confess($@ || $self->dbh->errstr);
}

sub _valid_params {
    croak("Odd number of parameters!") if scalar(@_) % 2;
    my ($self, $vlist, %uarg) = @_;
    my %ret;
    $ret{$_} = delete $uarg{$_} foreach @$vlist;
    croak("Bogus options: ".join(',',keys %uarg)) if %uarg;
    return %ret;
}

sub was_deadlock_error {
    my $self = shift;
    my $dbh = $self->dbh;
    die "UNIMPLEMENTED";
}

sub was_duplicate_error {
    my $self = shift;
    my $dbh = $self->dbh;
    die "UNIMPLEMENTED";
}

# run a subref (presumably a database update) in an eval, because you expect it to
# maybe fail on duplicate key error, and throw a dup exception for you, else return
# its return value
sub conddup {
    my ($self, $code) = @_;
    my $rv = eval { $code->(); };
    throw("dup") if $self->was_duplicate_error;
    croak($@) if $@;
    return $rv;
}

# insert row if doesn't already exist
# WARNING: This function is NOT transaction safe if the duplicate errors causes
# your transaction to halt!
# WARNING: This function is NOT safe on multi-row inserts if can_insertignore
# is false! Rows before the duplicate will be inserted, but rows after the
# duplicate might not be, depending your database.
sub insert_ignore {
    my ($self, $sql, @params) = @_;
    my $dbh = $self->dbh;
    if ($self->can_insertignore) {
        return $dbh->do("INSERT IGNORE $sql", @params);
    } else {
        # TODO: Detect bad multi-row insert here.
        my $rv = eval { $dbh->do("INSERT $sql", @params); };
        if ($@ || $dbh->err) {
            return 1 if $self->was_duplicate_error;
            # This chunk is identical to condthrow, but we include it directly
            # here as we know there is definitely an error, and we would like
            # the caller of this function.
            my ($pkg, $fn, $line) = caller;
            my $msg = "Database error from $pkg/$fn/$line: " . $dbh->errstr;
            croak($msg);
        }
        return $rv;
    }
}

sub retry_on_deadlock {
    my $self  = shift;
    my $code  = shift;
    my $tries = shift || 3;
    croak("deadlock retries must be positive") if $tries < 1;
    my $rv;

    while ($tries-- > 0) {
        $rv = eval { $code->(); };
        next if ($self->was_deadlock_error);
        croak($@) if $@;
        last;
    }
    return $rv;
}

# --------------------------------------------------------------------------

my @extra_tables;

sub add_extra_tables {
    my $class = shift;
    push @extra_tables, @_;
}

use constant TABLES => qw( domain class file tempfile file_to_delete
                            unreachable_fids file_on file_on_corrupt host
                            device server_settings file_to_replicate
                            file_to_delete_later fsck_log file_to_queue
                            file_to_delete2 checksum);

sub setup_database {
    my $sto = shift;

    my $curver = $sto->schema_version;

    my $latestver = SCHEMA_VERSION;
    if ($curver == $latestver) {
        $sto->status("Schema already up-to-date at version $curver.");
        return 1;
    }

    if ($curver > $latestver) {
        die "Your current schema version is $curver, but this version of mogdbsetup only knows up to $latestver.  Aborting to be safe.\n";
    }

    if ($curver) {
        $sto->confirm("Install/upgrade your schema from version $curver to version $latestver?");
    }

    foreach my $t (TABLES, @extra_tables) {
        $sto->create_table($t);
    }

    $sto->upgrade_add_host_getport;
    $sto->upgrade_add_host_altip;
    $sto->upgrade_add_device_asof;
    $sto->upgrade_add_device_weight;
    $sto->upgrade_add_device_readonly;
    $sto->upgrade_add_device_drain;
    $sto->upgrade_add_class_replpolicy;
    $sto->upgrade_modify_server_settings_value;
    $sto->upgrade_add_file_to_queue_arg;
    $sto->upgrade_modify_device_size;
    $sto->upgrade_add_class_hashtype;

    return 1;
}

sub cached_schema_version {
    my $self = shift;
    return $self->{_cached_schema_version} ||=
        $self->schema_version;
}

sub schema_version {
    my $self = shift;
    my $dbh = $self->dbh;
    return eval {
        $dbh->selectrow_array("SELECT value FROM server_settings WHERE field='schema_version'") || 0;
    } || 0;
}

sub filter_create_sql { my ($self, $sql) = @_; return $sql; }

sub create_table {
    my ($self, $table) = @_;
    my $dbh = $self->dbh;
    return 1 if $self->table_exists($table);
    my $meth = "TABLE_$table";
    my $sql = $self->$meth;
    $sql = $self->filter_create_sql($sql);
    $self->status("Running SQL: $sql;");
    $dbh->do($sql) or
        die "Failed to create table $table: " . $dbh->errstr;
    my $imeth = "INDEXES_$table";
    my @indexes = eval { $self->$imeth };
    foreach $sql (@indexes) {
        $self->status("Running SQL: $sql;");
        $dbh->do($sql) or
            die "Failed to create indexes on $table: " . $dbh->errstr;
    }
}

# Please try to keep all tables aligned nicely
# with '"CREATE TABLE' on the first line
# and ')"' alone on the last line.

sub TABLE_domain {
    # classes are tied to domains.  domains can have classes of items
    # with different mindevcounts.
    #
    # a minimum devcount is the number of copies the system tries to
    # maintain for files in that class
    #
    # unspecified classname means classid=0 (implicit class), and that
    # implies mindevcount=2
    "CREATE TABLE domain (
    dmid         SMALLINT UNSIGNED NOT NULL PRIMARY KEY,
    namespace    VARCHAR(255),
    UNIQUE (namespace)
    )"
}

sub TABLE_class {
    "CREATE TABLE class (
    dmid          SMALLINT UNSIGNED NOT NULL,
    classid       TINYINT UNSIGNED NOT NULL,
    PRIMARY KEY (dmid,classid),
    classname     VARCHAR(50),
    UNIQUE      (dmid,classname),
    mindevcount   TINYINT UNSIGNED NOT NULL,
    hashtype  TINYINT UNSIGNED
    )"
}

# the length field is only here for easy verifications of content
# integrity when copying around.  no sums or content types or other
# metadata here.  application can handle that.
#
# classid is what class of file this belongs to.  for instance, on fotobilder
# there will be a class for original pictures (the ones the user uploaded)
# and a class for derived images (scaled down versions, thumbnails, greyscale, etc)
# each domain can setup classes and assign the minimum redundancy level for
# each class.  fotobilder will use a 2 or 3 minimum copy redundancy for original
# photos and and a 1 minimum for derived images (which means the sole device
# for a derived image can die, bringing devcount to 0 for that file, but
# the application can recreate it from its original)
sub TABLE_file {
    "CREATE TABLE file (
    fid          INT UNSIGNED NOT NULL,
    PRIMARY KEY  (fid),

    dmid          SMALLINT UNSIGNED NOT NULL,
    dkey           VARCHAR(255),     # domain-defined
    UNIQUE dkey  (dmid, dkey),

    length        BIGINT UNSIGNED,   # big limit

    classid       TINYINT UNSIGNED NOT NULL,
    devcount      TINYINT UNSIGNED NOT NULL,
    INDEX devcount (dmid,classid,devcount)
    )"
}

sub TABLE_tempfile {
    "CREATE TABLE tempfile (
    fid          INT UNSIGNED NOT NULL AUTO_INCREMENT,
    PRIMARY KEY  (fid),

    createtime   INT UNSIGNED NOT NULL,
    classid      TINYINT UNSIGNED NOT NULL,
    dmid          SMALLINT UNSIGNED NOT NULL,
    dkey           VARCHAR(255),
    devids       VARCHAR(60)
    )"
}

# files marked for death when their key is overwritten.  then they get a new
# fid, but since the old row (with the old fid) had to be deleted immediately,
# we need a place to store the fid so an async job can delete the file from
# all devices.
sub TABLE_file_to_delete {
    "CREATE TABLE file_to_delete (
    fid  INT UNSIGNED NOT NULL,
    PRIMARY KEY (fid)
    )"
}

# if the replicator notices that a fid has no sources, that file gets inserted
# into the unreachable_fids table.  it is up to the application to actually
# handle fids stored in this table.
sub TABLE_unreachable_fids {
    "CREATE TABLE unreachable_fids (
    fid        INT UNSIGNED NOT NULL,
    lastupdate INT UNSIGNED NOT NULL,
    PRIMARY KEY (fid),
    INDEX (lastupdate)
    )"
}

# what files are on what devices?  (most likely physical devices,
# as logical devices of RAID arrays would be costly, and mogilefs
# already handles redundancy)
#
# the devid index lets us answer "What files were on this now-dead disk?"
sub TABLE_file_on {
    "CREATE TABLE file_on (
    fid          INT UNSIGNED NOT NULL,
    devid        MEDIUMINT UNSIGNED NOT NULL,
    PRIMARY KEY (fid, devid),
    INDEX (devid)
    )"
}

# if application or framework detects an error in one of the duplicate files
# for whatever reason, it can register its complaint and the framework
# will do some verifications and fix things up w/ an async job
# MAYBE: let application tell us the SHA1/MD5 of the file for us to check
#        on the other devices?
sub TABLE_file_on_corrupt {
    "CREATE TABLE file_on_corrupt (
    fid          INT UNSIGNED NOT NULL,
    devid        MEDIUMINT UNSIGNED NOT NULL,
    PRIMARY KEY (fid, devid)
    )"
}

# hosts (which contain devices...)
sub TABLE_host {
    "CREATE TABLE host (
    hostid     MEDIUMINT UNSIGNED NOT NULL PRIMARY KEY,

    status     ENUM('alive','dead','down'),
    http_port  MEDIUMINT UNSIGNED DEFAULT 7500,
    http_get_port MEDIUMINT UNSIGNED,

    hostname   VARCHAR(40),
    hostip     VARCHAR(15),
    altip      VARCHAR(15),
    altmask    VARCHAR(18),
    UNIQUE     (hostname),
    UNIQUE     (hostip),
    UNIQUE     (altip)
    )"
}

# disks...
sub TABLE_device {
    "CREATE TABLE device (
    devid   MEDIUMINT UNSIGNED NOT NULL,
    hostid     MEDIUMINT UNSIGNED NOT NULL,

    status  ENUM('alive','dead','down'),
    weight  MEDIUMINT DEFAULT 100,

    mb_total   INT UNSIGNED,
    mb_used    INT UNSIGNED,
    mb_asof    INT UNSIGNED,
    PRIMARY KEY (devid),
    INDEX   (status)
    )"
}

sub TABLE_server_settings {
    "CREATE TABLE server_settings (
    field   VARCHAR(50) PRIMARY KEY,
    value   TEXT
    )"
}

sub TABLE_file_to_replicate {
    # nexttry is time to try to replicate it next.
    #   0 means immediate.  it's only on one host.
    #   1 means lower priority.  it's on 2+ but isn't happy where it's at.
    #   unix timestamp means at/after that time.  some previous error occurred.
    # fromdevid, if not null, means which devid we should replicate from.  perhaps it's the only non-corrupt one.  otherwise, wherever.
    # failcount.  how many times we've failed, just for doing backoff of nexttry.
    # flags.  reserved for future use.
    "CREATE TABLE file_to_replicate (
    fid        INT UNSIGNED NOT NULL PRIMARY KEY,
    nexttry    INT UNSIGNED NOT NULL,
    INDEX (nexttry),
    fromdevid  INT UNSIGNED,
    failcount  TINYINT UNSIGNED NOT NULL DEFAULT 0,
    flags      SMALLINT UNSIGNED NOT NULL DEFAULT 0
    )"
}

sub TABLE_file_to_delete_later {
    "CREATE TABLE file_to_delete_later (
    fid  INT UNSIGNED NOT NULL PRIMARY KEY,
    delafter INT UNSIGNED NOT NULL,
    INDEX (delafter)
    )"
}

sub TABLE_fsck_log {
    "CREATE TABLE fsck_log (
    logid  INT UNSIGNED NOT NULL AUTO_INCREMENT,
    PRIMARY KEY (logid),
    utime  INT UNSIGNED NOT NULL,
    fid    INT UNSIGNED NULL,
    evcode CHAR(4),
    devid  MEDIUMINT UNSIGNED,
    INDEX(utime)
    )"
}

# generic queue table, designed to be used for workers/jobs which aren't
# constantly in use, and are async to the user.
# ie; fsck, drain, rebalance.
sub TABLE_file_to_queue {
    "CREATE TABLE file_to_queue (
    fid       INT UNSIGNED NOT NULL,
    devid     INT UNSIGNED,
    type      TINYINT UNSIGNED NOT NULL,
    nexttry   INT UNSIGNED NOT NULL,
    failcount TINYINT UNSIGNED NOT NULL default '0',
    flags     SMALLINT UNSIGNED NOT NULL default '0',
    arg       TEXT,
    PRIMARY KEY (fid, type),
    INDEX type_nexttry (type,nexttry)
    )"
}

# new style async delete table.
# this is separate from file_to_queue since deletes are more actively used,
# and partitioning on 'type' doesn't always work so well.
sub TABLE_file_to_delete2 {
    "CREATE TABLE file_to_delete2 (
    fid INT UNSIGNED NOT NULL PRIMARY KEY,
    nexttry INT UNSIGNED NOT NULL,
    failcount TINYINT UNSIGNED NOT NULL default '0',
    INDEX nexttry (nexttry)
    )"
}

sub TABLE_checksum {
    "CREATE TABLE checksum (
    fid INT UNSIGNED NOT NULL PRIMARY KEY,
    hashtype TINYINT UNSIGNED NOT NULL,
    checksum VARBINARY(64) NOT NULL
    )"
}

# these five only necessary for MySQL, since no other database existed
# before, so they can just create the tables correctly to begin with.
# in the future, there might be new alters that non-MySQL databases
# will have to implement.
sub upgrade_add_host_getport { 1 }
sub upgrade_add_host_altip { 1 }
sub upgrade_add_device_asof { 1 }
sub upgrade_add_device_weight { 1 }
sub upgrade_add_device_readonly { 1 }
sub upgrade_add_device_drain { die "Not implemented in $_[0]" }
sub upgrade_modify_server_settings_value { die "Not implemented in $_[0]" }
sub upgrade_add_file_to_queue_arg { die "Not implemented in $_[0]" }
sub upgrade_modify_device_size { die "Not implemented in $_[0]" }

sub upgrade_add_class_replpolicy {
    my ($self) = @_;
    unless ($self->column_type("class", "replpolicy")) {
        $self->dowell("ALTER TABLE class ADD COLUMN replpolicy VARCHAR(255)");
    }
}

sub upgrade_add_class_hashtype {
    my ($self) = @_;
    unless ($self->column_type("class", "hashtype")) {
        $self->dowell("ALTER TABLE class ADD COLUMN hashtype TINYINT UNSIGNED");
    }
}

# return true if deleted, 0 if didn't exist, exception if error
sub delete_host {
    my ($self, $hostid) = @_;
    return $self->dbh->do("DELETE FROM host WHERE hostid = ?", undef, $hostid);
}

# return true if deleted, 0 if didn't exist, exception if error
sub delete_domain {
    my ($self, $dmid) = @_;
    my ($err, $rv);
    my $dbh = $self->dbh;
    eval {
        $dbh->begin_work;
        if ($self->domain_has_files($dmid)) {
            $err = "has_files";
        } elsif ($self->domain_has_classes($dmid)) {
            $err = "has_classes";
        } else {
            $rv = $dbh->do("DELETE FROM domain WHERE dmid = ?", undef, $dmid);

            # remove the "default" class if one was created (for mindevcount)
            # this is currently the only way to delete the "default" class
            $dbh->do("DELETE FROM class WHERE dmid = ? AND classid = 0", undef, $dmid);
            $dbh->commit;
        }
	$dbh->rollback if $err;
    };
    $self->condthrow; # will rollback on errors
    throw($err) if $err;
    return $rv;
}

sub domain_has_files {
    my ($self, $dmid) = @_;
    my $has_a_fid = $self->dbh->selectrow_array('SELECT fid FROM file WHERE dmid = ? LIMIT 1',
                                                undef, $dmid);
    return $has_a_fid ? 1 : 0;
}

sub domain_has_classes {
    my ($self, $dmid) = @_;
    # queryworker does not permit removing default class, so domain_has_classes
    # should not register the default class
    my $has_a_class = $self->dbh->selectrow_array('SELECT classid FROM class WHERE dmid = ? AND classid != 0 LIMIT 1',
        undef, $dmid);
    return defined($has_a_class);
}

sub class_has_files {
    my ($self, $dmid, $clid) = @_;
    my $has_a_fid = $self->dbh->selectrow_array('SELECT fid FROM file WHERE dmid = ? AND classid = ? LIMIT 1',
                                                undef, $dmid, $clid);
    return $has_a_fid ? 1 : 0;
}

# return new classid on success (non-zero integer), die on failure
# throw 'dup' on duplicate name
sub create_class {
    my ($self, $dmid, $classname) = @_;
    my $dbh = $self->dbh;

    my ($clsid, $rv);

    eval {
        $dbh->begin_work;
        if ($classname eq 'default') {
            $clsid = 0;
        } else {
            # get the max class id in this domain
            my $maxid = $dbh->selectrow_array
                ('SELECT MAX(classid) FROM class WHERE dmid = ?', undef, $dmid) || 0;
            $clsid = $maxid + 1;
        }
        # now insert the new class
        $rv = $dbh->do("INSERT INTO class (dmid, classid, classname, mindevcount) VALUES (?, ?, ?, ?)",
                       undef, $dmid, $clsid, $classname, 2);
        $dbh->commit if $rv;
    };
    if ($@ || $dbh->err) {
        if ($self->was_duplicate_error) {
            # ensure we're not inside a transaction
            if ($dbh->{AutoCommit} == 0) { eval { $dbh->rollback }; }
            throw("dup");
        }
    }
    $self->condthrow; # this will rollback on errors
    return $clsid if $rv;
    die;
}

# return 1 on success, throw "dup" on duplicate name error, die otherwise
sub update_class_name {
    my $self = shift;
    my %arg  = $self->_valid_params([qw(dmid classid classname)], @_);
    my $rv = eval {
        $self->dbh->do("UPDATE class SET classname=? WHERE dmid=? AND classid=?",
                       undef, $arg{classname}, $arg{dmid}, $arg{classid});
    };
    throw("dup") if $self->was_duplicate_error;
    $self->condthrow;
    return 1;
}

# return 1 on success, die otherwise
sub update_class_mindevcount {
    my $self = shift;
    my %arg  = $self->_valid_params([qw(dmid classid mindevcount)], @_);
    eval {
    $self->dbh->do("UPDATE class SET mindevcount=? WHERE dmid=? AND classid=?",
                   undef, $arg{mindevcount}, $arg{dmid}, $arg{classid});
    };
    $self->condthrow;
    return 1;
}

# return 1 on success, die otherwise
sub update_class_replpolicy {
    my $self = shift;
    my %arg  = $self->_valid_params([qw(dmid classid replpolicy)], @_);
    eval {
    $self->dbh->do("UPDATE class SET replpolicy=? WHERE dmid=? AND classid=?",
                   undef, $arg{replpolicy}, $arg{dmid}, $arg{classid});
    };
    $self->condthrow;
    return 1;
}

# return 1 on success, die otherwise
sub update_class_hashtype {
    my $self = shift;
    my %arg  = $self->_valid_params([qw(dmid classid hashtype)], @_);
    eval {
    $self->dbh->do("UPDATE class SET hashtype=? WHERE dmid=? AND classid=?",
                   undef, $arg{hashtype}, $arg{dmid}, $arg{classid});
    };
    $self->condthrow;
}

sub nfiles_with_dmid_classid_devcount {
    my ($self, $dmid, $classid, $devcount) = @_;
    return $self->dbh->selectrow_array('SELECT COUNT(*) FROM file WHERE dmid = ? AND classid = ? AND devcount = ?',
                                       undef, $dmid, $classid, $devcount);
}

sub set_server_setting {
    my ($self, $key, $val) = @_;
    my $dbh = $self->dbh;
    die "Your database does not support REPLACE! Reimplement set_server_setting!" unless $self->can_replace;

    eval {
        if (defined $val) {
            $dbh->do("REPLACE INTO server_settings (field, value) VALUES (?, ?)", undef, $key, $val);
        } else {
            $dbh->do("DELETE FROM server_settings WHERE field=?", undef, $key);
        }
    };

    die "Error updating 'server_settings': " . $dbh->errstr if $dbh->err;
    return 1;
}

# FIXME: racy.  currently the only caller doesn't matter, but should be fixed.
sub incr_server_setting {
    my ($self, $key, $val) = @_;
    $val = 1 unless defined $val;
    return unless $val;

    return 1 if $self->dbh->do("UPDATE server_settings ".
                               "SET value=value+? ".
                               "WHERE field=?", undef,
                               $val, $key) > 0;
    $self->set_server_setting($key, $val);
}

sub server_setting {
    my ($self, $key) = @_;
    return $self->dbh->selectrow_array("SELECT value FROM server_settings WHERE field=?",
                                       undef, $key);
}

sub server_settings {
    my ($self) = @_;
    my $ret = {};
    my $sth = $self->dbh->prepare("SELECT field, value FROM server_settings");
    $sth->execute;
    while (my ($k, $v) = $sth->fetchrow_array) {
        $ret->{$k} = $v;
    }
    return $ret;
}

# register a tempfile and return the fidid, which should be allocated
# using autoincrement/sequences if the passed in fid is undef.  however,
# if fid is passed in, that value should be used and returned.
#
# return new/passed in fidid on success.
# throw 'dup' if fid already in use
# return 0/undef/die on failure
#
sub register_tempfile {
    my $self = shift;
    my %arg  = $self->_valid_params([qw(fid dmid key classid devids)], @_);

    my $dbh = $self->dbh;
    my $fid = $arg{fid};

    my $explicit_fid_used = $fid ? 1 : 0;

    # setup the new mapping.  we store the devices that we picked for
    # this file in here, knowing that they might not be used.  create_close
    # is responsible for actually mapping in file_on.  NOTE: fid is being
    # passed in, it's either some number they gave us, or it's going to be
    # 0/undef which translates into NULL which means to automatically create
    # one.  that should be fine.
    my $ins_tempfile = sub {
        my $rv = eval {
            # We must only pass the correct number of bind parameters
            # Using 'NULL' for the AUTO_INCREMENT/SERIAL column will fail on
            # Postgres, where you are expected to leave it out or use DEFAULT
            # Leaving it out seems sanest and least likely to cause problems
            # with other databases.
            my @keys = ('dmid', 'dkey', 'classid', 'devids', 'createtime');
            my @vars = ('?'   , '?'   , '?'      , '?'     , $self->unix_timestamp);
            my @vals = ($arg{dmid}, $arg{key}, $arg{classid} || 0, $arg{devids});
            # Do not check for $explicit_fid_used, but rather $fid directly
            # as this anonymous sub is called from the loop later
            if($fid) {
                unshift @keys, 'fid';
                unshift @vars, '?';
                unshift @vals, $fid;
            }
            my $sql = "INSERT INTO tempfile (".join(',',@keys).") VALUES (".join(',',@vars).")";
            $dbh->do($sql, undef, @vals);
        };
        if (!$rv) {
            return undef if $self->was_duplicate_error;
            die "Unexpected db error into tempfile: " . $dbh->errstr;
        }

        unless (defined $fid) {
            # if they did not give us a fid, then we want to grab the one that was
            # theoretically automatically generated
            $fid = $dbh->last_insert_id(undef, undef, 'tempfile', 'fid')
                or die "No last_insert_id found";
        }
        return undef unless defined $fid && $fid > 0;
        return 1;
    };

    unless ($ins_tempfile->()) {
        throw("dup") if $explicit_fid_used;
        die "tempfile insert failed";
    }

    my $fid_in_use = sub {
        my $exists = $dbh->selectrow_array("SELECT COUNT(*) FROM file WHERE fid=?", undef, $fid);
        return $exists ? 1 : 0;
    };

    # See notes in MogileFS::Config->check_database
    my $min_fidid = MogileFS::Config->config('min_fidid');

    # if the fid is in use, do something
    while ($fid_in_use->($fid) || $fid <= $min_fidid) {
        throw("dup") if $explicit_fid_used;

        # be careful of databases which reset their
        # auto-increment/sequences when the table is empty (InnoDB
        # did/does this, for instance).  So check if it's in use, and
        # re-seed the table with the highest known fid from the file
        # table.

        # get the highest fid from the filetable and insert a dummy row
        $fid = $dbh->selectrow_array("SELECT MAX(fid) FROM file");
        $ins_tempfile->();  # don't care about its result

        # then do a normal auto-increment
        $fid = undef;
        $ins_tempfile->() or die "register_tempfile failed after seeding";
    }

    return $fid;
}

# return hashref of row containing columns "fid, dmid, dkey, length,
# classid, devcount" provided a $dmid and $key (dkey).  or undef if no
# row.
sub file_row_from_dmid_key {
    my ($self, $dmid, $key) = @_;
    return $self->dbh->selectrow_hashref("SELECT fid, dmid, dkey, length, classid, devcount ".
                                         "FROM file WHERE dmid=? AND dkey=?",
                                         undef, $dmid, $key);
}

# return hashref of row containing columns "fid, dmid, dkey, length,
# classid, devcount" provided a $fidid or undef if no row.
sub file_row_from_fidid {
    my ($self, $fidid) = @_;
    return $self->dbh->selectrow_hashref("SELECT fid, dmid, dkey, length, classid, devcount ".
                                         "FROM file WHERE fid=?",
                                         undef, $fidid);
}

# return an arrayref of rows containing columns "fid, dmid, dkey, length,
# classid, devcount" provided a pair of $fidid or undef if no rows.
sub file_row_from_fidid_range {
    my ($self, $fromfid, $count) = @_;
    my $sth = $self->dbh->prepare("SELECT fid, dmid, dkey, length, classid, devcount ".
                                  "FROM file WHERE fid > ? LIMIT ?");
    $sth->execute($fromfid,$count);
    return $sth->fetchall_arrayref({});
}

# return array of devids that a fidid is on
sub fid_devids {
    my ($self, $fidid) = @_;
    return @{ $self->dbh->selectcol_arrayref("SELECT devid FROM file_on WHERE fid=?",
                                             undef, $fidid) || [] };
}

# return hashref of { $fidid => [ $devid, $devid... ] } for a bunch of given @fidids
sub fid_devids_multiple {
    my ($self, @fidids) = @_;
    my $in = join(",", map { $_+0 } @fidids);
    my $ret = {};
    my $sth = $self->dbh->prepare("SELECT fid, devid FROM file_on WHERE fid IN ($in)");
    $sth->execute;
    while (my ($fidid, $devid) = $sth->fetchrow_array) {
        push @{$ret->{$fidid} ||= []}, $devid;
    }
    return $ret;
}

# return hashref of columns classid, dmid, dkey, given a $fidid, or return undef
sub tempfile_row_from_fid {
    my ($self, $fidid) = @_;
    return $self->dbh->selectrow_hashref("SELECT classid, dmid, dkey, devids ".
                                         "FROM tempfile WHERE fid=?",
                                         undef, $fidid);
}

# return 1 on success, throw "dup" on duplicate devid or throws other error on failure
sub create_device {
    my ($self, $devid, $hostid, $status) = @_;
    my $rv = $self->conddup(sub {
        $self->dbh->do("INSERT INTO device (devid, hostid, status) VALUES (?,?,?)", undef,
                       $devid, $hostid, $status);
    });
    $self->condthrow;
    die "error making device $devid\n" unless $rv > 0;
    return 1;
}

sub update_device {
    my ($self, $devid, $to_update) = @_;
    my @keys = sort keys %$to_update;
    return unless @keys;
    $self->conddup(sub {
        $self->dbh->do("UPDATE device SET " . join('=?, ', @keys)
            . "=? WHERE devid=?", undef, (map { $to_update->{$_} } @keys),
            $devid);
    });
    return 1;
}

sub update_device_usage {
    my $self = shift;
    my %arg  = $self->_valid_params([qw(mb_total mb_used devid)], @_);
    eval {
        $self->dbh->do("UPDATE device SET mb_total = ?, mb_used = ?, mb_asof = " . $self->unix_timestamp .
                       " WHERE devid = ?", undef, $arg{mb_total}, $arg{mb_used}, $arg{devid});
    };
    $self->condthrow;
}

# This is unimplemented at the moment as we must verify:
# - no file_on rows exist
# - nothing in file_to_queue is going to attempt to use it
# - nothing in file_to_replicate is going to attempt to use it
# - it's already been marked dead
# - that all trackers are likely to know this :/
# - ensure the devid can't be reused
# IE; the user can't mark it dead then remove it all at once and cause their
# cluster to implode.
sub delete_device {
    my ($self, $devid, $hostid) = @_;
    return $self->dbh->do("DELETE FROM device WHERE devid = ? and hostid = ?;", undef, $devid, $hostid);
}

sub file_on_device {
    my ($self, $devid) = @_;
    return $self->dbh->selectrow_array('SELECT COUNT(*) FROM file_on WHERE devid = ?', undef, $devid);
}

sub file_to_device {
    my ($self, $devid) = @_;
    return $self->dbh->selectrow_array('SELECT COUNT(*) FROM file_to_queue WHERE arg like ?', undef, "%$devid%");
}

sub mark_fidid_unreachable {
    my ($self, $fidid) = @_;
    die "Your database does not support REPLACE! Reimplement mark_fidid_unreachable!" unless $self->can_replace;
    $self->dbh->do("REPLACE INTO unreachable_fids VALUES (?, " . $self->unix_timestamp . ")",
                   undef, $fidid);
}

sub set_device_weight {
    my ($self, $devid, $weight) = @_;
    eval {
        $self->dbh->do('UPDATE device SET weight = ? WHERE devid = ?', undef, $weight, $devid);
    };
    $self->condthrow;
}

sub set_device_state {
    my ($self, $devid, $state) = @_;
    eval {
        $self->dbh->do('UPDATE device SET status = ? WHERE devid = ?', undef, $state, $devid);
    };
    $self->condthrow;
}

sub delete_class {
    my ($self, $dmid, $cid) = @_;
    throw("has_files") if $self->class_has_files($dmid, $cid);
    eval {
        $self->dbh->do("DELETE FROM class WHERE dmid = ? AND classid = ?", undef, $dmid, $cid);
    };
    $self->condthrow;
}

# called from a queryworker process, will trigger delete_fidid_enqueued
# in the delete worker
sub delete_fidid {
    my ($self, $fidid) = @_;
    eval { $self->dbh->do("DELETE FROM file WHERE fid=?", undef, $fidid); };
    $self->condthrow;
    $self->enqueue_for_delete2($fidid, 0);
    $self->condthrow;
}

# Only called from delete workers (after delete_fidid),
# this reduces client-visible latency from the queryworker
sub delete_fidid_enqueued {
    my ($self, $fidid) = @_;
    eval { $self->delete_checksum($fidid); };
    $self->condthrow;
    eval { $self->dbh->do("DELETE FROM tempfile WHERE fid=?", undef, $fidid); };
    $self->condthrow;
}

sub delete_tempfile_row {
    my ($self, $fidid) = @_;
    my $rv = eval { $self->dbh->do("DELETE FROM tempfile WHERE fid=?", undef, $fidid); };
    $self->condthrow;
    return $rv;
}

# Load the specified tempfile, then delete it.  If we succeed, we were
# here first; otherwise, someone else beat us here (and we return undef)
sub delete_and_return_tempfile_row {
    my ($self, $fidid) = @_;
    my $rv = $self->tempfile_row_from_fid($fidid);
    my $rows_deleted = $self->delete_tempfile_row($fidid);
    return $rv if ($rows_deleted > 0);
}

sub replace_into_file {
    my $self = shift;
    my %arg  = $self->_valid_params([qw(fidid dmid key length classid devcount)], @_);
    die "Your database does not support REPLACE! Reimplement replace_into_file!" unless $self->can_replace;
    eval {
        $self->dbh->do("REPLACE INTO file (fid, dmid, dkey, length, classid, devcount) ".
                       "VALUES (?,?,?,?,?,?) ", undef,
                       @arg{'fidid', 'dmid', 'key', 'length', 'classid', 'devcount'});
    };
    $self->condthrow;
}

# returns 1 on success, 0 on duplicate key error, dies on exception
# TODO: need a test to hit the duplicate name error condition
# TODO: switch to using "dup" exception here?
sub rename_file {
    my ($self, $fidid, $to_key) = @_;
    my $dbh = $self->dbh;
    eval {
        $dbh->do('UPDATE file SET dkey = ? WHERE fid=?',
                 undef, $to_key, $fidid);
    };
    if ($@ || $dbh->err) {
        # first is MySQL's error code for duplicates
        if ($self->was_duplicate_error) {
            return 0;
        } else {
            die $@;
        }
    }
    $self->condthrow;
    return 1;
}

sub get_domainid_by_name {
    my $self = shift;
    my ($dmid) = $self->dbh->selectrow_array('SELECT dmid FROM domain WHERE namespace = ?',
        undef, $_[0]);
    return $dmid;
}

# returns a hash of domains. Key is namespace, value is dmid.
sub get_all_domains {
    my ($self) = @_;
    my $domains = $self->dbh->selectall_arrayref('SELECT namespace, dmid FROM domain');
    return map { ($_->[0], $_->[1]) } @{$domains || []};
}

sub get_classid_by_name {
    my $self = shift;
    my ($classid) = $self->dbh->selectrow_array('SELECT classid FROM class WHERE dmid = ? AND classname = ?',
        undef, $_[0], $_[1]);
    return $classid;
}

# returns an array of hashrefs, one hashref per row in the 'class' table
sub get_all_classes {
    my ($self) = @_;
    my (@ret, $row);

    my @cols = qw/dmid classid classname mindevcount/;
    if ($self->cached_schema_version >= 10) {
        push @cols, 'replpolicy';
        if ($self->cached_schema_version >= 15) {
            push @cols, 'hashtype';
        }
    }
    my $cols = join(', ', @cols);
    my $sth = $self->dbh->prepare("SELECT $cols FROM class");
    $sth->execute;
    push @ret, $row while $row = $sth->fetchrow_hashref;
    return @ret;
}

# add a record of fidid existing on devid
# returns 1 on success, 0 on duplicate
sub add_fidid_to_devid {
    my ($self, $fidid, $devid) = @_;
    croak("fidid not non-zero") unless $fidid;
    croak("devid not non-zero") unless $devid;

    # TODO: This should possibly be insert_ignore instead
    # As if we are adding an extra file_on entry, we do not want to replace the
    # exist one. Check REPLACE semantics.
    my $rv = $self->dowell($self->ignore_replace . " INTO file_on (fid, devid) VALUES (?,?)",
                           undef, $fidid, $devid);
    return 1 if $rv > 0;
    return 0;
}

# remove a record of fidid existing on devid
# returns 1 on success, 0 if not there anyway
sub remove_fidid_from_devid {
    my ($self, $fidid, $devid) = @_;
    my $rv = eval { $self->dbh->do("DELETE FROM file_on WHERE fid=? AND devid=?",
                            undef, $fidid, $devid); };
    $self->condthrow;
    return $rv;
}

# Test if host exists.
sub get_hostid_by_id {
    my $self = shift;
    my ($hostid) = $self->dbh->selectrow_array('SELECT hostid FROM host WHERE hostid = ?',
        undef, $_[0]);
    return $hostid;
}

sub get_hostid_by_name {
    my $self = shift;
    my ($hostid) = $self->dbh->selectrow_array('SELECT hostid FROM host WHERE hostname = ?',
        undef, $_[0]);
    return $hostid;
}

# get all hosts from database, returns them as list of hashrefs, hashrefs being the row contents.
sub get_all_hosts {
    my ($self) = @_;
    my $sth = $self->dbh->prepare("SELECT /*!40000 SQL_CACHE */ hostid, status, hostname, " .
                                  "hostip, http_port, http_get_port, altip, altmask FROM host");
    $sth->execute;
    my @ret;
    while (my $row = $sth->fetchrow_hashref) {
        push @ret, $row;
    }
    return @ret;
}

# get all devices from database, returns them as list of hashrefs, hashrefs being the row contents.
sub get_all_devices {
    my ($self) = @_;
    my $sth = $self->dbh->prepare("SELECT /*!40000 SQL_CACHE */ devid, hostid, mb_total, " .
                                  "mb_used, mb_asof, status, weight FROM device");
    $self->condthrow;
    $sth->execute;
    my @return;
    while (my $row = $sth->fetchrow_hashref) {
        push @return, $row;
    }
    return @return;
}

# update the device count for a given fidid
sub update_devcount {
    my ($self, $fidid) = @_;
    my $dbh = $self->dbh;
    my $ct = $dbh->selectrow_array("SELECT COUNT(*) FROM file_on WHERE fid=?",
                                   undef, $fidid);

    eval { $dbh->do("UPDATE file SET devcount=? WHERE fid=?", undef,
              $ct, $fidid); };
    $self->condthrow;

    return 1;
}

# update the classid for a given fidid
sub update_classid {
    my ($self, $fidid, $classid) = @_;
    my $dbh = $self->dbh;

    $dbh->do("UPDATE file SET classid=? WHERE fid=?", undef,
              $classid, $fidid);

    $self->condthrow;
    return 1;
}

# enqueue a fidid for replication, from a specific deviceid (can be undef), in a given number of seconds.
sub enqueue_for_replication {
    my ($self, $fidid, $from_devid, $in) = @_;

    my $nexttry = 0;
    if ($in) {
        $nexttry = $self->unix_timestamp . " + " . int($in);
    }

    $self->retry_on_deadlock(sub {
        $self->insert_ignore("INTO file_to_replicate (fid, fromdevid, nexttry) ".
                             "VALUES (?,?,$nexttry)", undef, $fidid, $from_devid);
    });
}

# enqueue a fidid for delete
# note: if we get one more "independent" queue like this, the
# code should be collapsable? I tried once and it looked too ugly, so we have
# some redundancy.
sub enqueue_for_delete2 {
    my ($self, $fidid, $in) = @_;

    $in = 0 unless $in;
    my $nexttry = $self->unix_timestamp . " + " . int($in);

    $self->retry_on_deadlock(sub {
        $self->insert_ignore("INTO file_to_delete2 (fid, nexttry) ".
                             "VALUES (?,$nexttry)", undef, $fidid);
    });
}

# enqueue a fidid for work
sub enqueue_for_todo {
    my ($self, $fidid, $type, $in) = @_;

    $in = 0 unless $in;
    my $nexttry = $self->unix_timestamp . " + " . int($in);

    $self->retry_on_deadlock(sub {
        if (ref($fidid)) {
            $self->insert_ignore("INTO file_to_queue (fid, devid, arg, type, ".
                                 "nexttry) VALUES (?,?,?,?,$nexttry)", undef,
                                 $fidid->[0], $fidid->[1], $fidid->[2], $type);
        } else {
            $self->insert_ignore("INTO file_to_queue (fid, type, nexttry) ".
                                 "VALUES (?,?,$nexttry)", undef, $fidid, $type);
        }
    });
}

# return 1 on success.  die otherwise.
sub enqueue_many_for_todo {
    my ($self, $fidids, $type, $in) = @_;
    if (! ($self->can_insert_multi && ($self->can_replace || $self->can_insertignore))) {
        $self->enqueue_for_todo($_, $type, $in) foreach @$fidids;
        return 1;
    }

    $in = 0 unless $in;
    my $nexttry = $self->unix_timestamp . " + " . int($in);

    # TODO: convert to prepared statement?
    $self->retry_on_deadlock(sub {
        if (ref($fidids->[0]) eq 'ARRAY') {
            my $sql =  $self->ignore_replace .
                "INTO file_to_queue (fid, devid, arg, type, nexttry) VALUES ".
                join(', ', ('(?,?,?,?,?)') x scalar @$fidids);
            $self->dbh->do($sql, undef, map { @$_, $type, $nexttry } @$fidids);
        } else {
            $self->dbh->do($self->ignore_replace . " INTO file_to_queue (fid, type,
            nexttry) VALUES " .
            join(",", map { "(" . int($_) . ", $type, $nexttry)" } @$fidids));
        }
    });
    $self->condthrow;
}

# For file_to_queue queues that should be kept small, find the size.
# This isn't fast, but for small queues won't be slow, and is usually only ran
# from a single tracker.
sub file_queue_length {
    my $self = shift;
    my $type = shift;

    return $self->dbh->selectrow_array("SELECT COUNT(*) FROM file_to_queue " .
           "WHERE type = ?", undef, $type);
}

# reschedule all deferred replication, return number rescheduled
sub replicate_now {
    my ($self) = @_;

    $self->retry_on_deadlock(sub {
        return $self->dbh->do("UPDATE file_to_replicate SET nexttry = " . $self->unix_timestamp .
                              " WHERE nexttry > " . $self->unix_timestamp);
    });
}

# takes two arguments, devid and limit, both required. returns an arrayref of fidids.
sub get_fidids_by_device {
    my ($self, $devid, $limit) = @_;

    my $dbh = $self->dbh;
    my $fidids = $dbh->selectcol_arrayref("SELECT fid FROM file_on WHERE devid = ? LIMIT $limit",
                                          undef, $devid);
    return $fidids;
}

# finds a chunk of fids given a set of constraints:
# devid, fidid, age (new or old), limit
# Note that if this function is very slow on your large DB, you're likely
# sorting by "newfiles" and are missing a new index.
# returns an arrayref of fidids
sub get_fidid_chunks_by_device {
    my ($self, %o) = @_;

    my $dbh = $self->dbh;
    my $devid = delete $o{devid};
    croak("must supply at least a devid") unless $devid;
    my $age   = delete $o{age};
    my $fidid = delete $o{fidid};
    my $limit = delete $o{limit};
    croak("invalid options: " . join(', ', keys %o)) if %o;
    # If supplied a "previous" fidid, we're paging through.
    my $fidsort = '';
    my $order   = '';
    $age ||= 'old';
    if ($age eq 'old') {
        $fidsort = 'AND fid > ?' if $fidid;
        $order   = 'ASC';
    } elsif ($age eq 'new') {
        $fidsort = 'AND fid < ?' if $fidid;
        $order   = 'DESC';
    } else {
        croak("invalid age argument: " . $age);
    }
    $limit ||= 100;
    my @extra = ();
    push @extra, $fidid if $fidid;

    my $fidids = $dbh->selectcol_arrayref("SELECT fid FROM file_on WHERE devid = ? " .
        $fidsort . " ORDER BY fid $order LIMIT $limit", undef, $devid, @extra);
    return $fidids;
}

# gets fidids above fidid_low up to (and including) fidid_high
sub get_fidids_between {
    my ($self, $fidid_low, $fidid_high, $limit) = @_;
    $limit ||= 1000;
    $limit = int($limit);

    my $dbh = $self->dbh;
    my $fidids = $dbh->selectcol_arrayref(qq{SELECT fid FROM file
        WHERE fid > ? and fid <= ?
        ORDER BY fid LIMIT $limit}, undef, $fidid_low, $fidid_high);
    return $fidids;
}

# creates a new domain, given a domain namespace string.  return the dmid on success,
# throw 'dup' on duplicate name.
# override if you want a less racy version.
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

sub update_host {
    my ($self, $hid, $to_update) = @_;
    my @keys = sort keys %$to_update;
    return unless @keys;
    $self->conddup(sub {
        $self->dbh->do("UPDATE host SET " . join('=?, ', @keys)
            . "=? WHERE hostid=?", undef, (map { $to_update->{$_} } @keys),
            $hid);
    });
    return 1;
}

sub update_host_property {
    my ($self, $hostid, $col, $val) = @_;
    $self->conddup(sub {
        $self->dbh->do("UPDATE host SET $col=? WHERE hostid=?", undef, $val, $hostid);
    });
    return 1;
}

# return ne hostid, or throw 'dup' on error.
# NOTE: you need to put them into the initial 'down' state.
sub create_host {
    my ($self, $hostname, $ip) = @_;
    my $dbh = $self->dbh;
    # racy! lazy. no, better: portable! how often does this happen? :)
    my $hid = ($dbh->selectrow_array('SELECT MAX(hostid) FROM host') || 0) + 1;
    my $rv = $self->conddup(sub {
        $dbh->do("INSERT INTO host (hostid, hostname, hostip, status) ".
                 "VALUES (?, ?, ?, 'down')",
                 undef, $hid, $hostname, $ip);
    });
    return $hid if $rv;
    die "db failure";
}

# return array of row hashrefs containing columns: (fid, fromdevid,
# failcount, flags, nexttry)
sub files_to_replicate {
    my ($self, $limit) = @_;
    my $ut = $self->unix_timestamp;
    my $to_repl_map = $self->dbh->selectall_hashref(qq{
        SELECT fid, fromdevid, failcount, flags, nexttry
        FROM file_to_replicate
        WHERE nexttry <= $ut
        ORDER BY nexttry
        LIMIT $limit
    }, "fid") or return ();
    return values %$to_repl_map;
}

# "new" style queue consumption code.
# from within a transaction, fetch a limit of fids,
# then update each fid's nexttry to be off in the future,
# giving local workers some time to dequeue the items.
# Note:
# DBI (even with RaiseError) returns weird errors on
# deadlocks from selectall_hashref. So we can't do that.
# we also used to retry on deadlock within the routine,
# but instead lets return undef and let job_master retry.
sub grab_queue_chunk {
    my $self      = shift;
    my $queue     = shift;
    my $limit     = shift;
    my $extfields = shift;

    my $dbh = $self->dbh;
    my $tries = 3;
    my $work;

    return 0 unless $self->lock_queue($queue);

    my $extwhere = shift || '';
    my $fields = 'fid, nexttry, failcount';
    $fields .= ', ' . $extfields if $extfields;
    eval {
        $dbh->begin_work;
        my $ut  = $self->unix_timestamp;
        my $query = qq{
            SELECT $fields
            FROM $queue
            WHERE nexttry <= $ut
            $extwhere
            ORDER BY nexttry
            LIMIT $limit
        };
        $query .= "FOR UPDATE\n" if $self->can_for_update;
        my $sth = $dbh->prepare($query);
        $sth->execute;
        $work = $sth->fetchall_hashref('fid');
        # Nothing to work on.
        # Now claim the fids for a while.
        # TODO: Should be configurable... but not necessary.
        my $fidlist = join(',', keys %$work);
        unless ($fidlist) { $dbh->commit; return; }
        $dbh->do("UPDATE $queue SET nexttry = $ut + 1000 WHERE fid IN ($fidlist)");
        $dbh->commit;
    };
    if ($self->was_deadlock_error) {
        eval { $dbh->rollback };
        $work = undef;
    } else {
        $self->condthrow;
    }
    # FIXME: Super extra paranoia to prevent deadlocking.
    # Need to handle or die on all errors above, but $@ can get reset. For now
    # we'll just always ensure there's no transaction running at the end here.
    # A (near) release should figure the error detection correctly.
    if ($dbh->{AutoCommit} == 0) { eval { $dbh->rollback }; }
    $self->unlock_queue($queue);

    return defined $work ? values %$work : ();
}

sub grab_files_to_replicate {
    my ($self, $limit) = @_;
    return $self->grab_queue_chunk('file_to_replicate', $limit,
        'fromdevid, flags');
}

sub grab_files_to_delete2 {
    my ($self, $limit) = @_;
    return $self->grab_queue_chunk('file_to_delete2', $limit);
}

# $extwhere is ugly... but should be fine.
sub grab_files_to_queued {
    my ($self, $type, $what, $limit) = @_;
    $what ||= 'type, flags';
    return $self->grab_queue_chunk('file_to_queue', $limit,
        $what, 'AND type = ' . $type);
}

# although it's safe to have multiple tracker hosts and/or processes
# replicating the same file, around, it's inefficient CPU/time-wise,
# and it's also possible they pick different places and waste disk.
# so the replicator asks the store interface when it's about to start
# and when it's done replicating a fidid, so you can do something smart
# and tell it not to.
sub should_begin_replicating_fidid {
    my ($self, $fidid) = @_;
    my $lockname = "mgfs:fid:$fidid:replicate";
    return 1 if $self->get_lock($lockname, 1);
    return 0;
}

# called when replicator is done replicating a fid, so you can cleanup
# whatever you did in 'should_begin_replicating_fidid' above.
#
# NOTE: there's a theoretical race condition in the rebalance code,
# where (without locking as provided by
# should_begin_replicating_fidid/note_done_replicating), all copies of
# a file can be deleted by independent replicators doing rebalancing
# in different ways.  so you'll probably want to implement some
# locking in this pair of functions.
sub note_done_replicating {
    my ($self, $fidid) = @_;
    my $lockname = "mgfs:fid:$fidid:replicate";
    $self->release_lock($lockname);
}

sub find_fid_from_file_to_replicate {
    my ($self, $fidid) = @_;
    return $self->dbh->selectrow_hashref("SELECT fid, nexttry, fromdevid, failcount, flags FROM file_to_replicate WHERE fid = ?",
        undef, $fidid); 
}

sub find_fid_from_file_to_delete2 {
    my ($self, $fidid) = @_;
    return $self->dbh->selectrow_hashref("SELECT fid, nexttry, failcount FROM file_to_delete2 WHERE fid = ?",
        undef, $fidid);
}

sub find_fid_from_file_to_queue {
    my ($self, $fidid, $type) = @_;
    return $self->dbh->selectrow_hashref("SELECT fid, devid, type, nexttry, failcount, flags, arg FROM file_to_queue WHERE fid = ? AND type = ?",
        undef, $fidid, $type);
}

sub delete_fid_from_file_to_replicate {
    my ($self, $fidid) = @_;
    $self->retry_on_deadlock(sub {
        $self->dbh->do("DELETE FROM file_to_replicate WHERE fid=?", undef, $fidid);
    });
}

sub delete_fid_from_file_to_queue {
    my ($self, $fidid, $type) = @_;
    $self->retry_on_deadlock(sub {
        $self->dbh->do("DELETE FROM file_to_queue WHERE fid=? and type=?",
            undef, $fidid, $type);
    });
}

sub delete_fid_from_file_to_delete2 {
    my ($self, $fidid) = @_;
    $self->retry_on_deadlock(sub {
        $self->dbh->do("DELETE FROM file_to_delete2 WHERE fid=?", undef, $fidid);
    });
}

sub reschedule_file_to_replicate_absolute {
    my ($self, $fid, $abstime) = @_;
    $self->retry_on_deadlock(sub {
        $self->dbh->do("UPDATE file_to_replicate SET nexttry = ?, failcount = failcount + 1 WHERE fid = ?",
                       undef, $abstime, $fid);
    });
}

sub reschedule_file_to_replicate_relative {
    my ($self, $fid, $in_n_secs) = @_;
    $self->retry_on_deadlock(sub {
        $self->dbh->do("UPDATE file_to_replicate SET nexttry = " . $self->unix_timestamp . " + ?, " .
                       "failcount = failcount + 1 WHERE fid = ?",
                       undef, $in_n_secs, $fid);
    });
}

sub reschedule_file_to_delete2_absolute {
    my ($self, $fid, $abstime) = @_;
    $self->retry_on_deadlock(sub {
        $self->dbh->do("UPDATE file_to_delete2 SET nexttry = ?, failcount = failcount + 1 WHERE fid = ?",
                       undef, $abstime, $fid);
    });
}

sub reschedule_file_to_delete2_relative {
    my ($self, $fid, $in_n_secs) = @_;
    $self->retry_on_deadlock(sub {
        $self->dbh->do("UPDATE file_to_delete2 SET nexttry = " . $self->unix_timestamp . " + ?, " .
                       "failcount = failcount + 1 WHERE fid = ?",
                       undef, $in_n_secs, $fid);
    });
}

# Given a dmid prefix after and limit, return an arrayref of dkey from the file
# table.
sub get_keys_like {
    my ($self, $dmid, $prefix, $after, $limit) = @_;
    # fix the input... prefix always ends with a % so that it works
    # in a LIKE call, and after is either blank or something
    $prefix = '' unless defined $prefix;

    # escape underscores, % and \
    $prefix =~ s/([%\\_])/\\$1/g;

    $prefix .= '%';
    $after  = '' unless defined $after;

    my $like = $self->get_keys_like_operator;

    # now select out our keys
    return $self->dbh->selectcol_arrayref
        ("SELECT dkey FROM file WHERE dmid = ? AND dkey $like ? ESCAPE ? AND dkey > ? " .
         "ORDER BY dkey LIMIT $limit", undef, $dmid, $prefix, "\\", $after);
}

sub get_keys_like_operator { return "LIKE"; }

# return arrayref of all tempfile rows (themselves also arrayrefs, of [$fidid, $devids])
# that were created $secs_ago seconds ago or older.
sub old_tempfiles {
    my ($self, $secs_old) = @_;
    return $self->dbh->selectall_arrayref("SELECT fid, devids FROM tempfile " .
                                          "WHERE createtime < " . $self->unix_timestamp . " - $secs_old LIMIT 50");
}

# given an array of MogileFS::DevFID objects, mass-insert them all
# into file_on (ignoring if they're already present)
sub mass_insert_file_on {
    my ($self, @devfids) = @_;
    return 1 unless @devfids;

    if (@devfids > 1 && ! $self->can_insert_multi) {
        $self->mass_insert_file_on($_) foreach @devfids;
        return 1;
    }

    my (@qmarks, @binds);
    foreach my $df (@devfids) {
        my ($fidid, $devid) = ($df->fidid, $df->devid);
        Carp::croak("got a false fidid") unless $fidid;
        Carp::croak("got a false devid") unless $devid;
        push @binds, $fidid, $devid;
        push @qmarks, "(?,?)";
    }

    # TODO: This should possibly be insert_ignore instead
    # As if we are adding an extra file_on entry, we do not want to replace the
    # exist one. Check REPLACE semantics.
    $self->dowell($self->ignore_replace . " INTO file_on (fid, devid) VALUES " . join(',', @qmarks), undef, @binds);
    return 1;
}

sub set_schema_vesion {
    my ($self, $ver) = @_;
    $self->set_server_setting("schema_version", int($ver));
}

# returns array of fidids to try and delete again
sub fids_to_delete_again {
    my $self = shift;
    my $ut = $self->unix_timestamp;
    return @{ $self->dbh->selectcol_arrayref(qq{
        SELECT fid
         FROM file_to_delete_later
        WHERE delafter < $ut
        LIMIT 500
    }) || [] };
}

# return 1 on success.  die otherwise.
sub enqueue_fids_to_delete {
    my ($self, @fidids) = @_;
    # multi-row insert-ignore/replace CAN fail with the insert_ignore emulation sub.
    # when the first row causes the duplicate error, and the remaining rows are
    # not processed.
    if (@fidids > 1 && ! ($self->can_insert_multi && ($self->can_replace || $self->can_insertignore))) {
        $self->enqueue_fids_to_delete($_) foreach @fidids;
        return 1;
    }
    # TODO: convert to prepared statement?
    $self->retry_on_deadlock(sub {
        $self->dbh->do($self->ignore_replace . " INTO file_to_delete (fid) VALUES " .
                       join(",", map { "(" . int($_) . ")" } @fidids));
    });
    $self->condthrow;
}

sub enqueue_fids_to_delete2 {
    my ($self, @fidids) = @_;
    # multi-row insert-ignore/replace CAN fail with the insert_ignore emulation sub.
    # when the first row causes the duplicate error, and the remaining rows are
    # not processed.
    if (@fidids > 1 && ! ($self->can_insert_multi && ($self->can_replace || $self->can_insertignore))) {
        $self->enqueue_fids_to_delete2($_) foreach @fidids;
        return 1;
    }

    my $nexttry = $self->unix_timestamp;

    # TODO: convert to prepared statement?
    $self->retry_on_deadlock(sub {
        $self->dbh->do($self->ignore_replace . " INTO file_to_delete2 (fid,
        nexttry) VALUES " .
                       join(",", map { "(" . int($_) . ", $nexttry)" } @fidids));
    });
    $self->condthrow;
}

# clears everything from the fsck_log table
# return 1 on success.  die otherwise.
sub clear_fsck_log {
    my $self = shift;
    $self->dbh->do("DELETE FROM fsck_log");
    return 1;
}

# FIXME: Fsck log entries are processed a little out of order.
# Once a fsck has completed, the log should be re-summarized.
sub fsck_log_summarize {
    my $self = shift;

    my $lockname = 'mgfs:fscksum';
    my $lock = eval { $self->get_lock($lockname, 10) };
    return 0 if defined $lock && $lock == 0;

    my $logid = $self->max_fsck_logid;

    # sum-up evcode counts every so often, to make fsck_status faster,
    # avoiding a potentially-huge GROUP BY in the future..
    my $start_max_logid = $self->server_setting("fsck_start_maxlogid") || 0;
    # both inclusive:
    my $min_logid = $self->server_setting("fsck_logid_processed") || 0;
    $min_logid++;
    my $cts = $self->fsck_evcode_counts(logid_range => [$min_logid, $logid]); # inclusive notation :)
    while (my ($evcode, $ct) = each %$cts) {
        $self->incr_server_setting("fsck_sum_evcount_$evcode", $ct);
    }
    $self->set_server_setting("fsck_logid_processed", $logid);

    $self->release_lock($lockname) if $lock;
}

sub fsck_log {
    my ($self, %opts) = @_;
    $self->dbh->do("INSERT INTO fsck_log (utime, fid, evcode, devid) ".
                   "VALUES (" . $self->unix_timestamp . ",?,?,?)",
                   undef,
                   delete $opts{fid},
                   delete $opts{code},
                   delete $opts{devid});
    croak("Unknown opts") if %opts;
    $self->condthrow;

    return 1;
}

sub get_db_unixtime {
    my $self = shift;
    return $self->dbh->selectrow_array("SELECT " . $self->unix_timestamp);
}

sub max_fidid {
    my $self = shift;
    return $self->dbh->selectrow_array("SELECT MAX(fid) FROM file");
}

sub max_fsck_logid {
    my $self = shift;
    return $self->dbh->selectrow_array("SELECT MAX(logid) FROM fsck_log") || 0;
}

# returns array of $row hashrefs, from fsck_log table
sub fsck_log_rows {
    my ($self, $after_logid, $limit) = @_;
    $limit       = int($limit || 100);
    $after_logid = int($after_logid || 0);

    my @rows;
    my $sth = $self->dbh->prepare(qq{
        SELECT logid, utime, fid, evcode, devid
        FROM fsck_log
        WHERE logid > ?
        ORDER BY logid
        LIMIT $limit
    });
    $sth->execute($after_logid);
    my $row;
    push @rows, $row while $row = $sth->fetchrow_hashref;
    return @rows;
}

sub fsck_evcode_counts {
    my ($self, %opts) = @_;
    my $timegte = delete $opts{time_gte};
    my $logr    = delete $opts{logid_range};
    die if %opts;

    my $ret = {};
    my $sth;
    if ($timegte) {
        $sth = $self->dbh->prepare(qq{
            SELECT evcode, COUNT(*) FROM fsck_log
            WHERE utime >= ?
            GROUP BY evcode
         });
        $sth->execute($timegte||0);
    }
    if ($logr) {
        $sth = $self->dbh->prepare(qq{
            SELECT evcode, COUNT(*) FROM fsck_log
            WHERE logid >= ? AND logid <= ?
            GROUP BY evcode
         });
        $sth->execute($logr->[0], $logr->[1]);
    }
    while (my ($ev, $ct) = $sth->fetchrow_array) {
        $ret->{$ev} = $ct;
    }
    return $ret;
}

# run before daemonizing.  you can die from here if you see something's amiss.  or emit
# warnings.
sub pre_daemonize_checks {
    my $self = shift;

    $self->pre_daemonize_check_slaves;
}

sub pre_daemonize_check_slaves {
    my $sk = MogileFS::Config->server_setting('slave_keys')
        or return;

    my @slaves;
    foreach my $key (split /\s*,\s*/, $sk) {
        my $slave = MogileFS::Config->server_setting("slave_$key");

        if (!$slave) {
            error("key for slave DB config: slave_$key not found in configuration");
            next;
        }

        my ($dsn, $user, $pass) = split /\|/, $slave;
        if (!defined($dsn) or !defined($user) or !defined($pass)) {
            error("key slave_$key contains $slave, which doesn't split in | into DSN|user|pass - ignoring");
            next;
        }
        push @slaves, [$dsn, $user, $pass]
    }

    return unless @slaves; # Escape this block if we don't have a set of slaves anyways

    MogileFS::run_global_hook('slave_list_check', \@slaves);
}


# attempt to grab a lock of lockname, and timeout after timeout seconds.
# returns 1 on success and 0 on timeout.  dies if more than one lock is already outstanding.
sub get_lock {
    my ($self, $lockname, $timeout) = @_;
    die "Lock recursion detected (grabbing $lockname, had $self->{last_lock}).  Bailing out." if $self->{lock_depth};
    die "get_lock not implemented for $self";
}

# attempt to release a lock of lockname.
# returns 1 on success and 0 if no lock we have has that name.
sub release_lock {
    my ($self, $lockname) = @_;
    die "release_lock not implemented for $self";
}

# MySQL has an issue where you either get excessive deadlocks, or INSERT's
# hang forever around some transactions. Use ghetto locking to cope.
sub lock_queue { 1 }
sub unlock_queue { 1 }

sub BLOB_BIND_TYPE { undef; }

sub set_checksum {
    my ($self, $fidid, $hashtype, $checksum) = @_;
    my $dbh = $self->dbh;
    die "Your database does not support REPLACE! Reimplement set_checksum!" unless $self->can_replace;

    eval {
        my $sth = $dbh->prepare("REPLACE INTO checksum " .
                                "(fid, hashtype, checksum) " .
                                "VALUES (?, ?, ?)");
        $sth->bind_param(1, $fidid);
        $sth->bind_param(2, $hashtype);
        $sth->bind_param(3, $checksum, BLOB_BIND_TYPE);
        $sth->execute;
    };
    $self->condthrow;
}

sub get_checksum {
    my ($self, $fidid) = @_;

    $self->dbh->selectrow_hashref("SELECT fid, hashtype, checksum " .
                                  "FROM checksum WHERE fid = ?",
                                  undef, $fidid);
}

sub delete_checksum {
    my ($self, $fidid) = @_;

    $self->dbh->do("DELETE FROM checksum WHERE fid = ?", undef, $fidid);
}

# setup the value used in a 'nexttry' field to indicate that this item will
# never actually be tried again and require some sort of manual intervention.
use constant ENDOFTIME => 2147483647;

sub end_of_time { ENDOFTIME; }

# returns the size of the non-urgent replication queue
# nexttry == 0                        - the file is urgent
# nexttry != 0 && nexttry < ENDOFTIME - the file is deferred
sub deferred_repl_queue_length {
    my ($self) = @_;

    return $self->dbh->selectrow_array('SELECT COUNT(*) FROM file_to_replicate WHERE nexttry != 0 AND nexttry < ?', undef, $self->end_of_time);
}

1;

__END__

=head1 NAME

MogileFS::Store - data storage provider.  base class.

=head1 ABOUT

MogileFS aims to be database-independent (though currently as of late
2006 only works with MySQL).  In the future, the server will create a
singleton instance of type "MogileFS::Store", like
L<MogileFS::Store::MySQL>, and all database interaction will be
through it.

=head1 SEE ALSO

L<MogileFS::Store::MySQL>



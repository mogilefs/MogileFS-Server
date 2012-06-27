package MogileFS::Config;
use strict;
require Exporter;
use MogileFS::ProcManager;
use Getopt::Long;
use MogileFS::Store;
use Sys::Hostname ();

our @ISA = qw(Exporter);
our @EXPORT = qw($DEBUG config set_config FSCK_QUEUE REBAL_QUEUE);
our @EXPORT_OK = qw(DEVICE_SUMMARY_CACHE_TIMEOUT);

our ($DEFAULT_CONFIG, $MOGSTORED_STREAM_PORT, $DEBUG);
$DEBUG = 0;
$DEFAULT_CONFIG = "/etc/mogilefs/mogilefsd.conf";
$MOGSTORED_STREAM_PORT = 7501;

use constant FSCK_QUEUE => 1;
use constant REBAL_QUEUE => 2;
use constant DEVICE_SUMMARY_CACHE_TIMEOUT => 15;

my %conf;
my %server_settings;
my $has_cached_settings = 0;
sub set_config {
    shift if @_ == 3;
    my ($k, $v) = @_;

    # if a child, propagate to parent
    if (my $worker = MogileFS::ProcManager->is_child) {
        $worker->send_to_parent(":set_config_from_child $k $v");
    } elsif (defined $v) {
        MogileFS::ProcManager->send_to_all_children(":set_config_from_parent $k $v");
    }

    return set_config_no_broadcast($k, $v);
}

sub set_config_no_broadcast {
    shift if @_ == 3;
    my ($k, $v) = @_;
    return $conf{$k} = $v;
}

set_config('default_mindevcount', 2);
set_config('min_fidid', 0);

our (
    %cmdline,
    %cfgfile,
    $config,
    $skipconfig,
    $daemonize,
    $db_dsn,
    $db_user,
    $db_pass,
    $conf_port,
    $listen,
    $query_jobs,
    $delete_jobs,
    $replicate_jobs,
    $fsck_jobs,
    $reaper_jobs,
    $monitor_jobs,
    $max_handles,
    $min_free_space,
    $max_disk_age,
    $node_timeout,          # time in seconds to wait for storage node responses
    $conn_timeout,          # time in seconds to wait for connection to storage node
    $pidfile,
    $repl_use_get_port,
    $local_network,
   );

my $default_mindevcount;

sub load_config {
    my $dummy_workerport;

    # Command-line options will override
    Getopt::Long::Configure( "bundling" );
    Getopt::Long::GetOptions(
                             'c|config=s'    => \$config,
                             's|skipconfig'  => \$skipconfig,
                             'd|debug+'      => \$cmdline{debug},
                             'D|daemonize'   => \$cmdline{daemonize},
                             'dsn=s'         => \$cmdline{db_dsn},
                             'dbuser=s'      => \$cmdline{db_user},
                             'dbpass:s'      => \$cmdline{db_pass},
                             'user=s'        => \$cmdline{user},
                             'p|confport=i'  => \$cmdline{conf_port},
                             'l|listen=s@'   => \$cmdline{listen},
                             'w|workers=i'   => \$cmdline{query_jobs},
                             'no_http'       => \$cmdline{no_http},  # OLD, we just eat it to shut it up.
                             'workerport=i'  => \$dummy_workerport,  # eat it for backwards compat
                             'max_disk_age=i'  => \$cmdline{max_disk_age},
                             'min_free_space=i' => \$cmdline{min_free_space},
                             'default_mindevcount=i' => \$cmdline{default_mindevcount},
                             'node_timeout=i' => \$cmdline{node_timeout},
                             'conn_timeout=i' => \$cmdline{conn_timeout},
                             'max_handles=i'  => \$cmdline{max_handles},
                             'pidfile=s'      => \$cmdline{pidfile},
                             'no_schema_check' => \$cmdline{no_schema_check},
                             'plugins=s@'        => \$cmdline{plugins},
                             'repl_use_get_port=i' => \$cmdline{repl_use_get_port},
                             'local_network=s' => \$cmdline{local_network},
                             'mogstored_stream_port' => \$cmdline{mogstored_stream_port},
                             'cache_type' => \$cmdline{cache_type},
                             'cache_servers' => \$cmdline{cache_servers},
                             'cache_ttl' => \$cmdline{cache_ttl},
                             );

    # warn of old/deprecated options
    warn "The command line option --workerport is no longer needed (and has no necessary replacement)\n"
        if $dummy_workerport;

    $config = $DEFAULT_CONFIG if !$config && -r $DEFAULT_CONFIG;

    # Read the config file if one was specified
    if ($config && !$skipconfig) {
        open my $cf, "<$config" or die "open: $config: $!";

        my $configLine = qr{
            ^\s*                        # Leading space
                ([\w.]+)                # Key
                \s+ =? \s*              # space + optional equal + optional space
                (.+?)                   # Value
                \s*$                    # Trailing space
            }x;

        my $linecount = 0;
        while (defined( my $line = <$cf> )) {
            $linecount++;
            next if $line =~ m!^\s*(\#.*)?$!;
            die "Malformed config file (line $linecount)" unless $line =~ $configLine;

            my ( $key, $value ) = ( $1, $2 );
            print STDERR "Setting '$key' to '$value'\n" if $cmdline{debug};
            $cfgfile{$key} = $value;
        }

        close $cf;
    }

    # Fill in defaults for those values which were either loaded from config or
    # specified on the command line. Command line takes precedence, then values in
    # the config file, then the defaults.
    $daemonize      = choose_value( 'daemonize', 0 );
    $db_dsn         = choose_value( 'db_dsn', "DBI:mysql:mogilefs" );
    $db_user        = choose_value( 'db_user', "mogile" );
    $db_pass        = choose_value( 'db_pass', "", 1 );
    $conf_port      = choose_value( 'conf_port', 7001 );
    $query_jobs     = set_config("query_jobs",
                                 choose_value( 'listener_jobs', undef) || # undef if not present, then we
                                 choose_value( 'query_jobs', 20 ));       # fall back to query_jobs, new name
    $delete_jobs    = choose_value( 'delete_jobs', 1 );
    $replicate_jobs = choose_value( 'replicate_jobs', 1 );
    $fsck_jobs      = choose_value( 'fsck_jobs', 1 );
    $reaper_jobs    = choose_value( 'reaper_jobs', 1 );
    $monitor_jobs   = choose_value( 'monitor_jobs', 1 );
    $min_free_space = choose_value( 'min_free_space', 100 );
    $max_disk_age   = choose_value( 'max_disk_age', 5 );
    $max_handles    = choose_value( 'max_handles', 0 );
    $DEBUG          = choose_value( 'debug', $ENV{DEBUG} || 0 );
    $pidfile        = choose_value( 'pidfile', "" );

    choose_value( 'mogstored_stream_port', $MOGSTORED_STREAM_PORT );
    choose_value( 'default_mindevcount', 2 );
    $node_timeout   = choose_value( 'node_timeout', 2 );
    $conn_timeout   = choose_value( 'conn_timeout', 2 );

    choose_value( 'cache_type', "none" );
    choose_value( 'cache_servers', "" );
    choose_value( 'cache_ttl', 3600 );

    choose_value( 'rebalance_ignore_missing', 0 );
    $repl_use_get_port = choose_value( 'repl_use_get_port', 0 );
    $local_network  = choose_value( 'local_network', '' );

    choose_value( 'no_schema_check', 0 );

    # now load plugins
    my @plugins;
    push @plugins, $cfgfile{plugins}    if $cfgfile{plugins};
    push @plugins, @{$cmdline{plugins}} if $cmdline{plugins};

    foreach my $plugin (@plugins) {
        load_plugins($plugin);
    }

    choose_value('user', '');

    # fix up config file listen option
    $cfgfile{listen} = [ split(/\s*,\s*/, $cfgfile{listen}) ] if defined $cfgfile{listen};

    # now let's fix up the listen option to include the port if it doesn't already; we can't use
    # choose_value as that uses set_config and that sends to children; this option doesn't apply
    my $temp_listen = $cmdline{listen} || $cfgfile{listen} || [ '0.0.0.0' ];
    $conf{listen} = $listen = [ map { /:/ ? $_ : "$_:$conf{conf_port}" } @$temp_listen ];
}

### FUNCTION: choose_value( $name, $default )
sub choose_value {
    my ( $name, $default ) = @_;
    return set_config($name, $cmdline{$name}) if defined $cmdline{$name};
    return set_config($name, $cfgfile{$name}) if defined $cfgfile{$name};
    return set_config($name, $default);
}

sub load_plugins {
    my $plugins = shift;
    foreach my $plugin (split(/\s*,\s*/, $plugins)) {
        my $rv = eval "use MogileFS::Plugin::$plugin; MogileFS::Plugin::$plugin->load; 1;";
        die "Unable to load $plugin: $@\n" unless $rv;
    }
}

sub config {
    shift if @_ == 2;
    my $k = shift;
    die "No config variable '$k'" unless defined $conf{$k};
    return $conf{$k};
}

sub check_database {
    my $sto = eval { Mgd::get_store() };
    unless ($sto && $sto->ping) {
        die qq{
Error: unable to establish connection with your MogileFS database.

Please verify that you have correctly setup a configuration file or are
providing the correct information in order to reach the database and try
running the MogileFS server again.  If you haven\'t setup your database yet,
run 'mogdbsetup'.

Details: [sto=$sto, err=$@]
}
    }

    my $sversion = MogileFS::Config->server_setting('schema_version') || 0;
    my $expect_ver = MogileFS::Store->latest_schema_version;
    unless ($sversion == $expect_ver || MogileFS::Config->config('no_schema_check')) {
        die "Server's database schema version of $sversion doesn't match expected value of $expect_ver.  Halting.\n\n".
            "Please run mogdbsetup to upgrade your schema.\n";
    }

    $sto->pre_daemonize_checks;

    # If MySQL gets restarted InnoDB may reset its auto_increment counter. If
    # the first few fids have been deleted, the "reset to max on duplicate"
    # code won't fire immediately.
    # Instead, we also trigger it if a configured "min_fidid" is higher than
    # what we got from innodb.
    # For bonus points: This value should be periodically updated, in case the
    # trackers don't go down as often as the database.
    my $min_fidid = $sto->max_fidid;
    $min_fidid = 0 unless $min_fidid;
    set_config('min_fidid', $min_fidid);
}

# set_server_setting( key, value )
#   set value to undef to remove whatever is presently stored; returns 1 on success or
#   undef on error
sub set_server_setting {
    my ($class, $key, $val) = @_;
    return unless $key;

    my $sto = Mgd::get_store();
    $sto->set_server_setting($key, $val);
    return 1;
}

# get_server_setting( key )
#   get value of server setting, undef on error (or no result)
sub server_setting {
    my ($class, $key) = @_;
    return Mgd::get_store()->server_setting($key);
}

sub cache_server_setting {
    my ($class, $key, $val) = @_;
    $has_cached_settings++ unless $has_cached_settings;
    if (! defined $val) {
        delete $server_settings{$key}
            if exists $server_settings{$key};
    }
    $server_settings{$key} = $val;
}

sub server_setting_cached {
    my ($class, $key, $fallback) = @_;
    $fallback = 1 unless (defined $fallback);
    if (!$has_cached_settings && $fallback) {
        return MogileFS::Config->server_setting($key);
    }
    return $server_settings{$key};
}

my $cache_hostname;
sub hostname {
    return $cache_hostname ||= Sys::Hostname::hostname();
}

sub server_setting_is_readable {
    my ($class, $key) = @_;
    return 1 if $key eq 'fsck_checksum';
    return 0 if $key =~ /^fsck_/;
    return 1;
}

# returns subref which cleans (canonicalizes) the value, or dies if invalid format.
#   my $cleanval = $code->($val);
sub server_setting_is_writable {
    my ($class, $key) = @_;

    # common formats:
    my $any          = sub { $_[0]; };
    my $del_if_blank = sub { $_[0] || undef };
    my $bool         = sub {
        my $v = shift;
        return "0" unless $v;
        return "0" if $v =~ /^(0|f|off|n)/i;
        return "1" if $v =~ /^(1|t|on|y)/i;
        die "Unknown format";
    };
    my $num          = sub {
        my $v = shift;
        return "0" unless $v;
        return $v if $v =~ /^\d+$/;
        die "Must be numeric";
    };
    my $matchre      = sub {
        my $re = shift;
        return sub {
            my $v = shift;
            return $v if $v =~ /$re/;
            die "Doesn't match acceptable format.";
        };
    };
    my $valid_netmask = sub {
        my $n = Net::Netmask->new2($_[0]);
        die "Doesn't match an acceptable netmask" unless $n;
    };
    my $valid_netmask_list = sub {
        my @ns = split /[,\s]+/, $_[0];
        foreach my $n (@ns) {
            $valid_netmask->($n);
        }
        return $_[0];
    };

    # let slave settings go through unmodified, for now.
    if ($key =~ /^slave_/) { return $del_if_blank };
    if ($key eq "enable_rebalance") { return $bool };
    if ($key eq "skip_devcount") { return $bool };
    if ($key eq "skip_mkcol") { return $bool };
    if ($key eq "case_sensitive_list_keys") { return $bool };
    if ($key eq "memcache_servers") { return $any  };
    if ($key eq "memcache_ttl") { return $num };
    if ($key eq "internal_queue_limit") { return $num };

    # ReplicationPolicy::MultipleNetworks
    if ($key eq 'network_zones') { return $any };
    if ($key =~ /^zone_/) { return $valid_netmask_list };

    if ($key eq "rebalance_policy") { return sub {
        my $v = shift;
        return undef unless $v;
        # TODO: actually load the provided class and test if it loads?
        die "Doesn't match acceptable format" unless
            $v =~ /^[\w:\-]+$/;
        return $v;
    }}

    # should probably restrict to (\d+)
    if ($key =~ /^queue_/) { return $any };

    if ($key eq "fsck_checksum") {
        return sub {
            my $v = shift;
            return "off" if $v eq "off";
            return undef if $v eq "class";
            return $v if MogileFS::Checksum->valid_alg($v);
            die "Not a valid checksum algorithm";
        }
    }

    return 0;
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:

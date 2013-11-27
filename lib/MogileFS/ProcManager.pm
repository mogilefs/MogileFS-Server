package MogileFS::ProcManager;
use strict;
use warnings;
use POSIX qw(:sys_wait_h sigprocmask SIGINT SIG_BLOCK SIG_UNBLOCK);
use Symbol;
use Socket;
use MogileFS::Connection::Client;
use MogileFS::Connection::Worker;
use MogileFS::Util qw(apply_state_events);

# This class handles keeping lists of workers and clients and
# assigning them to each other when things happen.  You don't actually
# instantiate a procmanager.  the class itself holds all state.

# Mappings: fd => [ clientref, jobstring, starttime ]
# queues are just lists of Client class objects
# ChildrenByJob: job => { pid => $client }
# ErrorsTo: fid => Client
# RecentQueries: [ string, string, string, ... ]
# Stats: element => number
our ($IsChild, @RecentQueries,
     %Mappings, %ChildrenByJob, %ErrorsTo, %Stats);

our $starttime = time(); # time we got going
sub server_starttime { return $starttime }

my @IdleQueryWorkers;  # workers that are idle, able to process commands  (MogileFS::Worker::Query, ...)
my @PendingQueries;    # [ MogileFS::Connection::Client, "$ip $query" ]

my %idle_workers = (); # 'job' -> {href of idle workers}
my %pending_work = (); # 'job' -> [aref of pending work]

$IsChild = 0;  # either false if we're the parent, or a MogileFS::Worker object

# keep track of what all child pids are doing, and what jobs are being
# satisfied.
my %child  = ();    # pid -> MogileFS::Connection::Worker
my %todie  = ();    # pid -> 1 (lists pids that we've asked to die)
my %jobs   = ();    # jobname -> [ min, current ]

# we start job_master after monitor has run, but this avoid undef warning
# in job_needs_reduction
$jobs{job_master} = [ 0, 0 ];

our $allkidsup = 0;  # if true, all our kids are running. set to 0 when a kid dies.

my @prefork_cleanup;  # subrefs to run to clean stuff up before we make a new child

*error = \&Mgd::error;

my $monitor_good = 0; # ticked after monitor executes once after startup

my $nowish;  # updated approximately once per second

# it's pointless to spawn certain jobs without a job_master
my $want_job_master;
my %needs_job_master = (
    delete => 1,
    fsck => 1,
    replicate => 1,
);

sub push_pre_fork_cleanup {
    my ($class, $code) = @_;
    push @prefork_cleanup, $code;
}

sub RecentQueries {
    return @RecentQueries;
}

sub write_pidfile {
    my $class = shift;
    my $pidfile = MogileFS->config("pidfile")
        or return 1;
    my $fh;
    unless (open($fh, ">$pidfile")) {
        Mgd::log('err', "couldn't create pidfile '$pidfile': $!");
        return 0;
    }
    unless ((print $fh "$$\n") && close($fh)) {
        Mgd::log('err', "couldn't write into pidfile '$pidfile': $!");
        remove_pidfile();
        return 0;
    }
    return 1;
}

sub remove_pidfile {
    my $class = shift;
    my $pidfile = MogileFS->config("pidfile")
        or return;
    unlink $pidfile;
    return 1;
}

sub set_min_workers {
    my ($class, $job, $min) = @_;
    $jobs{$job} ||= [undef, 0];   # [min, current]
    $jobs{$job}->[0] = $min;

    # TODO: set allkipsup false, so spawner re-checks?
}

sub job_to_class_suffix {
    my ($class, $job) = @_;
    return {
        fsck        => "Fsck",
        queryworker => "Query",
        delete      => "Delete",
        replicate   => "Replicate",
        reaper      => "Reaper",
        monitor     => "Monitor",
        job_master  => "JobMaster",
    }->{$job};
}

sub job_to_class {
    my ($class, $job) = @_;
    my $suffix = $class->job_to_class_suffix($job) or return "";
    return "MogileFS::Worker::$suffix";
}

sub child_pids {
    return keys %child;
}

sub WatchDog {
    foreach my $pid (keys %child) {
        my MogileFS::Connection::Worker $child = $child{$pid};
        my $healthy = $child->watchdog_check;
        next if $healthy;

        # special $todie level of 2 means the watchdog tried to kill it.
        # TODO: Should be a CONSTANT?
        next if $todie{$pid} && $todie{$pid} == 2;
        note_pending_death($child->job, $pid, 2);

        error("Watchdog killing worker $pid (" . $child->job . ")");
        kill 9, $pid;
    }
}

# returns a sub that Danga::Socket calls after each event loop round.
# the sub must return 1 for the program to continue running.
sub PostEventLoopChecker {
    my $lastspawntime = 0; # time we last ran spawn_children sub

    return sub {
        # run only once per second
        $nowish = time();
        return 1 unless $nowish > $lastspawntime;
        $lastspawntime = $nowish;

        MogileFS::ProcManager->WatchDog;

        # see if anybody has died, but don't hang up on doing so
        while(my $pid = waitpid -1, WNOHANG) {
            last unless $pid > 0;
            $allkidsup = 0; # know something died

            # when a child dies, figure out what it was doing
            # and note that job has one less worker
            my $jobconn;
            if (($jobconn = delete $child{$pid})) {
                my $job = $jobconn->job;
                my $extra = $todie{$pid} ? "expected" : "UNEXPECTED";
                error("Child $pid ($job) died: $? ($extra)");
                MogileFS::ProcManager->NoteDeadChild($pid);
                $jobconn->close;

                if (my $jobstat = $jobs{$job}) {
                    # if the pid is in %todie, then we have asked it to shut down
                    # and have already decremented the jobstat counter and don't
                    # want to do it again
                    unless (my $true = delete $todie{$pid}) {
                        # decrement the count of currently running jobs
                        $jobstat->[1]--;
                    }
                }
            }
        }

        return 1 if $allkidsup;

        # foreach job, fork enough children
        while (my ($job, $jobstat) = each %jobs) {

            # do not spawn job_master-dependent workers if we have no job_master
            next if (! $want_job_master && $needs_job_master{$job});

            my $need = $jobstat->[0] - $jobstat->[1];
            if ($need > 0) {
                error("Job $job has only $jobstat->[1], wants $jobstat->[0], making $need.");
                for (1..$need) {
                    my $jobconn = make_new_child($job)
                        or return 1;  # basically bail: true value keeps event loop running
                    $child{$jobconn->pid} = $jobconn;

                    # now increase the count of processes currently doing this job
                    $jobstat->[1]++;
                }
            }
        }

        # if we got this far, all jobs have been re-created.  note that
        # so we avoid more CPU usage in this post-event-loop callback later
        $allkidsup = 1;

        # true value keeps us running:
        return 1;
    };
}

sub make_new_child {
    my $job = shift;

    my $pid;
    my $sigset;

    # Ensure our dbh is closed before we fork anything.
    # Causes problems on some platforms (Solaris+Postgres)
    Mgd::close_store();

    # block signal for fork
    $sigset = POSIX::SigSet->new(SIGINT);
    sigprocmask(SIG_BLOCK, $sigset)
        or return error("Can't block SIGINT for fork: $!");

    socketpair(my $parents_ipc, my $childs_ipc, AF_UNIX, SOCK_STREAM, PF_UNSPEC )
        or die( "socketpair failed: $!" );

    return error("fork failed creating $job: $!")
        unless defined ($pid = fork);

    # enable auto-flush, so it's not pipe-buffered between parent/child
    select((select( $parents_ipc ), $|++)[0]);
    select((select( $childs_ipc  ), $|++)[0]);

    # if i'm the parent
    if ($pid) {
        sigprocmask(SIG_UNBLOCK, $sigset)
            or return error("Can't unblock SIGINT for fork: $!");

        close($childs_ipc);  # unnecessary but explicit
        IO::Handle::blocking($parents_ipc, 0);

        my $worker_conn = MogileFS::Connection::Worker->new($parents_ipc);
        $worker_conn->pid($pid);
        $worker_conn->job($job);
        MogileFS::ProcManager->RegisterWorkerConn($worker_conn);
        return $worker_conn;
    }

    # let children have different random number seeds
    srand();

    # as a child, we want to close these and ignore them
    $_->() foreach @prefork_cleanup;
    close($parents_ipc);
    undef $parents_ipc;

    $SIG{INT} = 'DEFAULT';
    $SIG{TERM} = 'DEFAULT';
    $0 .= " [$job]";

    # unblock signals
    sigprocmask(SIG_UNBLOCK, $sigset)
        or return error("Can't unblock SIGINT for fork: $!");

    # now call our job function
    my $class = MogileFS::ProcManager->job_to_class($job)
        or die "No worker class defined for job '$job'\n";
    my $worker = $class->new($childs_ipc);

    # set our frontend into child mode
    MogileFS::ProcManager->SetAsChild($worker);

    $worker->work;
    exit 0;
}

sub PendingQueryCount {
    return scalar @PendingQueries;
}

sub BoredQueryWorkerCount {
    return scalar @IdleQueryWorkers;
}

sub QueriesInProgressCount {
    return scalar keys %Mappings;
}

# Toss in any queue depths.
sub StatsHash {
    for my $job (keys %pending_work) {
        $Stats{'work_queue_for_' . $job} = @{$pending_work{$job}};
    }
    return \%Stats;
}

sub foreach_job {
    my ($class, $cb) = @_;
    foreach my $job (sort keys %ChildrenByJob) {
        my $ct = scalar(keys %{$ChildrenByJob{$job}});
        $cb->($job, $ct, $jobs{$job}->[0], [ join(' ', sort { $a <=> $b } keys %{$ChildrenByJob{$job}}) ]);
    }
}

sub foreach_pending_query {
    my ($class, $cb) = @_;
    foreach my $clq (@PendingQueries) {
        $cb->($clq->[0],  # client object,
              $clq->[1],  # "$ip $query"
              );
    }
}

sub is_monitor_good {
    return $monitor_good;
}

sub is_valid_job {
    my ($class, $job) = @_;
    return defined $jobs{$job};
}

sub valid_jobs {
    return sort keys %jobs;
}

sub request_job_process {
    my ($class, $job, $n) = @_;
    return 0 unless $class->is_valid_job($job);
    return 0 if ($job =~ /^(?:job_master|monitor)$/i && $n > 1); # ghetto special case

    $want_job_master = $n if ($job eq "job_master");

    $jobs{$job}->[0] = $n;
    $allkidsup = 0;

    # try to clean out the queryworkers (if that's what we're doing?)
    MogileFS::ProcManager->CullQueryWorkers
        if $job eq 'queryworker';

    # other workers listening off of a queue should be pinging parent
    # frequently. shouldn't explicitly kill them.
}


# when a child is spawned, they'll have copies of all the data from the
# parent, but they don't need it.  this method is called when you want
# to indicate that this procmanager is running on a child and should clean.
sub SetAsChild {
    my ($class, $worker) = @_;

    @IdleQueryWorkers = ();
    @PendingQueries = ();
    %Mappings = ();
    $IsChild = $worker;
    %ErrorsTo = ();
    %idle_workers = ();
    %pending_work = ();
    %ChildrenByJob = ();
    %child = ();
    %todie = ();
    %jobs = ();

    # we just forked from our parent process, also using Danga::Socket,
    # so we need to lose all that state and start afresh.
    Danga::Socket->Reset;
}

# called when a child has died.  a child is someone doing a job for us,
# but it might be a queryworker or any other type of job.  we just want
# to remove them from our list of children.  they're actually respawned
# by the make_new_child function elsewhere in Mgd.
sub NoteDeadChild {
    my $pid = $_[1];
    foreach my $job (keys %ChildrenByJob) {
        return if # bail out if we actually delete one
            delete $ChildrenByJob{$job}->{$pid};
    }
}

# called when a client dies.  clients are users, management or non.
# we just want to remove them from the error reporting interface, if
# they happen to be part of it.
sub NoteDeadClient {
    my $client = $_[1];
    delete $ErrorsTo{$client->{fd}};
}

# called when the error function in Mgd is called and we're in the parent,
# so it's pretty simple that basically we just spit it out to folks listening
# to errors
sub NoteError {
    return unless %ErrorsTo;

    my $msg = ":: ${$_[1]}\r\n";
    foreach my $client (values %ErrorsTo) {
        $client->write(\$msg);
    }
}

sub RemoveErrorWatcher {
    my ($class, $client) = @_;
    return delete $ErrorsTo{$client->{fd}};
}

sub AddErrorWatcher {
    my ($class, $client) = @_;
    $ErrorsTo{$client->{fd}} = $client;
}

# one-time initialization of a new worker connection
sub RegisterWorkerConn {
    my MogileFS::Connection::Worker $worker = $_[1];
    $worker->watch_read(1);

    #warn sprintf("Registering start-up of $worker (%s) [%d]\n", $worker->job, $worker->pid);

    # now do any special case startup
    if ($worker->job eq 'queryworker') {
        MogileFS::ProcManager->NoteIdleQueryWorker($worker);
    }

    # add to normal list
    $ChildrenByJob{$worker->job}->{$worker->pid} = $worker;

}

sub EnqueueCommandRequest {
    my ($class, $line, $client) = @_;
    push @PendingQueries, [
                           $client,
                           ($client->peer_ip_string || '0.0.0.0') . " $line"
                           ];
    MogileFS::ProcManager->ProcessQueues;
    if (@PendingQueries) {
        # Don't like the name. Feel free to change if you find better.
        $Stats{times_out_of_qworkers}++;
    }
}

# puts a worker back in the queue, deleting any outstanding jobs in
# the mapping list for this fd.
sub NoteIdleQueryWorker {
    # first arg is class, second is worker
    my MogileFS::Connection::Worker $worker = $_[1];
    delete $Mappings{$worker->{fd}};

    # see if we need to kill off some workers
    if (job_needs_reduction('queryworker')) {
        Mgd::error("Reducing queryworker headcount by 1.");
        MogileFS::ProcManager->AskWorkerToDie($worker);
        return;
    }

    # must be okay, so put it in the queue
    push @IdleQueryWorkers, $worker;
    MogileFS::ProcManager->ProcessQueues;
}

# if we need to kill off a worker, this function takes in the WorkerConn
# object, tells it to die, marks us as having requested its death, and decrements
# the count of running jobs.
sub AskWorkerToDie {
    my MogileFS::Connection::Worker $worker = $_[1];
    note_pending_death($worker->job, $worker->pid);
    $worker->write(":shutdown\r\n");
}

# kill bored query workers so we can get down to the level requested.  this
# continues killing until we run out of folks to kill.
sub CullQueryWorkers {
    while (@IdleQueryWorkers && job_needs_reduction('queryworker')) {
        my MogileFS::Connection::Worker $worker = shift @IdleQueryWorkers;
        MogileFS::ProcManager->AskWorkerToDie($worker);
    }
}

# called when we get a response from a worker.  this reenqueues the
# worker so it can handle another response as well as passes the answer
# back on to the client.
sub HandleQueryWorkerResponse {
    # got a response from a worker
    my MogileFS::Connection::Worker $worker;
    my $line;
    (undef, $worker, $line) = @_;

    return Mgd::error("ASSERT: ProcManager (Child) got worker response: $line") if $IsChild;
    return unless $worker && $Mappings{$worker->{fd}};

    # get the client we're working with (if any)
    my ($client, $jobstr, $starttime) = @{ $Mappings{$worker->{fd}} };

    # if we have no client, then we just got a standard message from
    # the queryworker and need to pass it up the line
    return MogileFS::ProcManager->HandleChildRequest($worker, $line) if !$client;

    # at this point it was a command response, but if the client has gone
    # away, just reenqueue this query worker
    return MogileFS::ProcManager->NoteIdleQueryWorker($worker) if $client->{closed};

    # <numeric id> [client-side time to complete] <response>
    my ($time, $id, $res);
    if ($line =~ /^(\d+-\d+)\s+(\-?\d+\.\d+)\s+(.+)$/) {
        # save time and response for use later
        # Note the optional negative sign in the regexp.  Somebody
        # on the mailing list was getting a time of -0.0000, causing
        # broken connections.
        ($id, $time, $res) = ($1, $2, $3);
    }

    # now, if it doesn't match
    unless ($id && $id eq "$worker->{pid}-$worker->{reqid}") {
        $id   = "<undef>" unless defined $id;
        $line = "<undef>" unless defined $line;
        $line =~ s/\n/\\n/g;
        $line =~ s/\r/\\r/g;
        Mgd::error("Worker responded with id $id (line: [$line]), but expected id $worker->{pid}-$worker->{reqid}, killing");
        $client->close('worker_mismatch');
        return MogileFS::ProcManager->AskWorkerToDie($worker);
    }

    # now time this interval and add to @RecentQueries
    my $tinterval = Time::HiRes::time() - $starttime;
    push @RecentQueries, sprintf("%s %.4f %s", $jobstr, $tinterval, $time);
    shift @RecentQueries if scalar(@RecentQueries) > 50;

    # send text to client, put worker back in queue
    $client->write("$res\r\n");
    MogileFS::ProcManager->NoteIdleQueryWorker($worker);
}

# new per-worker magic internal queue runner.
# TODO: Since this fires only when a master asks or a worker reports
# in bored, it should just operate on that *one* queue?
#
# new change: if worker in $job, but not in _bored, do not send work.
# if work is received, only delete from _bored
sub process_worker_queues {
    return if $IsChild;

    JOB: while (my ($job, $queue) = each %pending_work) {
        next JOB unless @$queue;
        next JOB unless $idle_workers{$job} && keys %{$idle_workers{$job}};
        WORKER: for my $worker_key (keys %{$idle_workers{$job}}) {
            my MogileFS::Connection::Worker $worker = 
                delete $idle_workers{_bored}->{$worker_key};
            if (!defined $worker || $worker->{closed}) {
                delete $idle_workers{$job}->{$worker_key};
                next WORKER;
            }

            # allow workers to grab a linear range of work.
            while (@$queue && $worker->wants_todo($job)) {
                $worker->write(":queue_todo $job " . shift(@$queue) . "\r\n");
                $Stats{'work_sent_to_' . $job}++;
            }
            next JOB unless @$queue;
        }
    }
}

# called from various spots to empty the queues of available pairs.
sub ProcessQueues {
    return if $IsChild;

    # try to match up a client with a worker
    while (@IdleQueryWorkers && @PendingQueries) {
        # get client that isn't closed
        my $clref;
        while (!$clref && @PendingQueries) {
            $clref = shift @PendingQueries
                or next;
            if ($clref->[0]->{closed}) {
                $clref = undef;
                next;
            }
        }
        next unless $clref;

        # get worker and make sure it's not closed already
        my MogileFS::Connection::Worker $worker = pop @IdleQueryWorkers;
        if (!defined $worker || $worker->{closed}) {
            unshift @PendingQueries, $clref;
            next;
        }

        # put in mapping and send data to worker
        push @$clref, Time::HiRes::time();
        $Mappings{$worker->{fd}} = $clref;
        $Stats{queries}++;

        # increment our counter so we know what request counter this is going out
        $worker->{reqid}++;
        # so we're writing a string of the form:
        #     123-455 10.2.3.123 get_paths foo=bar&blah=bar\r\n
        $worker->write("$worker->{pid}-$worker->{reqid} $clref->[1]\r\n");
    }
}

# send short descriptions of commands we support to the user
sub SendHelp {
    my $client = $_[1];

    # send general purpose help
    $client->write(<<HELP);
Mogilefsd admin commands:

    !version    Server version
    !recent     Recently executed queries and how long they took.
    !queue      Queries that are pending execution.
    !stats      General stats on what we\'re up to.
    !watch      Observe errors/messages from children.
    !jobs       Outstanding job counts, desired level, and pids.
    !shutdown   Immediately kill all of mogilefsd.

    !to <job class> <message>
                Send <message> to all workers of <job class>.
                Mostly used for debugging.

    !want <count> <job class>
                Alter the level of workers of this class desired.
                Example: !want 20 queryworker, !want 3 replicate.
                See !jobs for what jobs are available.

HELP

}

# a child has contacted us with some command/status/something.
sub HandleChildRequest {
    if ($IsChild) {
        Mgd::fatal("ASSERT: child $_[2] shouldn't be getting requests from other children");
    }

    # if they have no job set, then their first line is what job they are
    # and not a command.  they also specify their pid, just so we know what
    # connection goes with what pid, in case it's ever useful information.
    my MogileFS::Connection::Worker $child = $_[1];
    my $cmd = $_[2];

    die "Child $child with no pid?" unless $child->job;

    # at this point we've got a command of some sort
    if ($cmd =~ /^error (.+)$/i) {
        # pass it on to our error handler, prefaced with the child's job
        Mgd::error("[" . $child->job . "(" . $child->pid . ")] $1");

    } elsif ($cmd =~ /^debug (.+)$/i) {
        # pass it on to our error handler, prefaced with the child's job
        Mgd::debug("[" . $child->job . "(" . $child->pid . ")] $1");

    } elsif ($cmd =~ /^queue_depth (\w+)/) {
        my $job   = $1;
        if ($job eq 'all') {
            for my $qname (keys %pending_work) {
                my $depth = @{$pending_work{$qname}};
                $child->write(":queue_depth $qname $depth\r\n");
            }
        } else {
            my $depth = 0;
            if ($pending_work{$job}) {
                $depth = @{$pending_work{$job}};
            }
            $child->write(":queue_depth $job $depth\r\n");
        }
        MogileFS::ProcManager->process_worker_queues;
    } elsif ($cmd =~ /^queue_todo (\w+) (.+)/) {
        my $job = $1;
        $pending_work{$job} ||= [];
        push(@{$pending_work{$job}}, $2);
        # Don't process queues immediately, to allow batch processing.
    } elsif ($cmd =~ /^worker_bored (\d+) (.+)/) {
        my $batch = $1;
        my $types = $2;
        if (job_needs_reduction($child->job)) {
            MogileFS::ProcManager->AskWorkerToDie($child);
        } else {
            unless (exists $idle_workers{$child->job}) {
                $idle_workers{$child->job} = {};
            }
            $idle_workers{_bored} ||= {};
            $idle_workers{_bored}->{$child} = $child;
            for my $type (split(/\s+/, $types)) {
                $idle_workers{$type} ||= {};
                $idle_workers{$type}->{$child}++;
                $child->wants_todo($type, $batch);
            }
            MogileFS::ProcManager->process_worker_queues;
        }
    } elsif ($cmd eq ":ping") {

        # warn sprintf("Job '%s' with pid %d is still alive at %d\n", $child->job, $child->pid, time());

        # this command expects a reply, either to die or stay alive.  beginning of worker's loops
        if (job_needs_reduction($child->job)) {
            MogileFS::ProcManager->AskWorkerToDie($child);
        } else {
            $child->write(":stay_alive\r\n");
        }

    } elsif ($cmd eq ":still_alive") {
        # a no-op

    } elsif ($cmd =~ /^:monitor_events/) {
        # Apply the state locally, so when we fork children they have a
        # pre-parsed factory.
        # We do not replay the events back to where it came, since this
        # severely impacts startup performance for instances with several
        # thousand domains, classes, hosts or devices.
        apply_state_events(\$cmd);
        MogileFS::ProcManager->send_to_all_children($cmd, $child);

    } elsif ($cmd eq ":monitor_just_ran") {
        send_monitor_has_run($child);

    } elsif ($cmd =~ /^:wake_a (\w+)$/) {

        MogileFS::ProcManager->wake_a($1, $child);
    } elsif ($cmd =~ /^:set_config_from_child (\S+) (.+)/) {
        # and this will rebroadcast it to all other children
        # (including the one that just set it to us, but eh)
        MogileFS::Config->set_config($1, $2);
    } elsif ($cmd =~ /^:refresh_monitor$/) {
        MogileFS::ProcManager->ImmediateSendToChildrenByJob("monitor", $cmd);
    } else {
        # unknown command
        my $show = $cmd;
        $show = substr($show, 0, 80) . "..." if length $cmd > 80;
        Mgd::error("Unknown command [$show] from child; job=" . $child->job);
    }
}

# Class method.
#   ProcManager->ImmediateSendToChildrenByJob($class, $message, [ $child ])
# given a job class, and a message, send it to all children of that job.  returns
# the number of children the message was sent to.
#
# if child is specified, the message will be sent to members of the job class that
# aren't that child.  so you can exclude the one that originated the message.
#
# doesn't add to queue of things child gets on next interactive command: writes immediately
# (won't get in middle of partial write, though, as danga::socket queues things up)
#
# if $just_one is specified, only a single process is notified, then we stop.
sub ImmediateSendToChildrenByJob {
    my ($pkg, $class, $msg, $exclude_child, $just_one) = @_;

    my $childref = $ChildrenByJob{$class};
    return 0 unless defined $childref && %$childref;

    foreach my $child (values %$childref) {
        # ignore the child specified as the third arg if one is sent
        next if $exclude_child && $exclude_child == $child;

        # send the message to this child
        $child->write("$msg\r\n");
        return 1 if $just_one;
    }
    return scalar(keys %$childref);
}

# called when we notice that a worker has bit it.  we might have to restart a
# job that they had been working on.
sub NoteDeadWorkerConn {
    return if $IsChild;

    # get parms and error check
    my MogileFS::Connection::Worker $worker = $_[1];
    return unless $worker;

    my $fd = $worker->{fd};
    return unless defined($fd);

    # if there's a mapping for this worker's fd, they had a job that didn't get done
    if ($Mappings{$fd}) {
        # unshift, since this one already went through the queue once
        unshift @PendingQueries, $Mappings{$worker->{fd}};
        delete $Mappings{$worker->{fd}};

        # now try to get it processing again
        MogileFS::ProcManager->ProcessQueues;
    }
}

# given (job, pid), record that this worker is about to die
# $level is so we can tell if watchdog requested the death.
sub note_pending_death {
    my ($job, $pid, $level) = @_;

    die "$job not defined in call to note_pending_death.\n"
        unless defined $jobs{$job};

    $level ||= 1;
    # don't double decrement.
    $jobs{$job}->[1]-- unless $todie{$pid};
    $todie{$pid} = $level;
}

# see if we should reduce the number of active children
sub job_needs_reduction {
    my $job = shift;
    my $q;

    # drop job_master-dependent workers if there is no job_master and no
    # previously queued work
    if (!$want_job_master && $needs_job_master{$job}
            && $jobs{job_master}->[1] == 0 # check if job_master is really dead
            && (($q = $pending_work{$job}) && !@$q || !$q)) {
        return 1;
    }

    return $jobs{$job}->[0] < $jobs{$job}->[1];
}

sub is_child {
    return $IsChild;
}

sub wake_a {
    my ($pkg, $class, $fromchild) = @_;  # from arg is optional (which child sent it)
    my $child = MogileFS::ProcManager->is_child;
    if ($child) {
        $child->wake_a($class);
    } else {
        MogileFS::ProcManager->ImmediateSendToChildrenByJob($class, ":wake_up", $fromchild, "just_one");
    }
}

sub send_to_all_children {
    my ($pkg, $msg, $exclude) = @_;
    foreach my $child (values %child) {
        next if $exclude && $child == $exclude;
        $child->write($msg . "\r\n");
    }
}

sub send_monitor_has_run {
    my $child = shift;
    # Gas up other workers if monitor's completed for the first time.
    if (! $monitor_good) {
        MogileFS::ProcManager->set_min_workers('queryworker' => MogileFS->config('query_jobs'));
        MogileFS::ProcManager->set_min_workers('delete'      => MogileFS->config('delete_jobs'));
        MogileFS::ProcManager->set_min_workers('replicate'   => MogileFS->config('replicate_jobs'));
        MogileFS::ProcManager->set_min_workers('reaper'      => MogileFS->config('reaper_jobs'));
        MogileFS::ProcManager->set_min_workers('fsck'        => MogileFS->config('fsck_jobs'));

        # only one job_master at most
        $want_job_master = !!MogileFS->config('job_master');
        MogileFS::ProcManager->set_min_workers('job_master'  => $want_job_master);

        $monitor_good = 1;
        $allkidsup    = 0;
    }
    for my $type (qw(queryworker)) {
        MogileFS::ProcManager->ImmediateSendToChildrenByJob($type, ":monitor_has_run", $child);
    }
}

1;

# Local Variables:
# mode: perl
# c-basic-indent: 4
# indent-tabs-mode: nil
# End:

#!/usr/bin/perl
#
#   Perl Makefile for MogileFS
#   $Id$
#
#   Invoke with 'perl Makefile.PL'
#
#   See ExtUtils::MakeMaker (3) for more information on how to influence
#    the contents of the Makefile that is written
#

use ExtUtils::MakeMaker;

my $exefiles = ["mogstored", "mogilefsd", "mogdbsetup", "mogautomount"];
$exefiles = ["mogstored"] if exists $ENV{DANGABUILD_MOGSTOREDONLY};
$exefiles = ["mogilefsd"] if exists $ENV{DANGABUILD_MOGILEFSDONLY};

WriteMakefile(
    NAME                    => 'MogileFS::Server',
    VERSION_FROM            => 'lib/MogileFS/Server.pm',
    AUTHOR                  => 'Brad Fitzpatrick <brad@danga.com>',
    ABSTRACT_FROM           => 'lib/MogileFS/Server.pm',
    EXE_FILES               => $exefiles,
    PREREQ_PM               => {
        'Danga::Socket'    => '1.56',
        'Perlbal'          => '1.79',
        'Sys::Syslog'      => 0,
        'Sys::Syscall'     => '0.22',
        'Getopt::Long'     => 0,
        'Symbol'           => 0,
        'Net::Netmask'     => 0,
        'Net::Patricia'    => 0,
        fields            => 0,
        'IO::AIO'         => 0,
        'MogileFS::Client' => 0,
        DBI                => 0,
        'Test::More'        => 0.88,    # 0.88 for done_testing() support
    },
    META_MERGE              => {
        no_index => {
            package   => ['ProcessHandle', 'TrackerHandle', 'MogstoredHandle',
            'MogPath', 'Mgd'],
        },
          resources => {
            homepage    =>      'http://www.mogilefs.org',
            bugtracker  =>      'http://code.google.com/p/mogilefs/issues/list',
            repository  =>      'git://github.com/mogilefs/MogileFS-Server.git',
            MailingList =>      'http://groups.google.com/group/mogile',
        },

    },
);


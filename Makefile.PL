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
        'Perlbal'          => '1.76',
        'Sys::Syslog'      => 0,
        'Sys::Syscall'     => '0.22',
        'Getopt::Long'     => 0,
        'Symbol'           => 0,
        'Net::Netmask'     => 0,
        fields            => 0,
        'IO::AIO'         => 0,
        'MogileFS::Client' => 0,
        DBI                => 0,
    },
    META_MERGE              => {
        no_index => {
            directory => 'lib/mogdeps',
            package   => ['ProcessHandle', 'TrackerHandle', 'MogstoredHandle',
            'MogPath', 'Mgd'],
        },
          resources => {
            homepage    =>      'http://danga.com/mogilefs/',
            bugtracker  =>      'http://rt.cpan.org/Public/Dist/Display.html?Name=mogilefs-server',
            repository  =>      'git://github.com/mogilefs/MogileFS-Server.git',
            MailingList =>      'http://groups.google.com/group/mogile',
        },

    },
);


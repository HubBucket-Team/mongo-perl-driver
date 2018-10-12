#!/usr/bin/env perl
#
#  Copyright 2017 - present MongoDB, Inc.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

use v5.10;
use strict;
use warnings;
use Config;
use Cwd 'getcwd';
use File::Path qw/mkpath rmtree/;

# Get helpers
use FindBin qw($Bin);
use lib "$Bin/../lib";
use EvergreenHelper;

# constants

my $orig_dir      = getcwd();
my $root          = "opt";
my $prefix_prefix = "/$root/perl";
my $destdir       = "$orig_dir/build";
my @default_args  = ( '-j', 16, '-Doptimize=-g' );
my $tardir        = "$destdir/$root";

# define matrix of builds

my @perl_versions = qw(
  5.10.1
  5.12.5
  5.14.4
  5.16.3
  5.18.4
  5.20.3
  5.22.4
  5.24.4
  5.26.2
  5.28.0
);

# Build only more recent Perls for ZAP.  Debian/Ubuntu set a custom
# archname with "powerpc64le" instead of Perl standard "ppc64le" so
# we check both.
if ( $Config{archname} =~ /aarch64|s390x|ppc64le|powerpc64le/ ) {
    splice @perl_versions, 0, 3;
}

my %config_flags = (
    ''  => '',
    't' => '-Dusethreads',
    'ld' => '-Dusemorebits',
);

# Bootstrap

bootstrap_env();

# Install Perl::Build

run_perl5_cpanm(qw/Perl::Build/);

# build all perls from newest to oldest because older ones might fail
# and we want to see where things stop working
my @logs;
for my $version (reverse @perl_versions) {
    for my $config ( keys %config_flags ) {
        # prepare arguments
        my ($short_ver) = $version =~ m/^5\.(\d+)\.\d+$/;
        my $dest = "$prefix_prefix/$short_ver$config";
        my @args = ( @default_args, $version, $dest );
        unshift @args, $config_flags{$config} if length $config_flags{$config};

        # run perl-build
        local $ENV{DESTDIR} = $destdir;
        my $logfile = "$short_ver$config.log";
        push @logs, $logfile;
        eval { try_system("perl-build @args >$logfile 2>&1") };
        if ( $@ ) {
            # try again without parallel builds
            my @linear_args = ( '-Doptimize=-g', $version, $dest );
            (my $log2 = $logfile) =~ s/\.log/-2.log/;
            eval { try_system("perl-build @linear_args >$log2 2>&1") };
            if ( $@ ) {
                # tar the build logs so we have a record of the error
                try_system("tar -czf task-logs.tar.gz @logs");
                die $@
            }
        }

        # remove man dirs from $destdir$dest/...
        rmtree("$destdir$dest/man");

        # remove most pod files
        my $poddir = "$destdir$dest/lib/$version/pod";
        opendir my $dh, $poddir or die $!;
        my @files = grep { substr( $_, 0, 1 ) ne '.' } readdir($dh);
        for my $file (@files) {
            next if $file eq "perldiag.pod";
            my $fullpath = "$poddir/$file";
            unlink $fullpath or die "While deleting '$fullpath': $!";
        }
    }
}

# tar inside the destdir/opt
try_system("tar -czf perl.tar.gz -C $tardir perl");

# tar the build logs
try_system("tar -czf task-logs.tar.gz @logs");

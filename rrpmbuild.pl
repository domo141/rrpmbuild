#!/usr/bin/perl
#-*- mode: cperl; cperl-indent-level: 4; cperl-continued-brace-offset: -2 -*-

# This file is part of MADDE
#
# Copyright (C) 2010 Nokia Corporation and/or its subsidiary(-ies).
# Copyright (C) 2013-2024 Tomi Ollila <tomi.ollila@iki.fi>
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public License
# version 2.1 as published by the Free Software Foundation.
#
# This library is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA
# 02110-1301 USA

use strict;
use warnings;

use Fcntl ':mode';
use File::Find;

use Digest;

# So far, this is proof-of-concept implementation (read: terrible hack).
# Even some mentioned features do not work... and tested only on linux
# with perl 5.10.x // 2010-06-10 too

# Welcome to the source of 'restricted' rpmbuild. The 'restrictions' are:
#  does not check things that "real" rpm does (e.g. no binaries in noarch pkg)
#  does not recurse! (some is easy to add (and even full recursion))
#  no fancy variables
#  a set of %macros just not supported
#  only binary rpms (-bs probably does not work too well...)
#  only -bb now, more -b -options later (if ever). some --:s too...

# bottom line: the spec files that rrpmbuild can build, may also be buildable
# with standard rpm, but not necessarily wise versa.

# from rpm-4.8.0/rpmrc.in (aarch64 from rpm-4.19.1.1/rpmrc.in)

my %arch_canon = ( noarch => 1, # rpmpeek()ed (hmm some have 1, some 255 :O)
		   i686 => 1, i586 => 1, i486 => 1, i386 => 1, x86_64 => 1,
		   armv3l => 12, armv4b => 12, armv4l => 12, armv5tel => 12,
		   armv5tejl => 12, armv6l => 12, armv7l => 12, armv7hl => 12,
		   armv7nhl => 12, arm => 12, aarch64 => 19 );

my %os_canon = ( Linux => 1 );

# packages array defines order for packages + other hashes.
my @pkgnames = ('');
my %packages = ('', [ [ ], { } ] );


my (@prep, @build, @install, @clean);
my (%description, %files);
my (%pre, %post, %preun, %postun);
my @changelog;

sub usage()
{
    die "Usage: $0 [--rpmdir=DIR] [--buildtime=SECS] [--buildhost=HOSTNAME] (-bb|-bs) SPECFILE\n";
}

my ($specfile, $building_src_pkg, $rpmdir, $buildtime, $buildhost);

while (@ARGV > 0) {
    $_ = shift @ARGV;
    if ($_ eq '-bb') {
	die "Build option chosen already\n" if defined $building_src_pkg;
	$building_src_pkg = 0;
	next;
    }
    if ($_ eq '-bs') {
	die "Build option chosen already\n" if defined $building_src_pkg;
	$building_src_pkg = 1;
	next;
    }
    if ($_ =~ /--rpmdir=(.*)/) {
	die "Rpmdir chosen already\n" if defined $rpmdir;
	$rpmdir = $1;
	next;
    }
    if ($_ eq '--rpmdir') {
	die "Rpmdir chosen already\n" if defined $rpmdir;
	die "$0: option '--rpmdir' requires an argument\n" unless @ARGV > 0;
	$rpmdir = shift @ARGV;
	next;
    }
    if ($_ =~ /--buildhost=(.*)/) {
	die "Buildhost chosen already\n" if defined $buildhost;
	$buildhost = $1;
	next;
    }
    if ($_ eq '--buildhost') {
	die "Buildhost chosen already\n" if defined $buildhost;
	die "$0: option '--buildhost' requires an argument\n" unless @ARGV > 0;
	$buildhost = shift @ARGV;
	next;
    }
    $specfile = $_;
    last;
}

my $sde = $ENV{SOURCE_DATE_EPOCH} // '';
$buildtime = ($sde ne '')? $sde + 0: time;

use Net::Domain ();
$buildhost = Net::Domain::hostname unless defined $buildhost;

usage unless defined $building_src_pkg;

die "$0: missing specfile\n" unless defined $specfile;
die "$0: too many arguments\n" if @ARGV > 0;

$rpmdir = 'rrpmbuild' unless defined $rpmdir;

my %macros;
sub init_macros()
{
    my ($prefix, $exec_prefix, $lib) = ( '/usr', '/usr', 'lib' );

    %macros = ( _prefix => $prefix,
		_exec_prefix => $exec_prefix,
		_exec_prefix => $exec_prefix,
		_bindir => $exec_prefix . '/bin',
		_sbindir => $exec_prefix . '/sbin',
		_libexecdir => $exec_prefix . '/libexec',
		_datadir => $prefix . '/share',
		_sysconfdir => $prefix . '/etc',
		_sharedstatedir => $prefix . '/com',
		_localstatedir => $prefix . '/var',
		_lib => $lib,
		_libdir => $exec_prefix . '/' . $lib,
		_includedir => $prefix . '/include',
		_oldincludedir => '/usr/include',
		_infodir => $prefix . '/info',
		_mandir => $prefix . '/man',

		setup => 'echo no %prep' );
}

my $instroot = $building_src_pkg? '.': "$rpmdir/instroot";
my $instrlen = length $instroot;

$ENV{'RPM_BUILD_ROOT'} = $instroot;
$ENV{'RPM_OPT_FLAGS'} = '-O2';
#$ENV{''} = '';
#$ENV{''} = '';

sub rest_macros()
{
    sub NL() { "\n"; }
    $macros{'buildroot'} = $ENV{'RPM_BUILD_ROOT'};
    $macros{'makeinstall'} = eval_macros ( 'make install \\' . NL .
		'  prefix=%{buildroot}/%{_prefix} \\' . NL .
		'  exec_prefix=%{buildroot}/%{_exec_prefix} \\' . NL .
		'  bindir=%{buildroot}/%{_bindir} \\' . NL .
		'  sbindir=%{buildroot}/%{_sbindir} \\' . NL .
		'  sysconfdir=%{buildroot}/%{_sysconfdir} \\' . NL .
		'  datadir=%{buildroot}/%{_datadir} \\' . NL .
		'  includedir=%{buildroot}/%{_includedir} \\' . NL .
		'  libdir=%{buildroot}/%{_libdir} \\' . NL .
		'  libexecdir=%{buildroot}/%{_libexecdir} \\' . NL .
		'  localstatedir=%{buildroot}/%{_localstatedir} \\' . NL .
		'  sharedstatedir=%{buildroot}/%{_sharedstatedir} \\' . NL .
		'  mandir=%{buildroot}/%{_mandir} \\' . NL .
		'  infodir=%{buildroot}/%{_infodir}'
	      ) unless defined $macros{'makeinstall'};
}

my %stanzas = ( package => 1, description => 1, changelog => 1,
		prep => 1, build => 1, install => 1, clean => 1,
		files => 1, pre => 1, post => 1, preun => 1, postun => 1 );
sub readspec()
{
    sub eval_macros($)
    {
	my ($m, $rest) = split '#', $_[0], 2;

	sub _eval_it() {
	    return '%' if $1 eq '%';
	    return $macros{$1} if defined $macros{$1};
	    die "'$1': undefined macro\n";
	}

	#    s/%%/\001/g;
	# dont be too picky if var is in format %{foo or %foo} ;) (i.e fix ltr)
	$m =~ s/%\{?(%|[\w\?\!]+)\}?/_eval_it/ge;
	#    s/\001/%/g;
	return $m . '#' . $rest if (defined $rest);
	return $m;
    }

    sub readpackage($)
    {
	my ($arref, $hashref) = ($_[0]->[0], $_[0]->[1]);

	while (<I>) {
	    s/#.*//;
	    next if /^\s*$/;
	    if (/^\s*%define\s+(\S+)\s+(.*?)\s*$/) {
		$macros{$1} = eval_macros $2;
		next;
	    }
	    last if /^\s*%/;
	    if (/^\s*(\S+?)\s*:\s*(.*?)\s+$/) {
		my ($K, $key) = ($1, lc $1);
		my $val = $hashref->{$key};
		if (defined $val) {
		    $val = $val . ', ' . eval_macros $2;
		}
		else {
		    push @$arref, $key;
		    $val = eval_macros $2;
		}
		$hashref->{$key} = $val;
		# Add format checks, too...
		if ($key eq 'name' || $key eq 'version' || $key eq 'release') {
		    die "error: line $.: Tag takes single token only: $K: $val\n"
		      if $val =~ /\s/;
		    $macros{$key} = $val
		}
		# build files for source package
		if ($building_src_pkg && $key =~ /(source|patch)[0-9]+/) {
		    push @{ $files{''} }, $val;
		}
		next;
	    }
	    chomp;
	    die "'$_': unknown header format\n";
	}
    }

    sub readlines($)
    {
	while (<I>) {
	    return if /^\s*%(\S+)/ && defined $stanzas{$1};
	    push @{$_[0]}, eval_macros $_;
	}
    }

    sub readlines2string($)
    {
	my @list;
	readlines \@list;
	$_[0] = join '', @list;
	$_[0] =~ s/\s*$//;
    }

    sub readfiles($)
    {
	# doing stuff to catch more errors early, i.e. not after build
	# if these lines were just listed and all scanning done after

	$macros{$_} = "\001$_\001" foreach (qw/defattr attr doc dir config/);
	delete $macros{'docdir'}; delete $macros{'verify'};

	# xxx later may check format of defattr and attr...
	readlines $_[0];

	delete $macros{$_} foreach (qw/defattr attr doc dir config/);
    }

    sub readignore($)
    {
	while (<I>) {
	    return if /^\s*%(\S+)/ && defined $stanzas{$1};
	}
    }

    readpackage ($packages{''});
    rest_macros; # XXX
    while (1) {
	chomp, die "'$_': unsupported stanza format.\n"
	  unless /^\s*%(\w+)\s*(\S*?)\s*$/;

	if ($1 eq 'package') {
	    push @pkgnames, $2 if ! $building_src_pkg;
	    #we need to consume the spec file even when building source package
	    readpackage ($packages{$2} = [ [ ], { } ]);
	}
	elsif ($1 eq 'description') { readlines ($description{$2} = [ ]); }

	elsif ($1 eq 'prep') {    readignore \@prep; }
	elsif ($1 eq 'build') {   readlines \@build; }
	elsif ($1 eq 'install') { readlines \@install; }
	elsif ($1 eq 'clean') {   readlines \@clean; }

	elsif ($1 eq 'files') {
	    if ($building_src_pkg) {
		readfiles ([ ]);
	    }
	    else {
		readfiles ($files{$2} = [ ]);
	    }
	}

	elsif ($1 eq 'pre') { readlines2string $pre{$2}; }
	elsif ($1 eq 'post') { readlines2string $post{$2}; }
	elsif ($1 eq 'preun') { readlines2string $preun{$2}; }
	elsif ($1 eq 'postun') { readlines2string $postun{$2}; }

	elsif ($1 eq 'changelog') { readlines \@changelog; }

	else { chomp; die "'$1': unsupported stanza macro.\n"; }
	last if eof I;
    };
}

init_macros;
open I, '<', $specfile or die "Cannot open '$specfile': $!\n";
readspec;
close I;

push @{ $files{''} }, $specfile if $building_src_pkg;

foreach (qw/name version release/) {
    die "Package $_ not known\n" unless (defined $macros{$_});
}
#rest_macros; # moved above for now. smarter variable expansion coming later.

# XXX check what must be in "sub" packages (hmm maeby out-of-scope)
foreach (qw/license summary buildarch/) {
    die "Package $_ not known\n" unless (defined $packages{''}->[1]->{$_});
}

# XXX expect user to know how to cross-compile if that is the case
#my ($target_os, $target_arch) = split /\s+/, qx/uname -m -s/;
my ($target_os, $target_arch) = ('Linux', $packages{''}->[1]->{buildarch});
my $os_canon = $os_canon{$target_os};
my $arch_canon = $arch_canon{$target_arch};

die "'$target_os': unknown os\n" unless defined $os_canon;
die "'$target_arch': unknown arch\n" unless defined $arch_canon;


# check that we have description and files for all packages
# description and/or files sections that do not have packages
# are just ignored (should we care ?=

foreach (@pkgnames) {
    die "No 'description' section for package '$_'\n"
      unless defined $description{$_};
    die "No 'files' section for package '$_'\n"
      unless defined $files{$_};
}

sub execute_stage($$)
{
    print "Executing: %$_[0]\n";
    system('/bin/sh', '-euxc', $_[1]);
    if ($?) {
	my $ev = $? >> 8;
	die "$_[0] exited with nonzero exit code ($ev)\n";
    }
}

#skip prep ## and fix...
#execute_stage 'clean', join '', @clean;
if (! $building_src_pkg) {
    execute_stage 'build', join '', @build;
    mkdir $rpmdir;
    execute_stage 'install', join '', @install;
}

my ($ino, $cpio_dsize);
sub open_cpio_file($)
{
    open STDOUT, '>', $_[0] or die "Open $_[0] failed: $!\n";
    $ino = 1;
    $cpio_dsize = 0;
}

# knows files & directories.
sub file_to_cpio($$$)
{
    my ($name, $mode, $file) = @_;
    my ($size, $mtime, $nlink);

    if (defined $file) {
	my @sb = stat $file or die "stat '$file': $!\n";
	$mtime = ($sde eq '')? $sb[9]: $buildtime;
	if (S_ISDIR($sb[2])) {
	    $size = 0; $mode += 0040000; $nlink = 2;
	}
	else { $size = $sb[7]; $mode += 0100000; $nlink = 1; }
    }
    else { $mtime = 0; $size = 0; $mode = 0; $nlink = 1; }

    my $namesize = length($name) + 1;
    my $hdrbytes = 110 + $namesize;
    $hdrbytes += 4 - ($hdrbytes & 0x03) if ($hdrbytes & 0x03);
    # Type: New ASCII without crc (070701). See librachive/cpio.5
    syswrite STDOUT, sprintf
      ("070701%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x%08x00000000%s\000\000\000\000", $ino, $mode,0,0, $nlink, $mtime, $size, 0,0,0,0, $namesize, $name),
	$hdrbytes;

    $cpio_dsize += $size, system ('/bin/cat', $file) if $size;
    if ($size & 0x03) {
	syswrite STDOUT, "\000\000\000", 4 - ($size & 0x03);
    }
    return ($mode, $size, $mtime);# if wantarray;
}

sub close_cpio_file()
{
    $ino = 0;
    file_to_cpio('TRAILER!!!', 0, undef);
    # not making size multiple of 512 (as doesn't rpm do either).
    open STDOUT, ">&STDERR" or die;
}

sub xfork()
{
    my $pid = fork();
    die "fork() failed: $!\n" unless defined $pid;
    return $pid;
}

sub xpIopen(@)
{
    pipe I, WRITE or die "pipe() failed: $!\n";
    if (xfork) {
	# parent;
	close WRITE;
	return;
    }
    # child
    my $dir = shift;
    close I;
    open STDOUT, ">&WRITE" or die "dup2() failed: $!\n";
    if ($dir) {
	chdir $dir or die "chdir failed: $!\n";
    }
    exec @_;
    die "execve() failed: $!\n";
}
sub xpIclose()
{
    close I;
    return wait;
}


# fill arrays, make cpio
foreach (@pkgnames)
{
    # Declare variables, to be dynamically scoped using local below.
    our ($fmode, $dmode, $uname, $gname, $havedoc);
    our ($wdir, $pkgname, $swname, $npkg, $rpmname, @filelist);

    # Use local instead of my -- the failure w/ my is a small mystery to me.
    local ($fmode, $dmode, $uname, $gname, $havedoc);
    local ($wdir, $pkgname, $swname, $npkg, $rpmname, @filelist);

    #warn 'XXXX 1 ', \@filelist, "\n"; # see also XXXX 2 & XXXX 3

    sub addocfile($) {
	#if (/\*/)...
	# XXX pkgname has ${release}...
	warn "Adding doc file $_[0]\n";
	my $dname = "usr/share/doc/$swname";
	unless (defined $havedoc) {
	    push @filelist, [ $dname, $dmode, $uname, $gname, '.' ];
	    $havedoc = 1;
	}
	my $fname = $dname . '/' . $_[0];
	push @filelist, [ $fname, $fmode, $uname, $gname, $_[0] ];
    }

    my @_flist;
    sub _addfile($$);
    sub _addfile($$)
    {
	if (-d "$instroot/$_[0]") {
	    warn "Adding directory $_[0]\n";

	    push @filelist,
	      [ $_[0], $dmode, $uname, $gname, "$instroot/$_[0]" ];

	    return if $_[1];
	    sub _f() { push @_flist, (substr $_, $instrlen + 1); }
	    @_flist = ();
	    find({wanted =>\&_f, no_chdir => 1}, "$instroot/$_[0]");
	    shift @_flist;
	    _addfile($_, 1) foreach ( @_flist ); # sorted later.
	    #_addfile($_, 1) foreach ( sort @_flist );
	    return;
	}
	warn "Adding file $_[0]\n";
	push @filelist,
	  [ $_[0], $fmode, $uname, $gname, "$instroot/$_[0]" ];
	#warn 'XXXX 2 ', \@filelist, ' ', "@filelist", "\n";
    }
    sub addfile($$) # file, isdir
    {
	my $f = $_[0];
	if (/\*/) {
	    foreach ( glob "$instroot/$f" ) {
		_addfile substr($_, $instrlen + 1), $_[1];
	    }
	    return;
	}
	_addfile $f, $_[1];
    }

    $npkg = $_;
    if (length $npkg) {
	$rpmname = "$macros{name}-$npkg";
    }
    else {
	$rpmname = $macros{name};
    }
    $swname = "$rpmname-$macros{version}";
    if ($building_src_pkg) {
	$pkgname = "$swname-$macros{release}.src";
    }
    else {
	$pkgname = "$swname-$macros{release}.$target_arch";
    }

    warn "Creating package $pkgname.rpm\n";

    my ($deffmode, $defdmode, $defuname, $defgname) = qw/-1 -1 root root/;

    LINE: foreach (@{$files{$npkg}}) {
	($fmode, $dmode, $uname, $gname) = ($deffmode, $defdmode, $defuname, $defgname);
	my ($isdir, $isconfig, $isdoc) = (0, 0, 0);
	while (1) {
	    if (s/\001(def)?attr\001\((.+?)\)//) {
		my @attrs = split /\s*,\s*/, $2;

		$fmode = $attrs[0] if defined $attrs[0];
		$uname = $attrs[1] if defined $attrs[1];
		$gname = $attrs[2] if defined $attrs[2];
		my $ndmode;
		$ndmode = $attrs[3] if defined $attrs[3];
		# XXX should check that are numeric and in right range.
		$fmode = $fmode eq '-'? -1: oct $fmode;
		$dmode = ($ndmode eq '-'? -1: oct $ndmode) if defined $ndmode;
		($deffmode, $defdmode, $defuname, $defgname)
		  = ($fmode, $dmode, $uname, $gname) if defined $1;
		next;
	    }
	    $isdir = 1, next if s/\001dir\001//;
	    $isconfig = 1, next if s/\001config\001//;
	    # last, as slurps end of line (won't do better! ambiquous if.)
	    if (s/\001doc\001//) {
		$isdoc = 1;
		foreach (split /\s+/) {
		    addocfile $_ if length $_;
		}
		next LINE;
	    }
	    last;
	}

	# XXX add check must start with / (and allow whitespaces (maybe))
	if ($building_src_pkg) {
	    addfile $1, $isdir if /^\s*(\S+?)\/*\s*$/; # XXX no whitespace in filenames
	}
	else {
	    addfile $1, $isdir if /^\s*\/+(\S+?)\/*\s+$/; # XXX no whitespace in filenames
	}
    }

    # Ditto.
    our (@files, @dirindexes, @dirs, %dirs, @modes, @sizes, @mtimes);
    our (@unames, @gnames, @md5sums);
    local (@files, @dirindexes, @dirs, %dirs, @modes, @sizes, @mtimes);
    local (@unames, @gnames, @md5sums);
    sub add2lists($$$$$$$)
    {
	sub getmd5sum($)
	{
	    my $ctx = Digest->new('MD5');
	    open J, '<', $_[0] or die $!;
	    $ctx->addfile(*J);
	    close J;
	    return $ctx->hexdigest;
	}

	$_[0] =~ m%((.*/)?)(.+)% or die "'$_[0]': invalid path\n";
	my ($dir, $base) = (($building_src_pkg? '': '/') . $1, $3);
	my $di = $dirs{$dir};
	unless (defined $di) {
	    $di = $dirs{$dir} = scalar @dirs;
	    push @dirs, $dir;
	}
	push @files, $base;
	push @dirindexes, $di;

	push @modes, $_[1];
	push @sizes, $_[2];
	push @mtimes, $_[3];
	push @unames, $_[4];
	push @gnames, $_[5];
	if (-f $_[6]) {
	    push @md5sums, getmd5sum $_[6];
	}
	else { push @md5sums, ''; }
    }

    #warn 'XXXX 3 ', \@filelist, ' ', "@filelist", "\n";

    # Do permission check in separate loop as linux/windows functionality
    # differs when checking permissions from filesystem.
    # Cygwin can(?) handle permissions, Native w32/64 not supported ATM.
    if ($^O eq 'msys') {
	my (@flist, %flist);
	foreach (@filelist) {
	    push @flist, $_->[4] if ($_->[1] < 0);
	}
	if (@flist) {
	    xpIopen '', 'file', @flist;
	    while (<I>) {
		chomp, warn("'$_': strange 'file' output line\n"), next
		  unless /^([^:]*):\s+(.*)/;
		my $fn = $1; $_ = $2;
		$flist{$fn} = 0755, next if /executable/ or /directory/;
		$flist{$fn} = 0644;
	    }
	    xpIclose;
	    foreach (@filelist) {
		if ($_->[1] < 0) {
		    my $perm = $flist{$_->[4]} or die "'$_->[4]' not found.\n";
		    $_->[1] = $perm;
		}
	    }
	}
    }
    else { # unices!
	foreach (@filelist) {
	    if ($_->[1] < 0) {
		my @sb = stat $_->[4] or die "stat $_->[4]: $!\n";
		$_->[1] = $sb[2] & 0777;
	    }
	}
    }

    $wdir = $rpmdir . '/' . $pkgname;

    system ('/bin/rm', '-rf', $wdir);
    system ('/bin/mkdir', '-p', $wdir);

    my $cpiofile = $wdir . '/cpio';
    open_cpio_file $cpiofile;
    my $sizet = 0;
    foreach (sort { $a->[0] cmp $b->[0] } @filelist) {
	my ($mode, $size, $mtime) = file_to_cpio($_->[0], $_->[1], $_->[4]);
	add2lists($_->[0], $mode, $size, $mtime, $_->[2], $_->[3], $_->[4]);
	$sizet += $size;
    }
    close_cpio_file;

    my (@cdh_index, @cdh_data, $cdh_offset, $cdh_extras, $ptag);
    sub _append($$$$)
    {
	my ($tag, $type, $count, $data) = @_;

	die "$ptag >= $tag" if $ptag >= $tag and $tag > 99; $ptag = $tag;

	if ($type == 3) { # int16, align by 2
	    $cdh_extras++, $cdh_offset++, push @cdh_data, "\000"
	      if ($cdh_offset & 1);
	}
	elsif ($type == 4) { # int32, align by 4
	    if ($cdh_offset & 3) {
		my $pad = 4 - ($cdh_offset & 3);
		$cdh_extras++;
		$cdh_offset += $pad, push @cdh_data, "\000" x $pad;
	    }
	}
	elsif ($type == 5) {die "type 5: int64 not handled"} #int64 align by 8

	push @cdh_index, pack("NNNN", $tag, $type, $cdh_offset, $count);
	push @cdh_data, $_[3];
	$cdh_offset += length $_[3];
	warn 'Pushing data "', $_[3], '"', "\n" if $type == 6;
    }

    sub createsigheader($$$$$)
    {
	@cdh_index = (); @cdh_data = (); $cdh_offset = 0; $cdh_extras = 0, $ptag = 0;

	_append(269, 6, 1, $_[2] . "\000");    # SHA1
	_append(273, 6, 1, $_[3] . "\000");    # SHA256
	_append(1000, 4, 1, pack("N", $_[0] - 32)); # SIZE # XXX -32 !!!
	_append(1004, 7, 16, $_[1]);           # MD5
	_append(1007, 4, 1, pack("N", $_[4])); # PLSIZE
	_append(1008, 7, 6, "\0" x 6);         # RESERVEDSPACE

	my $ixcnt = scalar @cdh_data - $cdh_extras + 1;
	my $sx = (0x10000000 - $ixcnt) * 16;
	_append(62, 7, 16, pack("NNNN", 0x3e, 7, $sx, 0x10)); # HDRSIG
	my $hs = pop @cdh_index;

	my $header = join '', @cdh_data;
	my $hlen = length $header;
	my $hdrhdr = pack "CCCCNNN", 0x8e, 0xad, 0xe8, 0x01, 0, $ixcnt, $hlen;

	my $pad = $hlen % 8; $pad = 8 - $pad if $pad != 0;
	return $hdrhdr . join('', $hs, @cdh_index) . $header . "\0" x $pad;
    }

    sub createdataheader($) # npkg
    {
	@cdh_index = (); @cdh_data = (); $cdh_offset = 0; $cdh_extras = 0; $ptag = 0;
	sub _dep_tags($)
	{
	    return unless defined $_[0]; # depstring
	    my (@depversion, @depflags, @depname);
	    my @deps = split (/\s*,\s*/, $_[0]);
	    foreach (@deps) {
		my ($name, $flag, $version) = split (/\s*([><]*[>=<])\s*/, $_);
		push @depname, $name;
		unless (defined $version) {
		    push @depflags, 0;
		    push @depversion, '';
		    next
		}
		my $f;
		if ($flag =~ /=/){
		$f |= 0x08;
		}
		if ($flag =~ />/) {
		    $f |= 0x04;
		}
		if ($flag =~ /</) {
		    $f |= 0x02;
		}
		push @depflags, $f;
		push @depversion, $version;
	    }
	    my $count = scalar @deps;
	    if ($count > 0) {
		return ($count,
			pack("N" . $count, @depflags),
			join("\000", @depname) . "\000",
			join("\000", @depversion) . "\000")
	    }
	    #else
	    return ( 0 )
	}

	_append(100, 6, 1, "C\000"); # hdri18n, atm

	_append(1000, 6, 1, "$rpmname\000"); # name
	_append(1001, 6, 1, "$macros{version}\000"); # version
	_append(1002, 6, 1, "$macros{release}\000"); # release
	_append(1004, 9, 1, "$packages{$_[0]}->[1]->{summary}\000"); # summary, atm
	my $description = join '', @{$description{$_[0]}};
	$description =~ s/\s+$//;
	_append(1005, 6, 1, "$description\000"); # descrip, atm
	_append(1006, 4, 1, pack("N", $buildtime) ); # buildtime
	_append(1007, 6, 1, "$buildhost\000"); # buildhost
	_append(1009, 4, 1, pack("N", $sizet) ); # size
	_append(1014, 6, 1, "$packages{''}->[1]->{license}\000"); # license, atm
	my $group = $packages{$_[0]}->[1]->{group} // 'Unspecified';
	_append(1016, 6, 1, "$group\000");
	if (! $building_src_pkg) {
	    _append(1021, 6, 1, "$target_os\000"); # os
	    _append(1022, 6, 1, "$target_arch\000"); # arch
	}

	_append(1023, 6, 1, $pre{$npkg} . "\000")    if defined $pre{$npkg};
	_append(1024, 6, 1, $post{$npkg} . "\000")   if defined $post{$npkg};
	_append(1025, 6, 1, $preun{$npkg} . "\000")  if defined $preun{$npkg};
	_append(1026, 6, 1, $postun{$npkg} . "\000") if defined $postun{$npkg};

	my $count;
	$count = scalar @sizes;
	_append(1028, 4, $count, pack "N" . $count, @sizes);
	$count = scalar @modes;
	_append(1030, 3, $count, pack "n" . $count, @modes);
	$count = scalar @mtimes;
	_append(1034, 4, $count, pack "N" . $count, @mtimes);
	$count = scalar @md5sums;
	_append(1035, 8, $count, join("\000", @md5sums) . "\000");
	$count = scalar @unames;
	_append(1039, 8, $count, join("\000", @unames) . "\000");
	$count = scalar @gnames;
	_append(1040, 8, $count, join("\000", @gnames) . "\000");
	my ($pcnt, $t1112, $t1113) = 0;
	if ($building_src_pkg) {
	    #_fill_dep_tags($packages{$_[0]}->[1]->{buildrequires}, 1048, 1049, 1050);
	}
	else {
	    # source rpm, if there were any...(outcommented now, may get back?)
	    _append(1044, 6, 1, "$macros{name}-$macros{version}-src.rpm\000");
	    my $p = $packages{$_[0]}->[1]->{provides} || '';
	    my $t2;
	    ($pcnt, $t1112, $t2, $t1113) = _dep_tags "$rpmname=$macros{version}-$macros{release},$p";
	    _append 1047, 8, $pcnt, $t2 if $pcnt;
	    my ($c, $t1, $t3);
	    ($c, $t1, $t2, $t3) = _dep_tags $packages{$_[0]}->[1]->{requires};
	    if ($c) {
		_append 1048, 4, $c, $t1;
		_append 1049, 8, $c, $t2;
		_append 1050, 8, $c, $t3;
	    }
	}

	_append(1085, 6, 1, "/bin/sh\000") if defined $pre{$npkg};
	_append(1086, 6, 1, "/bin/sh\000") if defined $post{$npkg};
	_append(1087, 6, 1, "/bin/sh\000") if defined $preun{$npkg};
	_append(1088, 6, 1, "/bin/sh\000") if defined $postun{$npkg};

	if ($pcnt) {
	    _append 1112, 4, $pcnt, $t1112;
	    _append 1113, 8, $pcnt, $t1113;
	}

	$count = scalar @dirindexes;
	_append(1116, 4, $count, pack "N" . $count, @dirindexes);
	$count = scalar @files;
	_append(1117, 8, $count, join("\000", @files) . "\000");
	$count = scalar @dirs;
	_append(1118, 8, $count, join("\000", @dirs) . "\000");

	_append(1124, 6, 1, "cpio\000"); # payloadfmt
	_append(1125, 6, 1, "gzip\000"); # payloadcomp

	my $ixcnt = scalar @cdh_data - $cdh_extras + 1;
	my $sx = (0x10000000 - $ixcnt) * 16;
	_append(63, 7, 16, pack("NNNN", 0x3f, 7, $sx, 0x10)); # HDRIMM
	my $hi = pop @cdh_index;

	my $header = join '', @cdh_data;
	my $hlen = length $header;
	my $hdrhdr = pack "CCCCNNN", 0x8e, 0xad, 0xe8, 0x01, 0, $ixcnt, $hlen;

	return $hdrhdr . join('', $hi, @cdh_index) . $header;
    }

    my $dhdr = createdataheader $npkg;
    my $cpiosize = -s $cpiofile;
    system 'gzip', '-n', $cpiofile;
    my $ctx;
    $ctx = Digest->new('MD5'); $ctx->add($dhdr);
    open J, "$cpiofile.gz" or die $!; $ctx->addfile(*J); close J;
    my $md5 = $ctx->digest;
    $ctx = Digest->new('SHA-1'); $ctx->add($dhdr);
    my $sha1 = $ctx->hexdigest;
    $ctx = Digest->new('SHA-256'); $ctx->add($dhdr);
    my $sha256 = $ctx->hexdigest;
    my $shdr = createsigheader length($dhdr) + -s "$cpiofile.gz",
                               $md5, $sha1, $sha256, $cpiosize;
    open STDOUT, '>', "$wdir.rpm.wip" or die $!;
    $| = 1;
    my $leadname = substr "$swname-$macros{release}", 0, 65;
    print pack 'NCCnnZ66nnZ16', 0xedabeedb, 3, 0, $building_src_pkg,
	$arch_canon, $leadname, $os_canon, 5, "\0";
    print $shdr, $dhdr;
    system('/bin/cat' ,"$cpiofile.gz");
    open STDOUT, ">&STDERR" or die $!;
    rename "$wdir.rpm.wip", "$wdir.rpm" or die $!;
    print "Wrote '$wdir.rpm'\n";
}

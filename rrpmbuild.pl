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

use 5.8.1;
use strict;
use warnings;

use Fcntl ':mode';
use File::Find;
use POSIX qw/getcwd/;

use Digest;

# So far, this is proof-of-concept implementation (read: terrible hack).
# Even some mentioned features do not work... and tested only on linux
# with perl 5.10.x // 2010-06-10 too
# As of 2024-09-25 things may have improved, and produdes more or less
# good rpm v4 format packages...
# As of 2024-11, symbolic and hard link support were added; some rpm(8)
# versions between 4.11 and 4.20 (inclusive!) has been used when tested.

# Welcome to the source of 'restricted' rpmbuild. The 'restrictions' are:
#  does not check things that "real" rpm does (e.g. no binaries in noarch pkg)
#  %macros ("recursive") evaluated (only) once or twice...
#  no fancy variables
#  a set of %macros just not supported
#  only binary rpms (-bs probably does not work too well...)
#  only -bb now, more -b -options later (if ever). some --:s too...

# bottom line: the spec files that rrpmbuild can build, may also be buildable
# with standard rpm, but not necessarily wise versa.

# from rpm-4.8.0/rpmrc.in (aarch64 from rpm-4.19.1.1/rpmrc.in)

my %arch_canon = ( noarch => 255, # rpmpeek()ed and file(1)d (rpm src too hard)
		   i686 => 1, i586 => 1, i486 => 1, i386 => 1, x86_64 => 1,
		   armv3l => 12, armv4b => 12, armv4l => 12, armv5tel => 12,
		   armv5tejl => 12, armv6l => 12, armv7l => 12, armv7hl => 12,
		   armv7nhl => 12, arm => 12, aarch64 => 19 );

my %os_canon = ( linux => 1 );

# packages array defines order for packages + other hashes.
my @pkgnames = ('');
my %packages = ('', [ [ ], { } ] );


my (@prep, @build, @install, @clean);
my (%description, %files);
my (%pre, %post, %preun, %postun, %pretrans, %posttrans);
my @changelog;

sub usage()
{
    $_ = $0; s,.*/,,;

    die "\nUsage: $_",
      ' [--target=PLATFORM] [-D "MACRO VAL"...] (-bb|-bs) SPECFILE', qq:\n
    Environment variable 'SOURCE_DATE_EPOCH' does what one might expect.
    Option -D '_buildhost {buildhost}' sets (fixed) RPMTAG_BUILDHOST.
    "--build-in-place" implied, -D '_rpmdir {rpmdir}' changes _rpmdir
    (from 'build-rpms') -- this directory is created (if it didn't exist)
    before stage executions start. "Buildroot" points to a subdirectory
    in there and final rpms are written there. Current working directory
    is *not* changed there (stays in \$PWD) when stage executions start.\n\n:;
}

my ($specfile, $building_src_pkg, $targett, @defines, %macros);

while (@ARGV > 0) {
    $_ = shift @ARGV;
    if ($_ eq '-bb') {
	die "Build option chosen already\n" if defined $building_src_pkg;
	$building_src_pkg = 0;
	next
    }
    if ($_ eq '-bs') {
	die "Build option chosen already\n" if defined $building_src_pkg;
	$building_src_pkg = 1;
	next
    }
    if ($_ eq '--target') {
	die "Target chosen already\n" if defined $targett;
	die "$0: option '$_' requires an argument\n" unless @ARGV > 0;
	$targett = lc shift @ARGV;
	next
    }
    if ($_ =~ /--target=(.*)/) {
	die "Target chosen already\n" if defined $targett;
	$targett = lc $1;
	next
    }
    if ($_ eq '-D') {
	die "$0: option '$_' requires an argument\n" unless @ARGV > 0;
	$_ = shift @ARGV;
	die "'$_' not macro[ ]val\n" unless /^(\w+)[ ](.*)/;
	push @defines, [ $1, $2 ];
	$macros{$1} = $2;
	next
    }
    if ($_ =~ /-D(.+)/) {
	$_ = $1;
	die "'$_' not macro[ ]val\n" unless /^(\w+)[ ](.*)/;
	push @defines, [ $1, $2 ];
	$macros{$1} = $2;
	next
    }
    next if $_ eq '--build-in-place';
    $specfile = $_;
    last
}

my $buildhost = $macros{_buildhost} // '';

my $sde = $ENV{SOURCE_DATE_EPOCH} // '';
my $buildtime = ($sde ne '')? $sde + 0: time;

usage unless defined $building_src_pkg;

die "$0: missing specfile\n" unless defined $specfile;
die "$0: too many arguments\n" if @ARGV > 0;

my $ctx_md5 = Digest->new('MD5');
my $ctx_sha1 = Digest->new('SHA-1');
my $ctx_sha256 = Digest->new('SHA-256');

my $rpmdir = $macros{'_rpmdir'} // 'build-rpms';

my ($host_os, $host_arch) = grep { $_ = lc } split /\s+/, qx/uname -m -s/;

my ($target_os, $vendor, $target_arch);
if (defined $targett) {
    my @p = split /-/, $targett;
    die "'$targett': unknown --target format\n" if @p > 3;
    push @p, 'unknown' if @p == 1;
    push @p, 'linux' if @p == 2;
    ($target_arch, $vendor, $target_os) = @p;
} else {
    $vendor = 'unknown';
    ($target_os, $target_arch) = ($host_os, $host_arch);
}
my $os_canon = $os_canon{$target_os};
my $arch_canon = $arch_canon{$target_arch};

die "'$target_os': unknown os\n" unless defined $os_canon;
die "'$target_arch': unknown arch\n" unless defined $arch_canon;

sub init_macros()
{
    %macros =
      ( _prefix => '/usr',
	_exec_prefix => '/usr',
	_bindir => '%_exec_prefix/bin',
	_sbindir => '%_exec_prefix/sbin',
	_libexecdir => '%_exec_prefix/libexec',
	_datadir => '%_prefix/share',
	_sysconfdir => '%_prefix/etc',
	_sharedstatedir => '%_prefix/com',
	_localstatedir => '%_prefix/var',
	_lib => '/lib',
	_libdir => '%_exec_prefix/%_lib',
	_includedir => '%_prefix/include',
	_oldincludedir => '/usr/include',
	_infodir => '%_prefix/info',
	_mandir => '%_prefix/man',
	_host_cpu => $host_arch,
	_host_os => $host_os,
	_target_cpu => $target_arch,
	_vendor => $vendor,
	_target_os => $target_os,
	_rpmdir => $rpmdir,
	_target_platform => "$target_arch-$vendor-$target_os",

	setup => 'echo no %prep' )
}

sub _eval_macros($)
{
    sub _eval_it() {
	return $macros{$1} if defined $macros{$1};
	return '%'.$1;
    }
    #    s/%%/\001/g;
    # dont be too picky if var is in format %{foo or %foo} ;) (i.e fix ltr)
    $_[0] =~ s/%\{?(%|[\w\?\!]+)\}?/_eval_it/ge;
    #    s/\001/%/g;
}

sub eval_macros($)
{
    my $m = $_[0];
    _eval_macros($m);
    return $m;
}

my ($instroot, $instrlen);
sub rest_macros()
{
    _eval_macros $_ foreach (values %macros);

    if ($building_src_pkg) {
	$instroot = '.'
    } else {
	$instroot = "$rpmdir/br--$macros{_target_platform}";
	$instroot = getcwd . '/' . $instroot unless ord($rpmdir) == 47 # '/'
    }
    $instrlen = length $instroot;

    $ENV{'RPM_BUILD_ROOT'} = $instroot;
    $ENV{'RPM_OPT_FLAGS'} = '-O2';
    $ENV{'RPM_ARCH'} = $target_arch;
    $ENV{'RPM_OS'} = $target_os;
    $ENV{'LANG'} = $ENV{'LC_ALL'} = 'C';
    #$ENV{''} = '';

    $macros{buildroot} = $instroot;
    foreach (@defines) {
	$macros{$_->[0]} = eval_macros $_->[1]
    }
    @defines = ();
    sub NL() { "\n" }
    # makeinstall deprecated -- so no updates
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

    if ($buildhost) {
	$macros{_buildhost} = $buildhost;
    } else {
	$buildhost = $macros{_buildhost} // '';
	unless ($buildhost) {
	    require Net::Domain;
	    $buildhost = $macros{_buildhost} = Net::Domain::hostname();
	}
    }
}

my %stanzas = ( package => 1, description => 1, changelog => 1,
		prep => 1, build => 1, install => 1, clean => 1,
		files => 1, pre => 1, post => 1, preun => 1, postun => 1,
		pretrans => 1, posttrans => 1 );

sub readspec()
{
    sub readpackage($)
    {
	my ($arref, $hashref) = ($_[0]->[0], $_[0]->[1]);

	while (<I>) {
	    s/(#|%dnl\s).*//; # see %dnl commment in readlines() below...
	    next if /^\s*$/;
	    # %define should be handled differently (lazy eval) but...
	    if (/^\s*%define\s+(\S+)\s+(.*?)\s*$/ or
		/^\s*%global\s+(\S+)\s+(.*?)\s*$/) {
		$macros{$1} = eval_macros $2;
		next
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
		    die
		      "error: line $.: Tag takes single token only: $K: $val\n"
		      if $val =~ /\s/;
		    $macros{$key} = $val
		}
		# build files for source package
		if ($building_src_pkg && $key =~ /(source|patch)[0-9]+/) {
		    push @{ $files{''} }, $val;
		}
		if ($key eq 'buildarch') {
		    die "Support only 'noarch' for $K (not $val)\n"
		      unless $val eq 'noarch';
		    if (defined $targett) {
			die "'$target_arch' not BuildArch: '$val'",
			  " seen in '$specfile'\n" unless $target_arch eq $val;
		    }
		    # XXX should re-eval macros but just have early enough
		    $macros{_target_cpu} = $target_arch = $val;
		    $macros{_target_platform} = "$val-$vendor-$target_os";
		}
		next
	    }
	    chomp;
	    die "'$_': unknown header format\n";
	}
    }

    sub readlines($)
    {
	while (<I>) {
	    s/%dnl\s.*//; # is this too heavy (/[^%]\K%dnl\s/ and perl 5.10+ ?)
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
	elsif ($1 eq 'description') { readlines ($description{$2} = [ ]) }

	elsif ($1 eq 'prep') {    readignore \@prep }
	elsif ($1 eq 'build') {   readlines \@build }
	elsif ($1 eq 'install') { readlines \@install }
	elsif ($1 eq 'clean') {   readlines \@clean }

	elsif ($1 eq 'files') {
	    if ($building_src_pkg) {
		readfiles ([ ]);
	    }
	    else {
		readfiles ($files{$2} = [ ]);
	    }
	}

	elsif ($1 eq 'pre') { readlines2string $pre{$2} }
	elsif ($1 eq 'post') { readlines2string $post{$2} }
	elsif ($1 eq 'preun') { readlines2string $preun{$2} }
	elsif ($1 eq 'postun') { readlines2string $postun{$2} }

	elsif ($1 eq 'pretrans') { readlines2string $pretrans{$2} }
	elsif ($1 eq 'posttrans') { readlines2string $posttrans{$2} }

	elsif ($1 eq 'changelog') { readlines \@changelog }

	else { chomp; die "'$1': unsupported stanza macro.\n" }
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
foreach (qw/license summary/) {
    die "Package $_ not known\n" unless (defined $packages{''}->[1]->{$_});
}

# check that we have description and files for all packages
# description and/or files sections that do not have packages
# are just ignored (should we care ?)

foreach (@pkgnames) {
    die "No 'description' section for package '$_'\n"
      unless defined $description{$_};
    die "No 'files' section for package '$_'\n"
      unless defined $files{$_};
}

my ($plflgs, $plsfx, @plcmpr_w_opts) = do {
    $_ = $macros{_binary_payload} // '';
    if ($_) {
	die "_binary_payload '$_' does not match \\w\\d+\\w*[.]\\w+dio\n"
	  unless /^\w(\d+)\w*[.](\w+)dio$/;
	if ($2 eq 'gz') {
	    die "_binary_payload gzip level '$1' < 1\n" if $1 < 1;
	    die "_binary_payload gzip level '$1' > 9\n" if $1 > 9;
	    ($1,'gz', 'gzip', "-$1fn")
	}
	elsif ($2 eq 'xz') {
	    die "_binary_payload xz level '$1' > 9\n" if $1 > 9;
	    ($1,'xz', 'xz', "-$1f")
	}
	elsif ($2 eq 'zst') {
	    die "_binary_payload zstd level '$1' > 19\n" if $1 > 19;
	    $ENV{ZSTD_CLEVEL} = $1; # yeah right ;/
	    ($1,'zst', 'zstd', "-$1f", '--rm')
	}
	else { # to lazy to add 'bz' & 'lz' ('uf' needs more (or cat(1)))
	    die "_binary_payload compressor '$2' not supported\n"
	}
    }
    else { ('6','gz', 'gzip', '-6fn') }
};

#die "($plcmpr, $plflgs, $plopt)\n";

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
    unless (-d $rpmdir) {
	system qw/mkdir -p/, $rpmdir unless mkdir $rpmdir;
    }
    execute_stage 'build', join '', @build if @build;
    execute_stage 'install', join '', @install if @install;
}

sub open_cpio_file($)
{
    open STDOUT, '>', $_[0] or die "Open $_[0] failed: $!\n";
}

# knows files, directories and symlinks
sub file_lstat($$)
{
    my ($mode, $file) = @_;
    my ($size, $mtime);

    my @sb = lstat $file or die "lstat '$file': $!\n";
    $mtime = ($sde eq '')? $sb[9]: $buildtime;
    my $slnk = '';
    if (S_ISLNK($sb[2])) {
	$size = $sb[7]; $mode = 0120777;
	$slnk = readlink $file;
    }
    elsif (S_ISDIR($sb[2])) {
	$size = 0; $mode += 0040000;
    }
    else { $size = $sb[7]; $mode += 0100000; }

    return ($mode, $size, $mtime, $slnk)
}

sub hl_to_cpio($$$$$)
{
    my ($name, $mode, $nlink, $mtime, $ino) = @_;

    my $namesize = length($name) + 1;
    my $hdrbytes = 110 + $namesize;
    $hdrbytes += 4 - ($hdrbytes & 0x03) if ($hdrbytes & 0x03);
    # Type: New ASCII without crc (070701). See librachive/cpio.5
    syswrite STDOUT, sprintf
      ('070701' . '%08x' x 12 . "00000000%s\0\0\0\0", $ino, $mode, 0, 0,
       $nlink, $mtime, 0, 0,0,0,0, $namesize, $name), $hdrbytes;
}

sub file_to_cpio($$$$$$$)
{
    my ($name, $mode, $nlink, $mtime, $size, $fors, $ino) = @_;

    my $namesize = length($name) + 1;
    my $hdrbytes = 110 + $namesize;
    $hdrbytes += 4 - ($hdrbytes & 0x03) if ($hdrbytes & 0x03);
    # Type: New ASCII without crc (070701). See librachive/cpio.5
    syswrite STDOUT, sprintf
      ('070701' . '%08x' x 12 . "00000000%s\0\0\0\0", $ino, $mode, 0, 0,
       $nlink, $mtime, $size, 0,0,0,0, $namesize, $name), $hdrbytes;

    return unless $size;

    if ($mode == 0120777) {
	syswrite STDOUT, $fors
    } else {
	system ('/bin/cat', $fors)
    }
    if ($size & 0x03) {
	syswrite STDOUT, "\0\0\0", 4 - ($size & 0x03);
    }
}

sub close_cpio_file()
{
    file_to_cpio('TRAILER!!!', 0, 1, 0, 0, undef, 0);
    # not making size multiple of 512 (as doesn't rpm do either)
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
    our ($pkgname, $swname, $npkg, $rpmname, @filelist);

    # Use local instead of my -- the failure w/ my is a small mystery to me.
    local ($fmode, $dmode, $uname, $gname, $havedoc);
    local ($pkgname, $swname, $npkg, $rpmname, @filelist);

    #warn 'XXXX 1 ', \@filelist, "\n"; # see also XXXX 2 & XXXX 3

    sub addocfile($) {
	#if (/\*/)...
	# XXX pkgname has ${release}...
	warn "Adding doc file $_[0]\n";
	my $dname = "usr/share/doc/$swname";
	unless (defined $havedoc) {
	    push @filelist, [ $dname, $dmode, $uname, $gname, '.',
			      undef, undef, undef ];
	    $havedoc = 1;
	}
	my $fname = $dname . '/' . $_[0];
	push @filelist, [ $fname, $fmode, $uname, $gname, $_[0],
			  undef, undef, undef ];
    }

    my @_flist;
    sub _addfile($$);
    sub _addfile($$)
    {
	if (-d "$instroot/$_[0]") {
	    warn "Adding directory $_[0]\n";

	    push @filelist, [ $_[0], $dmode, $uname, $gname, "$instroot/$_[0]",
			      undef, undef, undef ];

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
	push @filelist, [ $_[0], $fmode, $uname, $gname, "$instroot/$_[0]",
			  undef, undef, undef ]

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
	($fmode, $dmode, $uname, $gname) = ($deffmode, $defdmode,
					    $defuname, $defgname);
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
    our (@files, @dirindexes, @dirs,%dirs, @modes, @sizes, @mtimes, @flntos);
    our (@inos,  @unames, @gnames, @md5sums);
    local (@files, @dirindexes, @dirs,%dirs, @modes, @sizes, @mtimes, @flntos);
    local (@inos,  @unames, @gnames, @md5sums);
    sub add2lists($$$$$$$$$)
    {
	sub getmd5sum($)
	{
	    open J, '<', $_[0] or die $!;
	    $ctx_md5->reset;
	    $ctx_md5->addfile(*J);
	    close J;
	    return $ctx_md5->hexdigest;
	}

	$_[0] =~ m%((.*/)?)(.+)% or die "'$_[0]': invalid path\n";
	my ($dir, $base) = (($building_src_pkg? '': '/') . $1, $3);
	my $di = $dirs{$dir};
	unless (defined $di) {
	    $di = $dirs{$dir} = scalar @dirs;
	    push @dirs, $dir;
	}
	push @inos, $_[8];
	push @files, $base;
	push @dirindexes, $di;

	push @modes, $_[1];
	push @sizes, $_[2];
	push @mtimes, $_[3];
	if ($_[4]) {
	    $flntos[$#mtimes] = $_[4]
	}
	push @unames, $_[5];
	push @gnames, $_[6];
	if (! $_[4] and -f $_[7]) {
	    push @md5sums, getmd5sum $_[7]
	}
	else { push @md5sums, '' }
    }

    # note: sorting dir.file before dir/file -- for rpm < 4.14 hardlink compat.
    @filelist = sort { $a->[0] cmp $b->[0] } @filelist;
    my %devinos;

    # Do permission check in separate loop as linux/windows functionality
    # differs when checking permissions from filesystem.
    # Cygwin can(?) handle permissions, Native w32/64 not supported ATM.
    # -- as of 2024-10: add dev:ino (for hard links) to unices part --
    if ($^O eq 'msys') {
	my (@flist, %flist);
	my $ino = 0;
	foreach (@filelist) {
	    $_->[6] = [ $_ ]; # no hard link detection
	    $_->[5] = ++$ino;
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
	my $ino = 0;
	foreach (@filelist) {
	    my @sb = lstat $_->[4] or die "lstat $_->[4]: $!\n";
	    $_->[5] = $ino;
	    my $devino = $sb[0].':'.$sb[1];
	    my $he = $devinos{$devino} // []; # list of hard links...
	    if (@{$he}) {
		$_->[5] = $he->[0][5]
	    }
	    else {
		$devinos{$devino} = $he;
		$_->[5] = ++$ino
	    }
	    push @{$he}, $_;
	    $_->[6] = $he;
	    if ($_->[1] < 0) {
		$_->[1] = $sb[2] & 0777;
	    }
	}
    }

    # add to headerlists in order (for rpm < 4.14 compatibility when hardlinks)
    foreach my $f (@filelist) {
	my ($mode, $size, $mtime, $slnk) = file_lstat $f->[1], $f->[4];
	$f->[7] = [ $mode, $size, $mtime, $slnk ];
	add2lists $f->[0], $mode, $size, $mtime, $slnk,
	  $f->[2], $f->[3], $f->[4], $f->[5];
    }

    # move last (hardlink) to first (when more than one listed as same)...
    foreach (values %devinos) {
	next unless @{$_} > 1;
	my $l = pop @{$_};
	unshift @{$_}, $l;
    }
    undef %devinos;

    my $pkgfbase = $rpmdir . '/' . $pkgname;
    my $cpiofile = $pkgfbase . '-cpio';
    if (-e $cpiofile) {
	unlink $cpiofile or die "Cannot unlink '$cpiofile': $!\n";
    }

    open_cpio_file $cpiofile;
    my $sizet = 0;
    my $hardlinks = 0;
    foreach my $f (@filelist) {
	my $l = $f->[6];
	next unless $f == $l->[0]; # hard links... last, unshifted above
	my $nlink = scalar @$l;
	shift @$l;
	my ($mode, $size, $mtime, $slnk) = @{$f->[7]};
	foreach my $h (@{$l}) {
	    hl_to_cpio $h->[0], $mode, $nlink, $mtime, $h->[5];
	    $hardlinks++;
	}
	my $fors = $slnk? $slnk: $f->[4];
	file_to_cpio $f->[0], $mode, $nlink, $mtime, $size, $fors, $f->[5];
	$sizet += $size;
    }
    close_cpio_file;

    my (@cdh_index, @cdh_data, $cdh_offset, $cdh_extras, $ptag);
    sub _append($$$$)
    {
	my ($tag, $type, $count, $data) = @_;

	die "$ptag >= $tag" if $ptag >= $tag and $tag > 99; $ptag = $tag;

	if ($type == 3) { # int16, align by 2
	    $cdh_extras++, $cdh_offset++, push @cdh_data, "\0"
	      if ($cdh_offset & 1);
	}
	elsif ($type == 4) { # int32, align by 4
	    if ($cdh_offset & 3) {
		my $pad = 4 - ($cdh_offset & 3);
		$cdh_extras++;
		$cdh_offset += $pad, push @cdh_data, "\0" x $pad;
	    }
	}
	elsif ($type == 5) {
	    die "type 5: int64 not handled (yet)" # int64, align by 8
	}
	elsif ($type == 6 or $type == 9) {
	    $data .= "\0"
	}
	push @cdh_index, pack("NNNN", $tag, $type, $cdh_offset, $count);
	push @cdh_data, $data;
	$cdh_offset += length $data;
	warn 'Pushing data "', $_[3], '"', "\n" if $type == 6 or $type == 9;
    }

    sub createsigheader($$$$$)
    {
	@cdh_index = (); @cdh_data = (); $cdh_offset = 0; $cdh_extras = 0;
	$ptag = 0;
	_append(269, 6, 1, $_[2]);             # SHA1
	_append(273, 6, 1, $_[3]);             # SHA256
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
	@cdh_index = (); @cdh_data = (); $cdh_offset = 0; $cdh_extras = 0;
	$ptag = 0;
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
		my $f = 0;
		if ($flag =~ /=/) { $f |= 0x08 }
		if ($flag =~ />/) { $f |= 0x04 }
		if ($flag =~ /</) { $f |= 0x02 }
		push @depflags, $f;
		push @depversion, $version;
	    }
	    my $count = scalar @deps;
	    return ( 0 ) unless $count;
	    # else #
	    return ($count,
		    pack("N" . $count, @depflags),
		    join("\0", @depname) . "\0",
		    join("\0", @depversion) . "\0")
	}

	#_append(100, 6, 1, 'C'); # hdri18n
	_append(100, 8, 1, "C\0"); # hdri18n

	_append(1000, 6, 1, $rpmname); # name
	_append(1001, 6, 1, $macros{version});
	_append(1002, 6, 1, $macros{release});
	_append(1004, 9, 1, $packages{$_[0]}->[1]->{summary});
	my $description = join '', @{$description{$_[0]}};
	$description =~ s/\s+$//;
	_append(1005, 9, 1, $description);
	_append(1006, 4, 1, pack("N", $buildtime) );
	_append(1007, 6, 1, $buildhost);
	_append(1009, 4, 1, pack("N", $sizet) ); # size
	_append(1014, 6, 1, $packages{''}->[1]->{license});
	my $group = $packages{$_[0]}->[1]->{group} // 'Unspecified';
	_append(1016, 9, 1, $group);
	if (! $building_src_pkg) {
	    _append(1021, 6, 1, $target_os);
	    _append(1022, 6, 1, $target_arch);
	}

	_append(1023, 6, 1, $pre{$npkg})    if defined $pre{$npkg};
	_append(1024, 6, 1, $post{$npkg})   if defined $post{$npkg};
	_append(1025, 6, 1, $preun{$npkg})  if defined $preun{$npkg};
	_append(1026, 6, 1, $postun{$npkg}) if defined $postun{$npkg};

	my $count;
	$count = scalar @sizes;
	_append(1028, 4, $count, pack "N" . $count, @sizes) if $count;
	$count = scalar @modes;
	_append(1030, 3, $count, pack "n" . $count, @modes) if $count;;
	$count = scalar @mtimes;
	_append(1034, 4, $count, pack "N" . $count, @mtimes) if $count;;
	$count = scalar @md5sums;
	_append(1035, 8, $count, join("\0", @md5sums) . "\0") if $count;
	if (@flntos) {
	    $flntos[$#mtimes] = '' if $#mtimes != $#flntos;
	    foreach (@flntos) { $_ = '' unless defined $_ }
	    $count = scalar @flntos;
	    _append(1036, 8, $count, join("\0", @flntos) . "\0");
	}
	$count = scalar @unames;
	_append(1039, 8, $count, join("\0", @unames) . "\0") if $count;
	$count = scalar @gnames;
	_append(1040, 8, $count, join("\0", @gnames) . "\0") if $count;
	my ($pcnt, $t1112, $t1113) = 0;
	if ($building_src_pkg) {
	    my ($c, $t1, $t2, $t3)
	      = _dep_tags $packages{$_[0]}->[1]->{buildrequires};
	      if ($c) {
		  _append 1048, 4, $c, $t1;
		  _append 1049, 8, $c, $t2;
		  _append 1050, 8, $c, $t3;
	      }
	}
	else {
	    _append(1044, 6, 1, "$macros{name}-$macros{version}-src.rpm");
	    my $p = $packages{$_[0]}->[1]->{provides} || '';
	    my $t2;
	    ($pcnt, $t1112, $t2, $t1113)
	      = _dep_tags "$rpmname=$macros{version}-$macros{release},$p";
	    _append 1047, 8, $pcnt, $t2 if $pcnt;
	    my ($c, $t1, $t3);
	    ($c, $t1, $t2, $t3) = _dep_tags $packages{$_[0]}->[1]->{requires};
	    if ($c) {
		_append 1048, 4, $c, $t1;
		_append 1049, 8, $c, $t2;
		_append 1050, 8, $c, $t3;
	    }
	}

	_append(1085, 6, 1, "/bin/sh") if defined $pre{$npkg};
	_append(1086, 6, 1, "/bin/sh") if defined $post{$npkg};
	_append(1087, 6, 1, "/bin/sh") if defined $preun{$npkg};
	_append(1088, 6, 1, "/bin/sh") if defined $postun{$npkg};

	if ($hardlinks) {
	    $count = scalar @inos;
	    _append(1095, 4, $count, pack "N" . $count, (1) x $count);
	    _append(1096, 4, $count, pack "N" . $count, @inos);
	}

	if ($pcnt) {
	    _append 1112, 4, $pcnt, $t1112;
	    _append 1113, 8, $pcnt, $t1113;
	}

	$count = scalar @dirindexes;
	_append(1116, 4, $count, pack "N" . $count, @dirindexes) if $count;
	$count = scalar @files;
	_append(1117, 8, $count, join("\0", @files) . "\0") if $count;
	$count = scalar @dirs;
	_append(1118, 8, $count, join("\0", @dirs) . "\0") if $count;

	_append(1124, 6, 1, 'cpio'); # payloadfmt
	_append(1125, 6, 1, $plcmpr_w_opts[0]); # payloadcomp
	_append(1126, 6, 1, $plflgs); # payloadflags

	_append(1132, 6, 1, $macros{_target_platform}); # platform

	_append(1151, 6, 1, $pretrans{$npkg})  if defined $pretrans{$npkg};
	_append(1152, 6, 1, $posttrans{$npkg}) if defined $posttrans{$npkg};
	_append(1153, 6, 1, "/bin/sh") if defined $pretrans{$npkg};
	_append(1154, 6, 1, "/bin/sh") if defined $posttrans{$npkg};

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
    my $cpiofile_zz = "$cpiofile.$plsfx";
    unlink $cpiofile_zz;
    system(@plcmpr_w_opts, $cpiofile) == 0
	or die "'@plcmpr_w_opts $cpiofile' failed\n";

    $ctx_md5->reset; $ctx_md5->add($dhdr);
    open J, $cpiofile_zz or die $!; $ctx_md5->addfile(*J); close J;
    my $md5 = $ctx_md5->digest;
    $ctx_sha1->reset; $ctx_sha1->add($dhdr);
    my $sha1 = $ctx_sha1->hexdigest;
    $ctx_sha256->reset; $ctx_sha256->add($dhdr);
    my $sha256 = $ctx_sha256->hexdigest;
    my $shdr = createsigheader length($dhdr) + -s $cpiofile_zz,
                               $md5, $sha1, $sha256, $cpiosize;
    open STDOUT, '>', "$pkgfbase.rpm.wip" or die $!;
    $| = 1;
    my $leadname = substr "$swname-$macros{release}", 0, 65;
    print pack 'NCCnnZ66nnZ16', 0xedabeedb, 3, 0, $building_src_pkg,
	$arch_canon, $leadname, $os_canon, 5, "\0";
    print $shdr, $dhdr;
    system('/bin/cat', $cpiofile_zz);
    open STDOUT, ">&STDERR" or die $!;
    rename "$pkgfbase.rpm.wip", "$pkgfbase.rpm" or die $!;
    print "Wrote '$pkgfbase.rpm'\n";
}

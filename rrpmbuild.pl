#!/usr/bin/perl
# -*- cperl -*-

# This file is part of MADDE
#
# Copyright (C) 2010 Nokia Corporation and/or its subsidiary(-ies).
#
# Contact: Riku Voipio <riku.voipio@nokia.com>
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

use Digest::MD5;

# SO far, this is proof-of-concept implementation (read: terrible hack).
# Even some mentioned features do not work... and tested only on linux
# with perl 5.10.x // 2010-06-10 too

# Welcome to the source of 'restricted' rpmbuild. The 'restrictions' are:
#  we do not recurse! (some is easy to add (and even full recursion)
#  no fancy variables
#  a se if %macros just not supported
#  only binary rpms (so far)
#  only -bb now, more -b -optios later. some --:s too...


# bottom line: the spec files that rrpmbuild can build, are also buildable
# with standard rpm, but not wise versa.

# from rpm-4.8.0/rpmrc.in

my %arch_canon = ( i686 => 1, i586 => 1, i486 => 1, i386 => 1, x86_64 => 1,
		   armv3l => 12, armv4b => 12, armv4l => 12, armv5tel => 12,
		   armv5tejl => 12, armv6l => 12, armv7l => 12, arm => 12 );

my %os_canon = ( Linux => 1 );

# packages array defines order for packages + other hashes.
my @pkgnames = ('');
my %packages = ('', [ [ ], { } ] );

my (@prep, @build, @install, @clean);
my (%description, %files);
my (%pre, %post, %preun, %postun);
my @changelog;

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

my $instroot = 'rrpmbuild/instroot';
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
	# dont be too picky if var is in format %{foo or $foo} ;) (i.e fix ltr)
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
	    push @pkgnames, $2;
	    readpackage ($packages{$2} = [ [ ], { } ]);
	}
	elsif ($1 eq 'description') { readlines ($description{$2} = [ ]); }

	elsif ($1 eq 'prep') {    readignore \@prep; }
	elsif ($1 eq 'build') {   readlines \@build; }
	elsif ($1 eq 'install') { readlines \@install; }
	elsif ($1 eq 'clean') {   readlines \@clean; }

	elsif ($1 eq 'files') { readfiles ($files{$2} = [ ]); }
	elsif ($1 eq 'pre') { readlines ($pre{$2} = [ ]); }
	elsif ($1 eq 'post') { readlines ($post{$2} = [ ]); }
	elsif ($1 eq 'preun') { readlines ($preun{$2} = [ ]); }
	elsif ($1 eq 'postun') { readlines ($postun{$2} = [ ]); }

	elsif ($1 eq 'changelog') { readlines \@changelog; }

	else { chomp; die "'$1': unsupported stanza macro.\n"; }
	last if eof I;
    };
}

die "Usage: $0 -bb <specfile>\n" unless @ARGV == 2 && $ARGV[0] eq '-bb';
die "$ARGV[1]: not a file\n" unless -f $ARGV[1];

my ($target_os, $target_arch) = split /\s+/, qx/uname -m -s/;
my $os_canon = $os_canon{$target_os};
my $arch_canon = $arch_canon{$target_arch};

# XXX should ignore for noarch.. (maybe) so check later...
die "'$target_os': unknown os\n" unless defined $os_canon;
die "'$target_arch': unknown arch\n" unless defined $arch_canon;

init_macros;
open I, '<', $ARGV[1] or die;
readspec;
close I;
foreach (qw/name version release/) {
    die "Package $_ not known\n" unless (defined $macros{$_});
}
#rest_macros; # moved above for now. smarter variable expansion coming later.

# XXX check what must be in "sub" packages
foreach (qw/license summary group/) {
    die "Package $_ not known\n" unless (defined $packages{''}->[1]->{$_});
}


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
    system('/bin/sh', '-exc', $_[1]);
    if ($?) {
	my $ev = $? >> 8;
	die "$_[0] exited with nonzero exit code ($ev)\n";
    }
}

#skip prep ## and fix...
#execute_stage 'clean', join '', @clean;

execute_stage 'build', join '', @build;
execute_stage 'install', join '', @install;

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
	$mtime = $sb[9];
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


# fill arrays, make cpio
foreach (@pkgnames)
{
    my ($fmode, $dmode, $uname, $gname, $havedoc);
    my ($wdir, $pkgname, $swname, $spkg, @filelist);

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

    $spkg = $_;
    if (length $_) {
	$swname = "$macros{name}-$spkg-$macros{version}";
    }
    else {
	$swname = "$macros{name}-$macros{version}";
    }
    $pkgname = "$swname-$macros{release}.$target_arch";

    my ($deffmode, $defdmode, $defuname, $defgname) = qw/-1 -1 root root/;

    LINE: foreach (@{$files{$spkg}}) {
	($fmode, $dmode, $uname, $gname) = ($deffmode,$defdmode,$defuname,$defgname);
	my ($isdir, $isconfig, $isdoc) = (0, 0, 0);
	while (1) {
	    if (s/\001(def)?attr\001\((.+?)\)//) {
		my @attrs = split /\s*,\s*/, $2;

		$fmode = $attrs[0] if defined $attrs[0];
		$uname = $attrs[1] if defined $attrs[1];
		$gname = $attrs[2] if defined $attrs[2];
		$dmode = $attrs[3] if defined $attrs[3];
		# XXX should check that are numeric and in right range.
		$fmode = $fmode eq '-'? -1: oct $fmode;
		$dmode = $dmode eq '-'? -1: oct $dmode;
		($deffmode,$defdmode,$defuname,$defgname)
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

	# XXX add check must start with / (and allow whitespaces (mayber)
	addfile $1, $isdir if /^\s*\/+(\S+?)\/*\s+$/; # XXX no whitespace in filenames
    }

    my (@files, @dirindexes, @dirs, %dirs, @modes, @sizes, @mtimes);
    my (@unames, @gnames, @md5sums);
    sub add2lists($$$$$$$)
    {
	sub getmd5sum($)
	{
	    my $ctx = Digest::MD5->new;
	    #XXX warn $_[0];
	    open J, '<', $_[0] or die $!;
	    $ctx->addfile(*J);
	    close J;
	    return $ctx->hexdigest;
	}

	$_[0] =~ m%((.*/)?)(.+)% or die "'$_[0]': invalid path\n";
	my ($dir, $base) = ('/' . $1, $3);
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

    # Do permission check in separate loop as linux/windows functionality
    # differs when checking permissions from filesystem.

    # Cygwin can(?) handle permissions, Native w32/64 not supported ATM.
    if ($^O eq 'msys') {
    }
    else {
    }

    $wdir = 'rrpmbuild/' . $pkgname;

    system ('/bin/rm', '-rf', $wdir);
    system ('/bin/mkdir', '-p', $wdir);

    my $cpiofile = $wdir . '/cpio';
    open_cpio_file $cpiofile;
    foreach (sort { $a->[0] cmp $b->[0] } @filelist) {
	my ($mode, $size, $mtime) = file_to_cpio($_->[0], $_->[1], $_->[4]);
	add2lists($_->[0], $mode, $size, $mtime, $_->[2], $_->[3], $_->[4]);
    }
    close_cpio_file;

    sub createsigheader($$)
    {
	# all hardcoded (use _append later, when proof-of-concept ready)
	my @hdr;

	push @hdr, pack("CCCCNNN", 0x8e, 0xad, 0xe8, 0x01, 0, 2, 20);
	#push @hdr, pack("CCCCNNN", 0x8e, 0xad, 0xe8, 0x01, 0, 3, 36);
	#push @hdr, pack("NNNN", 62, 7, 20, 16); # HDRSIG
	push @hdr, pack("NNNN", 1000, 4, 0, 1); # SIZE
	push @hdr, pack("NNNN", 1004, 7, 4, 16); # MD5

	#push @hdr, pack("N", $_[0]); # add SIZE;
	push @hdr, pack("N", $_[0] - 32); # add SIZE; # XXX -32 !!!
	push @hdr, $_[1]; # add digest
	#push @hdr, pack("CCCCCCCCCCCCCCCC", 0x00, 0x00, 0x00, 0x3e, 0x00, 0x00,
	#		0x00, 0x07, 0xff, 0xff, 0xff, 0xb0, 0x00, 0x00, 0x00, 0x10);
	return join('', @hdr) . "\0" x 4; # with align
    }

    my (@cdh_index, @cdh_data, $cdh_offset, $cdh_extras);

    sub createdataheader($$) # spkg, cpiofile
    {
	@cdh_index = (); @cdh_data = (); $cdh_offset = 0; $cdh_extras = 0;
	sub _append($$$$)
	{
	    my ($tag, $type, $count, $data) = @_;

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
	    # elif $type == 5) #int64 align by 8...

	    push @cdh_index, pack("NNNN", $tag, $type, $cdh_offset, $count);
	    push @cdh_data, $_[3];
	    $cdh_offset += length $_[3];
	    warn 'Pushing data "', $_[3], '"', "\n" if $type == 6;
	}

	_append(100, 6, 1, "C\000"); # hdri18n, atm

	_append(1000, 6, 1, "$macros{name}\000"); # name
	_append(1001, 6, 1, "$macros{version}\000"); # version
	_append(1002, 6, 1, "$macros{release}\000"); # release
	_append(1004, 9, 1, "$packages{$_[0]}->[1]->{summary}\000"); # summary, atm
	my $description = join '', @{$description{$_[0]}};
	$description =~ s/\s+$//;
	_append(1005, 6, 1, "$description\000"); # descrip, atm
	_append(1009, 4, 1, pack("N", $cpio_dsize) ); # size
	_append(1014, 6, 1, "$packages{''}->[1]->{license}\000"); # license, atm
	_append(1016, 6, 1, "$packages{$_[0]}->[1]->{group}\000"); # group, atm
	_append(1021, 6, 1, "$target_os\000"); # os
	_append(1022, 6, 1, "$target_arch\000"); # arch
	_append(1046, 4, 1, pack("N", -s $_[1]) ); # archivesize
	_append(1124, 6, 1, "cpio\000"); # payloadfmt
	_append(1125, 6, 1, "gzip\000"); # payloadcomp

	# 8, not 6 - 6 made rpm 4.8.1 crash mysteriously ;/
	_append(1047, 8, 1, "$macros{name}\000"); # providename

	my $count;
	$count = scalar @files;
	_append(1117, 8, $count, join("\000", @files) . "\000");
	$count = scalar @dirs;
	_append(1118, 8, $count, join("\000", @dirs) . "\000");
	$count = scalar @dirindexes;
	_append(1116, 4, $count, pack "N" . $count, @dirindexes);
	$count = scalar @modes;
	_append(1030, 3, $count, pack "n" . $count, @modes);
	$count = scalar @sizes;
	_append(1028, 4, $count, pack "N" . $count, @sizes);
	$count = scalar @mtimes;
	# moved last.
	#_append(1034, 4, $count, pack "N" . $count, @mtimes);
	#$count = scalar @md5sums;
	_append(1035, 8, $count, join("\000", @md5sums) . "\000");
	$count = scalar @unames;
	_append(1039, 8, $count, join("\000", @unames) . "\000");
	$count = scalar @gnames;
	_append(1040, 8, $count, join("\000", @gnames) . "\000");

	# mtimes moved last, so that header is aligned by 4...
	_append(1034, 4, $count, pack "N" . $count, @mtimes);
	$count = scalar @md5sums;

	my $header = join '', @cdh_data;
	my $hdrhdr = pack "CCCCNNN", 0x8e, 0xad, 0xe8, 0x01, 0,
	  scalar @cdh_data - $cdh_extras, length($header);

	return $hdrhdr . join('', @cdh_index) . $header;
    }

    my $dhdr = createdataheader $spkg, $cpiofile;
    system 'gzip', $cpiofile;
    my $ctx = Digest::MD5->new();
    $ctx->add($dhdr);
    open J, "$wdir/cpio.gz" or die $!;
    $ctx->addfile(*J);
    close J;
    my $shdr = createsigheader length($dhdr) + -s "$cpiofile.gz", $ctx->digest;

    open STDOUT, '>', "$wdir.rpm" or die $!;
    my $leadname = substr "$swname-$macros{release}", 0, 65;
    print pack 'NCCnnZ66nnZ16', 0xedabeedb, 3, 0, 0,
	$os_canon, $leadname, $arch_canon, 5, "\0";
    print $shdr, $dhdr;
    system('/bin/cat' ,"$cpiofile.gz");
    open STDOUT, ">&STDERR" or die;
}

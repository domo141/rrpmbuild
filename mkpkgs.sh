#!/bin/sh
# -*- mode: shell-script; sh-basic-offset: 8; tab-width: 8 -*-
# $ mkpkgs.sh $

case ${BASH_VERSION-} in *.*) shopt -s xpg_echo; esac
case ${ZSH_VERSION-} in *.*) emulate ksh; esac

set -euf  # hint: (z|ba|da|'')sh -x thisfile [args] to trace execution

die () { printf '%s\n' '' "$@" ''; exit 1; } >&2

mkvers ()
{
	set x `exec git log -1 --pretty=%ct`
	SECS=$2
	IFS="${IFS}-"
	set x `exec git log --pretty=%ci | sed 's/ .*//' | uniq -c | sed q`
	IFS=
	VERS=$3.$4.$5
	RELN=$2
}

mkvers


opt=
for f in f rpmpeek.pl f rrpmbuild.pl
do
	case $f in ?) opt=$f; continue; esac
	test -$opt $f || { case $opt in f) type=file ;;
				d) type=directory ;; x) type=executable; esac
		die "'$f': no such $type (wrong dir?)"; }
done

rm -rf dot-build

mkdir -p dot-build/usr/bin
cp rpmpeek.pl rrpmbuild.pl dot-build/usr/bin

SIZE=`du -ks dot-build | tr -dc 0-9`

export TAR_OPTIONS='--format=ustar --owner=root --group=root --sort=name'

PKG=rrpmbuild

MAINT='Tomi Ollila <tomi.ollila@iki.fi>'

mkdir dot-build/DEBIAN
echo 2.0 > dot-build/DEBIAN/debian-binary
echo > dot-build/DEBIAN/control "\
Package: $PKG
Version: $VERS-$RELN
Architecture: all
Maintainer: $MAINT
Installed-Size: $SIZE
Depends: perl
Section: utilities
Priority: optional
Description: R rpm build tool
 R rpm build tool
 Och Samma på svenska
 Niinkuin myös suomeksi"

( cd dot-build/DEBIAN; exec tar -I 'gzip -n' -cf control.tar.gz ./control )
( cd dot-build; exec tar --exclude '[DR][EP][BM]*' -I 'gzip -n' -cf DEBIAN/data.tar.gz . )
( cd dot-build/DEBIAN;
  ln ../../mkpkgs.sh .
  ARCHIVE_TIME=$SECS; export ARCHIVE_TIME
  exec > ../${PKG}_${VERS}-${RELN}_all.deb
  echo '!<arch>'
  perl -x "$0" addstr2ar debian-binary '2.0
'
  perl -x "$0" addfile2ar control.tar.gz
  perl -x "$0" addfile2ar data.tar.gz )

mkdir dot-build/RPM
echo > dot-build/RPM/rpm.spec "\
Name: $PKG
Version: $VERS
Release: $RELN
Summary: R rpm build tool
BuildArch: noarch

Group: Development/Tools
License: Confidential

%description
R rpm build tool
Och Samma på svenska
Niinkuin myös suomeksi

%prep
%setup q

%build
echo built

%install
mkdir %{buildroot}
ln -s ../../usr %{buildroot}
echo installed

%files
/usr/bin/*

%changelog
* Fri Mar 15 2013 Tomi Ollila <tomi.ollila@iki.fi> - 0.5
- Yes, there were changes made"

./rrpmbuild.pl -D '_buildhost localhost' -D '_rpmdir dot-build/RPM' -bb \
	dot-build/RPM/rpm.spec
set +f
mv dot-build/RPM/*.rpm dot-build
echo
ls -godF dot-build/*
exit

#!perl
#line 129
# warn 'at mkpkgs.sh line 129';

# (progn (cperl-mode) (set-variable 'cperl-indent-level 8))
# (progn (shell-script-mode) (set-variable 'sh-basic-offset 8))

use strict;
use warnings;

sub copyIO($)
{
  my $left = $_[0];
  while ($left > 65536) {
	my $l = sysread I, $_, 65536;
	die "Read error: $!\n" unless $l;
	die "Write error: $!\n" unless syswrite STDOUT, $_;
	$left -= $l;
 }
  while ($left > 0) {
	my $l = sysread I, $_, $left;
	die "Read error: $!\n" unless $l;
	die "Write error: $!\n" unless syswrite STDOUT, $_;
	$left -= $l;
 }
}

if ($ARGV[0] eq 'addfile2ar')
{
        open I, '<', $ARGV[1] or die "Cannot read '$ARGV[0]/$_[0]': $!\n";
        my $size = -s $ARGV[1];
        my $time = $ENV{ARCHIVE_TIME};
        syswrite STDOUT, sprintf "%-16s%d  0     0     100644  %-10d\140\012",
                $ARGV[1], $time, $size;
        copyIO $size;
        syswrite STDOUT, "\n", 1 if $size & 1;
        close I;
}

if ($ARGV[0] eq 'addstr2ar')
{
        my $size = length $ARGV[2];
        my $time = $ENV{ARCHIVE_TIME};
        syswrite STDOUT, sprintf "%-16s%d  0     0     100644  %-10d\140\012",
                $ARGV[1], $time, $size;
	syswrite STDOUT, $ARGV[2];
        syswrite STDOUT, "\n", 1 if $size & 1;
}

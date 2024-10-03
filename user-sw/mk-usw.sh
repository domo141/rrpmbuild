#!/bin/sh
#
# $ mk-usw.sh $
#
# Author: Tomi Ollila -- too ät iki piste fi
#
#	Copyright (c) 2024 Tomi Ollila
#	    All rights reserved
#
# Created: Tue 01 Oct 2024 20:15:45 EEST too
# Last modified: Thu 03 Oct 2024 17:52:07 +0300 too

case ${BASH_VERSION-} in *.*) set -o posix; shopt -s xpg_echo; esac
case ${ZSH_VERSION-} in *.*) emulate ksh; esac

set -euf  # hint: (z|ba|da|'')sh -x thisfile [args] to trace execution

die () { printf '%s\n' '' "$@" ''; exit 1; } >&2

x () { printf '+ %s\n' "$*" >&2; "$@"; }
x_exec () { printf '+ %s\n' "$*" >&2; exec "$@"; exit not reached; }

test "${UID-}" || UID=`id -u`
test "$UID" = 0 && die 'Do not run as root'

command -v rpm >/dev/null && rpme=true || rpme=false
$rpme || printf %s\\n '' 'NOTE: rpm(1) does not exist' >&2

v=1
r=1.usw

test $# -gt 0 || die "Usage: ${0##*/} {rootdir}

Imagine you have a system which has rpm(1), but one needs to install
packages elsewhere than system directories.
There may also be need/desire to install as non-root user.

Enter rootdir where to install a system where such a thing can be achieved;
this will create user-sw-$v-${r}XX-noarch.rpm and install it in {rootdir};
after installation, {rootdir}/bin will contain usw, rrpmbuild.pl and rpmpeek.pl

Add {rootdir}/bin to PATH and then execute 'usw' to manage the env there."

$rpme || die 'Need rpm(1) for this to be useful'

case $1 in *["$IFS"]*) die "Whitespace in '$1'"; esac

test -d "$1" || die "Create '$1' first"

duid=`stat -c %u "$1"`
test "$duid" = "$UID" || die "Directory '$1' owner '$duid' not '$UID'"

test "`cd "$1" && find .`" = '.' || die "Directory '$1' not empty"

rp1=`realpath -s "$1"` # keep symlinks, user responsibility

case $rp1 in *["$IFS"]*) die "Whitespace in '$rp1'"; esac

ch2=`printf %s "$rp1" | sha256sum`
ch2=${ch2%${ch2#??}} # 2 first chars, for a bit of compatibility checking

r=$r$ch2

chi=.usw$ch2

vlrd=var/lib/rpm
vcrd=var/cache/rpm
(cd "$1" && printf 'pwd: ' && pwd && x_exec mkdir -p tmp/bstr $vlrd $vcrd)

(
  rp0=`realpath "$0"`
  dn=${rp0%/*}
  test -f $dn/rrpmbuild.pl && ddn=$dn || ddn=${rp0%/*/*}
  cp $ddn/rrpmbuild.pl $ddn/rpmpeek.pl "$1"/tmp/bstr
  exec \
  sed	-e 's/.*exit.*install-me-first.*/#/' \
	-e "/rootdir=/ s =.* =$rp1 " -e "/chi=/ s/=.*/=$chi/" \
  $dn/usw-tmpl.sh > "$1"/tmp/bstr/usw
)
(
  rd=`realpath "$1"`
  cd "$rd"/tmp/bstr
  rdr=${rd#/}
  echo > usw.spec "
Name: user-sw
Summary: user sw in $rdr
Version: $v
Release: $r
License: LGPL v2.1
BuildArch: noarch

%description
User to install custom-made rpm pkgs to non-root hierarchy

%prep
exit 0

%build
exit 0

%install
mkdir -p %buildroot/$rdr/bin
cp rrpmbuild.pl rpmpeek.pl usw %buildroot/$rdr/bin
set +f
cd %buildroot/$rdr/bin
exec chmod 755 *

%files
%defattr/-,root,root,-)
$rd/
"
  printf 'pwd: '; pwd
  x_exec perl rrpmbuild.pl -bb usw.spec
)

( cd "$1" && printf 'pwd: ' && pwd && set -x &&
  mv tmp/bstr/build-rpms/user-sw-$v-$r.noarch.rpm var/cache/rpm &&
  exec rpm --dbpath $PWD/var/lib/rpm -ivh var/cache/rpm/user-sw-$v-$r.noarch.rpm
)

printf 'pwd: '; pwd
x rm -rf $1/tmp/bstr
x_exec find $1

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
# Last modified: Sat 23 Nov 2024 13:37:08 -0800 too

case ${BASH_VERSION-} in *.*) set -o posix; shopt -s xpg_echo; esac
case ${ZSH_VERSION-} in *.*) emulate ksh; esac

set -euf  # hint: (z|ba|da|'')sh -x thisfile [args] to trace execution

LANG=C LC_ALL=C; export LANG LC_ALL; unset LANGUAGE

die () { printf '%s\n' '' "$@" ''; exit 1; } >&2

x () { printf '+ %s\n' "$*" >&2; "$@"; }
x_exec () { printf '+ %s\n' "$*" >&2; exec "$@"; exit not reached; }

v=12
r=1.usw

test $# -gt 0 || die "Usage: ${0##*/} {rootdir}

Imagine you have a system which has rpm(8), but one needs to install
packages elsewhere than system directories.
There may also be need/desire to install as non-root user.

Enter rootdir where to install a system where such a thing can be achieved;
this will create user-sw-$v-${r}XX-noarch.rpm and bootstrap-user-sw-uswXX.sh

bootstrap-user-sw-uswXX.sh needed to populate {rootdir} (with a few dirs)
and then install user-sw-$v-${r}XX-noarch.rpm package there. After that
the 'usw' tool in {rootdir}/bin/ can be used to install more packages
(also new version of user-sw if such is made (with ${0##*/}) available)

After bootstrapping one can either add {rootdir}/bin to PATH, symlink 'usw'
elsewhere in PATH -- or access the content in {rootdir}/ any other way...

The 'XX' part in the names above is 2 first hexdigits of the sha256 digest
of the installation directory. That is used to check a bit that a package
that is being installed probably installs files in expected fs hierarchy."

case $1 in *["$IFS"]*) die "Whitespace in '$1'"; esac

rp1=`realpath -ms "$1"`

case $rp1 in *["$IFS"]*) die "Whitespace in '$rp1'"; esac

test "$1" = "$rp1" || echo rootdir: $rp1

ch2=`printf %s "$rp1" | sha256sum`
ch2=${ch2%${ch2#??}} # 2 first chars, for a bit of compatibility checking

r=$r$ch2

chi=usw$ch2

user_sw_rpm=user-sw-$v-$r.noarch.rpm

if test -f "$user_sw_rpm"
then  echo "'$user_sw_rpm' exists. Doing bootstrap...sh (only)"
else
 vlrd=var/lib/rpm
 vcrd=var/cache/rpm

 td=`mktemp -d`
 trap "rm -rf $td" 0
 (
   rp0=`realpath "$0"`
   dn0=${rp0%/*}
   ddn0=${rp0%/*/*}
   echo > $td/usw.spec "
Name: user-sw
Summary: user sw in $dn0
Version: $v
Release: $r
License: LGPL v2.1
BuildArch: noarch
Provides: $rp1

%description
User to install custom-made rpm pkgs to non-root hierarchy

%prep
exit 0

%build
exit 0

%install
mkdir -p %buildroot/$rp1/bin
cp $ddn0/rrpmbuild.pl $ddn0/rpmpeek.pl %buildroot/$rp1/bin
sed	-e 's/.*exit.*install-me-first.*/#/' \
	-e '/rootdir=/ s =.* =$rp1 ' -e '/chi=/ s/=.*/=.$chi/' \
	$dn0/usw-tmpl.sh > %buildroot/$rp1/bin/usw

set +f
cd %buildroot/$rp1/bin
exec chmod 755 *

%files
%defattr/-,root,root,-)
$rp1/
"
   cd $td
   printf 'pwd: '; pwd
   x_exec perl $ddn0/rrpmbuild.pl -bb usw.spec
 )

 printf 'pwd: '; pwd
 mv $td/build-rpms/$user_sw_rpm .

 rm -rf $td
 trap - 0
fi

bf=bootstrap-user-sw-$chi.sh
sed -ne 1d -e '/^#!\/bin\/sh/,$ {
	'"s %d $1 ; s/%rpm/$user_sw_rpm/; p; }" "$0" > $bf
chmod 755 $bf

echo Use:

x_exec ls -goU $user_sw_rpm $bf

exit 0
---- bootstrap code ----
#!/bin/sh

die () { printf '%s\n' '' "$@" ''; exit 1; } >&2

test "${UID-}" || UID=`id -u`
test "$UID" = 0 && die 'Do not run this as root'

command -v rpm >/dev/null || die 'Need rpm(8) for this to be useful'

test $# = 1 || die "Usage: ${0##*/} path/to/%rpm"

case $1 in %rpm)
	;; */%rpm)
	;; *) die "'$1' is not path to file named %rpm"
esac

test -f "$1" || die "'$1': no such file"

d=%d

test -d "$d" || die "Create '$d' first"

duid=`stat -c %u "$d"`
test "$duid" = "$UID" || die "Directory '$d' owner '$duid' not '$UID'"

test "`cd "$d" && find . -maxdepth 1`" = '.' || die "Directory '$d' not empty"

set -x

(cd "$d" && exec mkdir bin tmp var var/lib var/lib/rpm var/cache var/cache/rpm)

rpm --dbpath=%d/var/lib/rpm -ivh "$1"

find %d | sort

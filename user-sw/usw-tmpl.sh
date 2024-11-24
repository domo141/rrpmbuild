#!/bin/sh
#
# Author: Tomi Ollila -- too ät iki piste fi
#
#	Copyright (c) 2024 Tomi Ollila
#	    All rights reserved
test "$1" = '' && shift || exit install-me-first
# Created: Tue 01 Oct 2024 20:30:50 EEST too
# Last modified: Sat 23 Nov 2024 13:46:13 -0800 too

case ${BASH_VERSION-} in *.*) set -o posix; shopt -s xpg_echo; esac
case ${ZSH_VERSION-} in *.*) emulate ksh; esac

set -euf  # hint: (z|ba|da|'')sh -x thisfile [args] to trace execution

LANG=C LC_ALL=C; export LANG LC_ALL; unset LANGUAGE

die () { printf '%s\n' '' "$@" ''; exit 1; } >&2

x () { printf '+ %s\n' "$*" >&2; "$@"; }
x_bg () { printf '+ %s\n' "$*" >&2; "$@" & }
x_env () { printf '+ %s\n' "$*" >&2; env "$@"; }
x_eval () { printf '+ %s\n' "$*" >&2; eval "$*"; }
x_exec () { printf '+ %s\n' "$*" >&2; exec "$@"; exit not reached; }

test "${UID-}" || UID=`id -u`
test "$UID" = 0 && die "Do not run ${0##*/} as root"

test $# -gt 0 || { echo; echo Commands:; exec sed -n 's/^#[.]/ /p' "$0"; }

rootdir=/
chi=.uswXX

c=$1; shift


#. rpm*  :run rpm command with dbpath pointing to usw
#.        known cmds: 'rpmi' 'rpmu' 'rpme' 'rpmqa' 'rpmqil' 'rpmqilp' 'rpmqf'
case $c in rpm*)
	rpm="rpm --dbpath=$rootdir/var/lib/rpm"
	test $c = rpmqa && {
		qao='-qa --nodigest --nosignature'
		test $# = 0 && x_exec $rpm $qao
		$rpm $qao | grep "$@"
		exit
	}
	test $# = 0 && die "${0##*/} $c expects args..."
	case $c in rpm[iu])
		for arg
		do  case  $arg  in *$chi.*.rpm)
			grep -aq "$rootdir/" "$arg" ||
			     die "Cannot find '$rootdir/' in '$arg'"
				;; *.rpm)
			die "No '*$chi.*.' part in '$arg'"
		    esac
		done
	esac
	case $c in rpmi) set -- -ivh "$@"
		;; rpmu) set -- -Uvh "$@"
		;; rpme) set -- -evh "$@"
		;; rpmqil) set -- -qil "$@"
		;; rpmqilp) set -- -qilp "$@"
		;; rpmqf)
			x_exec $rpm -q -f $rootdir/bin/"$1"
			exit not reached
		;; rpm) test "${1-}" = --footgun ||
				die "Enter '--footgun' as first arg for $c"
			shift
		;; *) die "'$c': unknown ${0##*/} rpm* command"
	esac
	x_exec $rpm "$@"
esac


#. find  :find(2) with first arg to usw root
test $c = find && exec find $rootdir "$@"


#. spec  :write template .spec for rrpmbuild.pl
if test $c = spec
then
	test $# = 1 || die "$0 spec {name}"
	case $1 in *["$IFS"]*) die "Whitespace in '$1'"; esac
	fn=$1$chi.spec
	test -f $fn && die "File '$fn' exists"
	echo "\
# edit, then try with rrpmbuild.pl -bb $fn

Name: $1
Summary: $1 summary
Version: 1
Release: 1$chi
#License: Fixme and uncomment
#BuildArch: noarch
Requires: $rootdir

%description
(multi-line description text for $1)

%prep
exit 0 %dnl prep not run anyway (rrpmbuild.pl does not)

%build
exit 0
# remove ''/tmp/x after known build/install does not accidentally write there
./configure --prefix=$rootdir''/tmp/x
make

%install
exit 1
make install DESTDIR=%buildroot

%files
%defattr/-,root,root,-)
$rootdir

%dnl eof" > $fn
	echo Wrote $fn
	exit
fi


die "'$c': unknown command"


# Local variables:
# mode: shell-script
# sh-basic-offset: 8
# tab-width: 8
# End:
# vi: set sw=8 ts=8

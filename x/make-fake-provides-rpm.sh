#!/bin/sh
#
# $ make-fake-provides-rpm.sh $
#
# Author: Tomi Ollila -- too ät iki piste fi
#
#	Copyright (c) 2024 Tomi Ollila
#	    All rights reserved
#
# Created: Sun 17 Nov 2024 09:21:31 EET too
# Last modified: Mon 18 Nov 2024 22:56:15 +0200 too

case ${BASH_VERSION-} in *.*) set -o posix; shopt -s xpg_echo; esac
case ${ZSH_VERSION-} in *.*) emulate ksh; esac

set -euf  # hint: (z|ba|da|'')sh -x thisfile [args] to trace execution

saved_IFS=$IFS; readonly saved_IFS

warn () { printf '%s\n' "$@"; } >&2
die () { printf '%s\n' '' "$@" ''; exit 1; } >&2

x () { printf '+ %s\n' "$*" >&2; "$@"; }
x_bg () { printf '+ %s\n' "$*" >&2; "$@" & }
x_env () { printf '+ %s\n' "$*" >&2; env "$@"; }
x_eval () { printf '+ %s\n' "$*" >&2; eval "$*"; }
x_exec () { printf '+ %s\n' "$*" >&2; exec "$@"; exit not reached; }

# if specfilename given, will be created with content, and not deleted later

rrpmbuild=true specfilename= version=
while test $# != 0
do case $1
	in --use-rpmbuild) rrpmbuild=false
	;; --specfilename=*)
		   specfilename=${1#*=}
		   test -f "$specfilename" && die "'$specfilename' exists"
	;; --version=*) version=${1#*=}
	;; --) shift; break
	;; -*) die "$1: unknown option (use '--' to exit option processing)"
	;; *) break
   esac
   shift
done

printf 'make using: '
if $rrpmbuild
then
	if test -x ./rrpmbuild.pl
	then rrpmbuild=./rrpmbuild.pl
	elif test -x ../rrpmbuild.pl
	then rrpmbuild=../rrpmbuild.pl
	else
	     command -v rrpmbuild.pl || die "'rrpmbuild.pl': command not found"
	     rrpmbuild=rrpmbuild.pl
	fi
else
	command -v rpmbuild || die "'rpmbuild': command not found"
	rrpmbuild=
fi
case $rrpmbuild in */*) echo $rrpmbuild; esac

test $# -gt 0 || die "Usage: ${0##*/} [options] [--] providenames..."

if test "${specfilename-}"
then
	exec 3>&1 > make-fake-provides.spec
else
	tf=`mktemp`
	exec 3>&1 > $tf
fi

if test "${version-}"
then case $version in *-*)
	release=${version##*-}
 	version=${version%-*}
     ;; *)
	release=1
     esac
else x_eval `date '+version=0.%Y%m%d release=%H%M'`
fi

echo "
%global _buildhost reproducible
#%global source_date_epoch_from_changelog Y
#%global clamp_mtime_to_source_date_epoch Y

Name:        fake-provides
Summary:     provides to satisfy dependencies, without content
Version:     $version
Release:     $release
License:     Unlicence
Buildarch:   noarch
"
printf 'Provides: %s\n' "$@"
echo "
%description
Fake provides to satisfy requirements other packages have.

This package does not provide any files.

%files
"

exec 1>&3 3>&-
test "${specfilename}" || {
	exec 8<$tf
	rm $tf
	specfilename=/dev/fd/8
}
test "$rrpmbuild" && x_exec $rrpmbuild -bb $specfilename
# else #
x_exec rpmbuild --build-in-place -D_rpmdir\ $PWD -bb $specfilename


# Local variables:
# mode: shell-script
# sh-basic-offset: 8
# tab-width: 8
# End:
# vi: set sw=8 ts=8

#!/bin/sh

case ${BASH_VERSION-} in *.*) set -o posix; shopt -s xpg_echo; esac
case ${ZSH_VERSION-} in *.*) emulate ksh; esac

set -euf  # hint: (z|ba|da|'')sh -x thisfile [args] to trace execution

LANG=C LC_ALL=C; export LANG LC_ALL; unset LANGUAGE

die () { printf '%s\n' '' "$@" ''; exit 1; } >&2

x () { printf '+ %s\n' "$*" >&2; "$@"; }

if test $# = 0
then
	echo
	echo r[r]pmbuild test program
	echo execute $0 {number} to test things:
	echo
	sed -n 's/if[ ]test "$1" =/ /p' "$0"
	echo
	exit
fi


if test "$1" = 1 # run rrpmbuild -bb test.spec w/ all compressors and levels
then
	fn () {
		script -ec "exec /usr/bin/time -p \
		./rrpmbuild.pl -bb -D '_binary_payload w$2.$1dio' test.spec"
		mv typescript build-rpms
		mv build-rpms build-rpms-$1-$2
	}
	(set +f -x; exec rm -rf build-rpms*)
	fn xz 0; fn zst 0; fn zst 10
	for l in 1 2 3 4 5 6 7 8 9
	do
		for z in gz xz zst; do fn $z $l; done
		fn $z 1$l
	done
	exit
fi

if test "$1" = 2 # exit 1 (i.e. placeholder)
then
	x exit 1
fi

die "$0: '$1': unexpected arg"


# Local variables:
# mode: shell-script
# sh-basic-offset: 8
# tab-width: 8
# End:
# vi: set sw=8 ts=8

#!/bin/sh

case ${BASH_VERSION-} in *.*) set -o posix; shopt -s xpg_echo; esac
case ${ZSH_VERSION-} in *.*) emulate ksh; esac

set -euf  # hint: (z|ba|da|'')sh -x thisfile [args] to trace execution

LANG=C LC_ALL=C; export LANG LC_ALL; unset LANGUAGE

die () { printf '%s\n' '' "$@" ''; exit 1; } >&2

x () { printf '+ %s\n' "$*" >&2; "$@"; }
x_eval () { printf '+ %s\n' "$*" >&2; eval "$*"; }
x_exec () { printf '+ %s\n' "$*" >&2; exec "$@"; }

pfx_cmd=
while	case ${1-}
	in l) x_eval 'export LD_PRELOAD=$PWD/ldpreload-peek-memcmp.so'
	;; p) test "${PFX_CMD-}" || die "PFX_CMD not defined in environment"
	      pfx_cmd=$PFX_CMD
	;; *) break
	esac
do
	shift
	continue
done

usage () { die "Usage: ${0##*/} $@"; }

export SOURCE_DATE_EPOCH=1234567890

if test $# = 0
then
	echo
	echo '(r[r]pmbuild) test program'
	echo "execute $0 [pfl...] {number} to test things:"
	echo
	sed -n 's/if[ ]test "$1" =/ /p' "$0"
	echo
	echo 'pfl: prefix letter to affect execution sometimes':
	echo '  l: export LD_PRELOAD=$PWD/ldpreload-peek-memcmp.so'
	echo '  p: prefix with trace command defined in PFX_CMD env var'
	echo
	exit
fi

if test "$1" = 1 # run rrpmbuild -bb test.spec w/ all compressors and levels
then
	fn () {
		script -ec "exec /usr/bin/time -p \
		./rrpmbuild.pl -D '_binary_payload w$2.$1dio' -bb x/test.spec"
		mv typescript build-rpms
		mv build-rpms t1-build-rpms/$1-$2
	}
	rm -rf build-rpms t1-build-rpms; mkdir t1-build-rpms
	fn xz 0; fn zst 0; fn zst 10
	for l in 1 2 3 4 5 6 7 8 9
	do
		for z in gz xz zst; do fn $z $l; done
		fn $z 1$l
	done
	exit
fi

if test "$1" = 2 # run one rpmbuild command line in podman container
then
	test $# = 1 && { echo
		echo choose a container image which has rpmbuild'(8)' below
		exec podman images --format '{{.ID}}  {{.Repository}}:{{.Tag}}'
	} >&2
	ci=$2
	shift 2
	fn () {
		x podman run -u root --pull=never --net=none --rm -it \
		       --privileged --tmpfs /tmp --tmpfs /run \
		       --env SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH \
		       -v "$PWD:$PWD" -w "$PWD" "$ci" "$@"
	}
	rm -rf t2-build-rpms; mkdir t2-build-rpms
	fn rpmbuild --build-in-place -D_rpmdir\ t2-build-rpms \
	   -D '_binary_payload w3.gzdio' -bb x/test.spec
	exit
fi

if test "$1" = 3 # install using /tmp/rrdbdd/ as dbpath (rm -rf'd first)
then
	test $# = 1 && usage "{file}.rpm"
	case $2 in *.rpm) ;; *) die "'$2' does not end with '.rpm'" ;; esac
	test -f "$2" || die "'$2': no such file"

	rm -rf /tmp/rrdbdd
	mkdir /tmp/rrdbdd
	#pfx_cmd='ltrace -f -e memcmp'
	x_exec $pfx_cmd rpm -ivh --dbpath=/tmp/rrdbdd "$2"
fi


if test "$1" = 9 # exit 1 (i.e. placeholder)
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

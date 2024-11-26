#!/bin/sh

case ${BASH_VERSION-} in *.*) set -o posix; shopt -s xpg_echo; esac
case ${ZSH_VERSION-} in *.*) emulate ksh; esac

set -euf  # hint: (z|ba|da|'')sh -x thisfile [args] to trace execution

LANG=C LC_ALL=C; export LANG LC_ALL; unset LANGUAGE

die () { printf '%s\n' '' "$@" ''; exit 1; } >&2

x () { printf '+ %s\n' "$*" >&2; "$@"; }
x_eval () { printf '+ %s\n' "$*" >&2; eval "$*"; }
x_exec () { printf '+ %s\n' "$*" >&2; exec "$@"; }

pfx_cmd= vv=
while	case ${1-}
	in l) x_eval 'export LD_PRELOAD=$PWD/ldpreload-peek-memcmp.so'
	;; p) test "${PFX_CMD-}" || die "PFX_CMD not defined in environment"
	      pfx_cmd=$PFX_CMD
	;; vv) vv=-vv
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

if test "$1" = 1 # run one rrpmbuild -bb test.spec w/
then
	rm -rf build-rpms; mkdir build-rpms # should give in -D but...
	script -ec "exec /usr/bin/time -p ./rrpmbuild.pl -bb x/test.spec"
	mv typescript build-rpms
	rm -rf t1-build-rpms
	exec \
	mv build-rpms t1-build-rpms
	exit not reached
fi

if test "$1" = 2 # run rrpmbuild -bb test.spec w/ all compressors and levels
then
	fn () {
		script -ec "exec /usr/bin/time -p \
		./rrpmbuild.pl -D '_binary_payload w$2.$1dio' -bb x/test.spec"
		mv typescript build-rpms
		mv build-rpms t2-build-rpms/$1-$2
	}
	rm -rf build-rpms t2-build-rpms; mkdir t2-build-rpms
	fn xz 0; fn zst 0; fn zst 10
	for l in 1 2 3 4 5 6 7 8 9
	do
		for z in gz xz zst; do fn $z $l; done
		fn $z 1$l
	done
	exit
fi

if test "$1" = 3 # run one rpmbuild command line in podman container
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
	rm -rf t3-build-rpms; mkdir t3-build-rpms
	fn rpmbuild --build-in-place -D_rpmdir\ t3-build-rpms \
	   -D '_binary_payload w3.gzdio' -bb x/test.spec
	exit
fi

if test "$1" = 4 # install using /tmp/rrdbdd/ as dbpath (rm -rf'd first)
then
	test $# = 1 && usage '[fake deps|deps.rpm] file.rpm'
	shift; rpm=$1; shift
	for arg
	do shift; set -- "$@" "$rpm"; rpm=$arg
	done
	case $rpm in *.rpm) ;; *) die "'$rpm' does not end with '.rpm'" ;; esac
	test -f "$rpm" || die "'$rpm': no such file"
	date=`date -u +%Y%m%d-%H%M%S`
	if test $# = 0
	then
		xrpm=
	else
		case $1 in *["$IFS"]*) die "Whitespace in '$1'"; esac
		case $#,$1 in 1,*.rpm) xrpm=$1 ;; *)
		 date=`date -u +%Y%m%d-%H%M%S`
		 x ./x/make-fake-provides-rpm.sh --version=$date -- "$@"
		 xrpm=build-rpms/fake-provides-$date.noarch.rpm
		esac
	fi
	rm -rf /tmp/rrdbdd
	mkdir /tmp/rrdbdd
	command -v rpm
	#pfx_cmd='ltrace -f -e memcmp'
	x_exec $pfx_cmd rpm $vv -ivh --dbpath=/tmp/rrdbdd $xrpm "$rpm"
fi


if test "$1" = 9 # exit 1 (copy/paste (ok, copy-region-as-kill - yank) for new)
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

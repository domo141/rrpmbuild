#!/bin/sh

# use this to collect the user-sw-yyyymmdd-hhmm.tar.xz arhive,
# copy it where needed, extract and then execute mk-usw.sh there

case ${BASH_VERSION-} in *.*) set -o posix; shopt -s xpg_echo; esac
case ${ZSH_VERSION-} in *.*) emulate ksh; esac

set -euf  # hint: (z|ba|da|'')sh -x thisfile [args] to trace execution

die () { printf '%s\n' '' "$@" ''; exit 1; } >&2

x_exec () { printf '+ %s\n' "$*" >&2; exec "$@"; exit not reached; }

eval `date -u +'d=%Y%m%d-%H%M s=%s'`
td=user-sw-$d
tf=$td.tar.xz

s=$((s / 60 * 60))

test $# -gt 0 || die "Usage: ${0##*/} '!'" '' "With '!' creates $tf"

export TAR_OPTIONS="--format=ustar --owner=root --group=root --mtime=@$s"

tar -C .. --xform "s:.*/:$td/:" --mode=0644 -chf $tf.wip \
	user-sw/usw-tmpl.sh ./rrpmbuild.pl ./rpmpeek.pl

tar -C .. --xform "s:.*/:$td/:" --mode=0755 --append -hf $tf.wip \
	user-sw/mk-usw.sh

xz -9 $tf.wip
mv $tf.wip.xz $tf
x_exec tar tvf $tf

<!-- GFM file splitting inhibitor -->

rrpmbuild
=========

This tools was initially developed to be used in Meego
Application SDK for future Nokia phones.

Since then this tool has been successfully used in packaging some
software for RHEL 6 system (among other RPM systems).

The feature set compared to (real) RPM build system is much smaller,
but in some cases this is sufficient. This tool is arguably easier
to use for simple cases.

rpmpeek
=======

A tool to view (and extract) rpm package structure and files.

mkpkgs.sh
---------

This script creates rpm and deb packages of rrpmbuild. For cross-platform
executability deb-package is created "by hand" (in fraction of a decisecond!)
and additionally to dogfood rrpmbuild rpm package is created by
`rrpmbuild.pl` itself (in second fraction of a decisecond)!

Initial import
==============

This script was used to import just rrpmbuild.pl and rpmpeek.pl from cloned
[MADDE](https://gitorious.org/meego-developer-tools/madde) repository.

```
#!/bin/sh
# -*- mode: shell-script; sh-basic-offset: 8; tab-width: 8 -*-

set -eu
#set -x

case ~ in '~') exec >&2; echo
        echo "Shell '/bin/sh' lacks some required modern shell functionality."
        echo "Try 'ksh $0${1+ $*}', 'bash $0${1+ $*}'"
        echo " or 'zsh $0${1+ $*}' instead."; echo
        exit 1
esac

case ${BASH_VERSION-} in *.*) shopt -s xpg_echo; esac
case ${ZSH_VERSION-} in *.*) setopt shwordsplit; esac

die () { echo "$@" >&2; exit 1; }

rin () { ( cd newrep && exec "$@" ); }

test ! -e newrep || die "'newrep' exists"
mkdir newrep
rin git init
mv newrep/.git/hooks newrep/.git/hooks.saved
trap 'mv newrep/.git/hooks.saved newrep/.git/hooks' 0

git log --pretty=%H src/madlib/rrpmbuild.pl src/madlib/rpmpeek.pl > commits
for commit in `tac commits`
do
        echo working on commit $commit
        rm -f b p
        git cat-file -p $commit:src/madlib/rrpmbuild.pl > b 2>/dev/null || :
        git cat-file -p $commit:src/madlib/rpmpeek.pl > p 2>/dev/null || :
        chmod -f 755 b p
        test ! -f b || { mv b newrep/rrpmbuild.pl; rin git add rrpmbuild.pl; }
        test ! -f p || { mv p newrep/rpmpeek.pl; rin git add rpmpeek.pl; }

        case `rin git status -s` in '') continue; esac

        eval  `git log -1 --pretty='an="%an" ae="%ae" at=%at cn="%cn" ce="%ce" ct=%ct' $commit`
        cmsg=`git log -1 --pretty=%B $commit`

        GIT_AUTHOR_NAME=$an GIT_AUTHOR_EMAIL=$ae GIT_AUTHOR_DATE=$at
        GIT_COMMITTER_NAME=$cn GIT_COMMITTER_EMAIL=$ce GIT_COMMITTER_DATE=$ct

        export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
                GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE

        rin git commit -m "$cmsg"
done
```

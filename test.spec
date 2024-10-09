
# ./rrpmbuild.pl [opts] -bb test.spec
# [podman run ...] rpmbuild [opts] --build-in-place -bb test.spec

Name:        test
Summary:     make test pkg with just test.spec and echo things
Version:     1
Release:     1
License:     Unlicence
#Buildarch:   noarch
#Requires:    python
BuildRequires: perl

%dnl in case of rpmbuild(8), file.spec overrides command line!
%define _binary_payload w19T.zstdio%dnl \- both of these
%global _binary_payload w0.xzdio

%description
use rpmbuild and rrpmbuild with this, see what comes out;
edit rigorousry at will...

%prep
{ set +x; } 2>/dev/null; exec 2>&1; set -x
: vv prep vv :
set -eufx
: $0 :$#: "$@"
sed '$q; s/^/: : /' "$0"
env | sort
: ^^ prep ^^ :
exit


%build
{ set +x; } 2>/dev/null; exec 2>&1; set -x
: vv build vv :
set -eufx
: $0 :$#: "$@"
:
: _target_cpu %_target_cpu
: _host_cpu %_host_cpu
: buildroot %buildroot
:
: ^^ build ^^ :
exit


%install
{ set +x; } 2>/dev/null; exec 2>&1; set -x
: vv install vv :
set -eufx
: $0 :$#: "$@"
umask 022
mkdir -p %{buildroot}/tmp
cp test.spec %{buildroot}/tmp
echo other > %{buildroot}/tmp/toinenkin
echo kikka > %{buildroot}/tmp/kuutonen
echo aito > %{buildroot}/tmp/aamu
(cd %{buildroot}/tmp && exec ln test.spec hlnk.spec)
: ^^ install ^^ :

%pre
echo pre: $0 :$#: "$@"

%post
echo post: $0 :$#: "$@"

%preun
echo preun: $0 :$#: "$@"

%postun
echo postun: $0 :$#: "$@"


%dnl # %check - (is this build, or install time)
%dnl # { set +x; } 2>/dev/null; exec 2>&1; set -x
%dnl # : vv check vv :
%dnl # set -eufx
%dnl # : $0 :$#: "$@"
%dnl # : ^^ check ^^ :


%clean
{ set +x; } 2>/dev/null; exec 2>&1; set -x
: vv clean vv :
set -eufx
: OBSOLETE :
: $0 :$#: "$@"
: ^^ clean ^^ :


%files
%defattr(-,root,root,-)
/tmp/*

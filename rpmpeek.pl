#!/usr/bin/perl

# http://www.rpm.org/max-rpm/s1-rpm-file-format-rpm-file-format.html
# http://docs.fedoraproject.org/drafts/rpm-guide-en/ch-package-structure.html

use strict;
use warnings;

$" = ', ';

my $extract = 0;
if (defined $ARGV[0]) {
    $extract = 1, shift @ARGV if $ARGV[0] eq '-x';
}

die "Usage: $0 [-x] file.rpm\n" unless defined $ARGV[0];

open I, '<', $ARGV[0] or die "Cannot open '$ARGV[0]': $!.\n";

my ($headerfile, $filesdir);
if ($extract) {
    ($headerfile = $ARGV[0]) =~ s/.rpm$//;
    sub _otw($) {
	die "Cannot extract: '$_[0]' is on the way.\n" if -e $_[0];
    }
    $filesdir = "$headerfile.files";
    $headerfile = "$headerfile.headers";
    _otw $headerfile;
    _otw $filesdir;
    open H, '>', $headerfile or die "Cannot open '$headerfile': $!.\n";
    print "Extracting '$ARGV[0]' headers into '$headerfile'\n";
    select H;
}

my ($data, $tlen, $toff) = ('', 0, 0);
sub readdata($)
{
    my $len = read I, $data, $_[0];
    die "$len != $_[0]\n" unless $len == $_[0];
    $toff = $tlen;
    $tlen += $len;
}

sub readlead()
{
    # see rpmlead.h (and rmplead.c)
    readdata 96;

    my @lead = unpack 'NCCnnZ66nnc16', $data;

    printf "\nLead: magic: %x, ", $lead[0];
    print "major: $lead[1], ";
    print "minor: $lead[2], ";
    print "type: $lead[3], ";
    print "archnum: $lead[4]\n";
    print "name: $lead[5]\n";
    print "osnum: $lead[6] ";
    print "signtype: $lead[7]\n";
    # don't print reserved (and lead is not used anyway...)
    # print $lead[8], "\n";
}

readlead;

my %knownhdrs_pri = ( 62 => 'HDRSIG', 63 => 'HDRIMM', 100 => 'HDRI18N',
		      267 => 'DSA', 268 => 'RSA', 269 => 'SHA1' );
my %knownhdrs_sig = ( 1000 => 'SIZE', 1002 => 'PGP', 1004 => 'MD5',
		      1006 => 'PGP', 1007 => 'PLSIZE' );
my %knownhdrs_hdr = (
    1000 => 'NAME', 1001 => 'VERSION', 1002 => 'RELEASE',
    1003 => 'EPOCH', 1004 => 'SUMMARY', 1005 => 'DESCRIPTION',
    1006 => 'BUILDTIME', 1007 => 'BUILDHOST', 1008 => 'INSTALLTIME',
    1009 => 'SIZE', 1010 => 'DISTRIBUTION', 1011 => 'VENDOR',
    1012 => 'GIF', 1013 => 'XPM', 1014 => 'LICENSE',
    1015 => 'PACKAGER', 1016 => 'GROUP', 1017 => 'CHANGELOG',
    1018 => 'SOURCE', 1019 => 'PATCH', 1020 => 'URL',
    1021 => 'OS', 1022 => 'ARCH', 1023 => 'PREIN',
    1024 => 'POSTIN', 1025 => 'PREUN', 1026 => 'POSTUN',
    1027 => 'OLDFILENAMES', 1028 => 'FILESIZES', 1029 => 'FILESTATES',
    1030 => 'FILEMODES', 1031 => 'FILEUIDS', 1032 => 'FILEGIDS',
    1033 => 'FILERDEVS', 1034 => 'FILEMTIMES', 1035 => 'FILEDIGESTS',
    1036 => 'FILELINKTOS', 1037 => 'FILEFLAGS', 1038 => 'ROOT',
    1039 => 'FILEUSERNAME', 1040 => 'FILEGROUPNAME', 1041 => 'EXCLUDE',
    1042 => 'EXCLUSIVE', 1043 => 'ICON', 1044 => 'SOURCERPM',
    1045 => 'FILEVERIFYFLAGS', 1046 => 'ARCHIVESIZE', 1047 => 'PROVIDENAME',
    1048 => 'REQUIREFLAGS', 1049 => 'REQUIRENAME', 1050 => 'REQUIREVERSION',
    1051 => 'NOSOURCE', 1052 => 'NOPATCH', 1053 => 'CONFLICTFLAGS',
    1054 => 'CONFLICTNAME', 1055 => 'CONFLICTVERSION', 1056 => 'DEFAULTPREFIX',
    1057 => 'BUILDROOT', 1058 => 'INSTALLPREFIX', 1059 => 'EXCLUDEARCH',
    1060 => 'EXCLUDEOS', 1061 => 'EXCLUSIVEARCH', 1062 => 'EXCLUSIVEOS',
    1063 => 'AUTOREQPROV', 1064 => 'RPMVERSION', 1065 => 'TRIGGERSCRIPTS',
    1066 => 'TRIGGERNAME', 1067 => 'TRIGGERVERSION', 1068 => 'TRIGGERFLAGS',
    1069 => 'TRIGGERINDEX', 1079 => 'VERIFYSCRIPT', 1080 => 'CHANGELOGTIME',
    1081 => 'CHANGELOGNAME', 1082 => 'CHANGELOGTEXT', 1083 => 'BROKENMD5',
    1084 => 'PREREQ', 1085 => 'PREINPROG', 1086 => 'POSTINPROG',
    1087 => 'PREUNPROG', 1088 => 'POSTUNPROG', 1089 => 'BUILDARCHS',
    1090 => 'OBSOLETENAME', 1091 => 'VERIFYSCRIPTPROG',
    1092 => 'TRIGGERSCRIPTPROG', 1093 => 'DOCDIR', 1094 => 'COOKIE',
    1095 => 'FILEDEVICES', 1096 => 'FILEINODES', 1097 => 'FILELANGS',
    1098 => 'PREFIXES', 1099 => 'INSTPREFIXES', 1100 => 'TRIGGERIN',
    1101 => 'TRIGGERUN', 1102 => 'TRIGGERPOSTUN', 1103 => 'AUTOREQ',
    1104 => 'AUTOPROV', 1105 => 'CAPABILITY', 1106 => 'SOURCEPACKAGE',
    1107 => 'OLDORIGFILENAMES', 1108 => 'BUILDPREREQ', 1109 => 'BUILDREQUIRES',
    1110 => 'BUILDCONFLICTS', 1111 => 'BUILDMACROS', 1112 => 'PROVIDEFLAGS',
    1113 => 'PROVIDEVERSION', 1114 => 'OBSOLETEFLAGS',
    1115 => 'OBSOLETEVERSION', 1116 => 'DIRINDEXES', 1117 => 'BASENAMES',
    1118 => 'DIRNAMES', 1119 => 'ORIGDIRINDEXES', 1120 => 'ORIGBASENAMES',
    1121 => 'ORIGDIRNAMES', 1122 => 'OPTFLAGS', 1123 => 'DISTURL',
    1124 => 'PAYLOADFORMAT', 1125 => 'PAYLOADCOMPRESSOR',
    1126 => 'PAYLOADFLAGS', 1127 => 'INSTALLCOLOR', 1128 => 'INSTALLTID',
    1129 => 'REMOVETID', 1130 => 'SHA1RHN', 1131 => 'RHNPLATFORM',
    1132 => 'PLATFORM', 1133 => 'PATCHESNAME', 1134 => 'PATCHESFLAGS',
    1135 => 'PATCHESVERSION', 1136 => 'CACHECTIME', 1137 => 'CACHEPKGPATH',
    1138 => 'CACHEPKGSIZE', 1139 => 'CACHEPKGMTIME', 1140 => 'FILECOLORS',
    1141 => 'FILECLASS', 1142 => 'CLASSDICT', 1143 => 'FILEDEPENDSX',
    1144 => 'FILEDEPENDSN', 1145 => 'DEPENDSDICT', 1146 => 'SOURCEPKGID',
    1147 => 'FILECONTEXTS', 1148 => 'FSCONTEXTS', 1149 => 'RECONTEXTS',
    1150 => 'POLICIES', 1151 => 'PRETRANS', 1152 => 'POSTTRANS',
    1153 => 'PRETRANSPROG', 1154 => 'POSTTRANSPROG', 1155 => 'DISTTAG',
    1156 => 'SUGGESTSNAME', 1157 => 'SUGGESTSVERSION',
    1158 => 'SUGGESTSFLAGS', 1159 => 'ENHANCESNAME',
    1160 => 'ENHANCESVERSION', 1161 => 'ENHANCESFLAGS',
    1162 => 'PRIORITY', 1163 => 'CVSID', 1164 => 'BLINKPKGID',
    1165 => 'BLINKHDRID', 1166 => 'BLINKNEVRA', 1167 => 'FLINKPKGID',
    1168 => 'FLINKHDRID', 1169 => 'FLINKNEVRA', 1170 => 'PACKAGEORIGIN',
    1171 => 'TRIGGERPREIN', 1172 => 'BUILDSUGGESTS',
    1173 => 'BUILDENHANCES', 1174 => 'SCRIPTSTATES',
    1175 => 'SCRIPTMETRICS', 1176 => 'BUILDCPUCLOCK',
    1177 => 'FILEDIGESTALGOS', 1178 => 'VARIANTS',
    1179 => 'XMAJOR', 1180 => 'XMINOR', 1181 => 'REPOTAG',
    1182 => 'KEYWORDS', 1183 => 'BUILDPLATFORMS', 1184 => 'PACKAGECOLOR',
    1185 => 'PACKAGEPREFCOLOR', 1186 => 'XATTRSDICT',
    1187 => 'FILEXATTRSX', 1188 => 'DEPATTRSDICT',
    1189 => 'CONFLICTATTRSX', 1190 => 'OBSOLETEATTRSX',
    1191 => 'PROVIDEATTRSX', 1192 => 'REQUIREATTRSX',
    1193 => 'BUILDPROVIDES', 1194 => 'BUILDOBSOLETES',
    1195 => 'DBINSTANCE', 1196 => 'NVRA', 5000 => 'FILENAMES',
    5001 => 'FILEPROVIDE', 5002 => 'FILEREQUIRE', 5003 => 'FSNAMES',
    5004 => 'FSSIZES', 5005 => 'TRIGGERCONDS', 5006 => 'TRIGGERTYPE',
    5007 => 'ORIGFILENAMES', 5008 => 'LONGFILESIZES', 5009 => 'LONGSIZE',
    5010 => 'FILECAPS', 5011 => 'FILEDIGESTALGO', 5012 => 'BUGURL',
    5013 => 'EVR', 5014 => 'NVR', 5015 => 'NEVR', 5016 => 'NEVRA',
    5017 => 'HEADERCOLOR', 5018 => 'VERBOSE', 5019 => 'EPOCHNUM'
);

sub tagstr($$)
{
#    return $_[0];
    if ($_[0] < 1000) {
	return $knownhdrs_pri{$_[0]} || 'prihdr';
    }
    if ($_[1]) {
	return $knownhdrs_sig{$_[0]} || 'sighdr';
    }
    else { return $knownhdrs_hdr{$_[0]} || 'rpmhdr'; }
}

sub dt0_null {
    my ($data, $count) = @_;
    return "null";
}
sub dt1_char {
    my ($data, $count) = @_;
    my @out = unpack "c$count", $data;
    return "char: @out";
}
sub dt2_int8 {
    my ($data, $count) = @_;
    my @out = unpack "C$count", $data;
    return "int8: @out";
}
sub dt3_int16 {
    my ($data, $count) = @_;
    my @out = unpack "n$count", $data;
    return "int16: @out";
}
sub dt4_int32 {
    my ($data, $count) = @_;
    my @out = unpack "N$count", $data;
    return "int32: @out";
}
sub dt5_int64 {
    my ($data, $count) = @_;
    return "int64 xxx";
}
sub dt6_string {
    my ($data, $count) = @_;
    my @out = split "\0", $data, $count + 1;
    pop @out if @out > $count;
    return "strings:\n" . join "\n----\n", @out if ($count > 1);
    return "string: @out";
}
sub dt7_bin {
    my ($data, $count) = @_;
    my @out = unpack "C$count", $data;
    return sprintf 'bin: ' . '%02x' x $count, @out;
}
sub dt8_strarr {
    my ($data, $count) = @_;
    my @out = split "\0", $data, $count + 1;
    pop @out if @out > $count;
    return "strarr: @out";
}
sub dt9_string_i18n {
    my ($data, $count) = @_;
    my @out = split "\0", $data, $count + 1;
    pop @out if @out > $count;
    return "strings_i18n:\n" . join "\n----\n", @out if ($count > 1);
    return "string_i18n: @out";
}

my @dtcalls = (
    \&dt0_null, \&dt1_char, \&dt2_int8, \&dt3_int16, \&dt4_int32, \&dt5_int64,
    \&dt6_string, \&dt7_bin, \&dt8_strarr, \&dt9_string_i18n
);

my ($plfmt, $plcomp) = ('cpio', 'gzip');
sub chkdatahdr($$)
{
    if ($_[0] eq '1124') { # 'PAYLOADFORMAT'
	$_[1] =~ /(\S+)\s*$/; $plfmt = $1;
    }
    elsif ($_[0] eq '1125') { # 'PAYLOADCOMPRESSOR'
	$_[1] =~ /(\S+)\s*$/; $plcomp = $1;
    }
}

sub readheader($)
{
    readdata 16;

    my ($magic, $res, $entries, $size);
    ($magic, $res, $entries, $size) = unpack('NNNN', $data);

    die "'$magic': unknown magic\n" unless $magic == 0x8eade801;

    printf "\nHeader (at %d): magic %x res %d entries %d (%d bytes) size %d\n",
	$toff, $magic, $res, $entries, ($entries + 1) * 16, $size;

    my @headers;
    for(1..$entries) {
	readdata 16;
	my @list = unpack('NNNN', $data);
	push @headers, \@list;
    }
    readdata $size;
    foreach (@headers) {
	my ($tag, $type, $offset, $count) = @$_;
	printf "%4d(%s) type %d offset %d(%d) count %d\n", $tag,
	    tagstr($tag, $_[0]), $type, $offset, $toff + $offset, $count;
	if ($type < @dtcalls) {
	    my $d = substr $data, $offset;
	    my $data = $dtcalls[$type]($d, $count);
	    print '  ', $data, "\n";
	    chkdatahdr $tag, $data unless $_[0];
	}
    }
}

# 8-align...
sub readpad8 () {
    my $pad = $tlen & 7;
    readdata 8 - $pad if $pad;
}

readheader 1;
readpad8;
readheader 0;

# XXX --no-absolute-filenames is gnu cpio extension...
my $cpiocmd = $extract?
  "(cd '$filesdir'; cpio -idv --no-absolute-filenames --quiet)":
  'cpio -t --quiet';

my %plfmtcmds = ( cpio => $cpiocmd );
my %plcompcmds = ( gzip => 'gzip -dc',
		   bzip2 => 'bzip2 -dc' );

my $plfmtcmd = $plfmtcmds{$plfmt};
die "'$plfmt': not known playload format\n" unless defined $plfmtcmd;
my $plcompcmd = $plcompcmds{$plcomp};
die "'$plcomp': not known playload compressor\n" unless defined $plcompcmd;

if ($extract) {
    mkdir $filesdir;
    print STDOUT "Extracting Archive (at $tlen) to '$filesdir'\n";
}
else {
    print "\nArchive contents (at $tlen):\n";
}

# for windows msys perl 5.6
use POSIX qw/lseek/;
my $fd = fileno I;
lseek($fd, $tlen, 0); # to reset buffered data.
open STDIN, "<&$fd"; # for perl 5.6, and windows msys.

# this works elsewhere...
#seek I, $tlen, 0 or die "$!"; # to reset buffered data.
#open STDIN, '<&=', \*I;
#open STDIN, '<&', \*I;
#open STDIN, '<&I'; # for perl 5.6

#system "set -x; $plcompcmd | $plfmtcmd";
system "$plcompcmd | $plfmtcmd";

#if 0 /* -*- mode: c; c-file-style: "stroustrup"; tab-width: 8; -*-
 set -euf
 so=${0##*''/}; so=${so%.c}.so; test -e "$so" && rm "$so"
 test $# = 0 && set -- -O2
 set -x
 ${CC:-gcc} -std=c11 -shared -fPIC -o "$so" "$0" "$@" -ldl
 exec chmod 644 $so
 exit not reached
 */
#endif
/*
 * $ ldpreload-peek-memcmp.c $
 *
 * Created: Wed 09 Oct 2024 23:58:41 +0300 too
 * Last modified: Thu 10 Oct 2024 21:56:22 +0300 too
 */

// SPDX-License-Identifier: Unlicense

// This may catch and hexdump memcmp() calls. In those cases where
// shared library calls memcmp() which is defined in the *same*
// library this does not catch those. ltrace -f -e memcmp may show
// when such a thing happens...

// gcc -dM -E -xc /dev/null | grep -i gnuc
// clang -dM -E -xc /dev/null | grep -i gnuc
#if defined (__GNUC__)

// to relax, change 'error' to 'warning' -- or even 'ignored'
// selectively. use #pragma GCC diagnostic push/pop to change
// the rules temporarily

#if 0 // use of -Wpadded gets complicated, 32 vs 64 bit systems
#pragma GCC diagnostic warning "-Wpadded"
#endif

#pragma GCC diagnostic error "-Wall"
#pragma GCC diagnostic error "-Wextra"

#if __GNUC__ >= 8 // impractically strict in gccs 5, 6 and 7
#pragma GCC diagnostic error "-Wpedantic"
#endif

#if __GNUC__ >= 7 || defined (__clang__) && __clang_major__ >= 12

// gcc manual says all kind of /* fall.*through * / regexp's work too
// but perhaps only when cpp does not filter comments out. thus...
#define FALL_THROUGH __attribute__ ((fallthrough))
#else
#define FALL_THROUGH ((void)0)
#endif

#pragma GCC diagnostic error "-Wstrict-prototypes"
#pragma GCC diagnostic error "-Winit-self"

// -Wformat=2 ¡currently! (2017-12) equivalent of the following 4
#pragma GCC diagnostic warning "-Wformat"
#pragma GCC diagnostic warning "-Wformat-nonliteral" // XXX ...
#pragma GCC diagnostic error "-Wformat-security"
#pragma GCC diagnostic error "-Wformat-y2k"

#pragma GCC diagnostic error "-Wcast-align"
#pragma GCC diagnostic error "-Wpointer-arith"
#pragma GCC diagnostic error "-Wwrite-strings"
#pragma GCC diagnostic error "-Wcast-qual"
#pragma GCC diagnostic error "-Wshadow"
#pragma GCC diagnostic error "-Wmissing-include-dirs"
#pragma GCC diagnostic error "-Wundef"
#pragma GCC diagnostic error "-Wbad-function-cast"
#ifndef __clang__
#pragma GCC diagnostic error "-Wlogical-op" // XXX ...
#endif
#pragma GCC diagnostic error "-Waggregate-return"
#pragma GCC diagnostic error "-Wold-style-definition"
#pragma GCC diagnostic error "-Wmissing-prototypes"
#pragma GCC diagnostic error "-Wmissing-declarations"
#pragma GCC diagnostic error "-Wredundant-decls"
#pragma GCC diagnostic error "-Wnested-externs"
#pragma GCC diagnostic error "-Winline"
#pragma GCC diagnostic error "-Wvla"
#pragma GCC diagnostic error "-Woverlength-strings"

//ragma GCC diagnostic error "-Wfloat-equal"
//ragma GCC diagnostic error "-Werror"
//ragma GCC diagnostic error "-Wconversion"

#endif /* defined (__GNUC__) */

#if defined(__linux__) && __linux__
#define _DEFAULT_SOURCE
#define _GNU_SOURCE

#define _ATFILE_SOURCE
#endif

#define memcmp memcmp_hidden

#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include <dlfcn.h>

#undef memcmp

static void pfdwrite2(const char * fn, const char * name, const char * arg1)
{
    char buf[4096];
    int l;
    pid_t pid = getpid();
    l = snprintf(buf, sizeof buf, "%d: %s: %s %s\n", pid, fn, name, arg1);
    if (l > (int)sizeof buf) l = (int)sizeof buf;
    (void)!write(2, buf, l);
}

__attribute__((constructor))
static void fn(int argc, const char ** argv /*, unsigned char ** envp*/)
{
    (void)argc;
    pfdwrite2("/exec/", argv[0], argv[1]);
}


static void * dlsym_next(const char * symbol)
{
    void * sym = dlsym(RTLD_NEXT, symbol);
    char * str = dlerror();

    if (str != NULL) {
	fprintf(stderr, "finding symbol '%s' failed: %s", symbol, str);
	exit(1);
    }
    return sym;
}

// Macros FTW! -- use gcc -E to examine expansion

#define _deffn(_rt, _fn, _args) \
_rt _fn _args; \
_rt _fn _args { \
    static _rt (*_fn##_next) _args = NULL; \
    if (! _fn##_next ) *(void**) (&_fn##_next) = dlsym_next(#_fn); \
    const char * fn = #_fn;


#if 1
#define cprintf(...) fprintf(stderr, __VA_ARGS__)
#else
#define cprintf(...) do {} while (0)
#endif

static void hd_16max(const void * p, size_t n)
{

    static unsigned char hex[17] = "0123456789abcdef";
    __auto_type s = (const unsigned char *)p;
    char buf[72];
    memset(buf, ' ', sizeof buf);

    if (n > 16) n = 16;
    for (size_t i = 0; i < n; i++) {
	unsigned char c = s[i];
	buf[i * 3 + 2] = hex[c >> 4];
	buf[i * 3 + 3] = hex[c & 15];
	if (c < 32 || c > 126) c = '.';
	buf[i + 54] = c;
    }
    buf[71] = '\n';
    write(2, buf, 72);
}

_deffn ( int, memcmp, (const void * m1, const void * m2, size_t n) )
#if 0
{
#endif
    (void)fn;
    int rv = memcmp_next(m1, m2, n);
    cprintf("*** memcmp(%p %p %zu) -> %d\n", m1, m2, n, rv);
    // XXX may go over buffer, but that's to know what is there after mismatch
    if (n > 0) {
	hd_16max(m1, n);
	hd_16max(m2, n);
    }
    return rv;
}

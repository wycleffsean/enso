#define _GNU_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#ifdef __APPLE__
#define _DARWIN_C_SOURCE 1
#endif

#include <string.h>
#include <stdarg.h>
#include <setjmp.h>

#ifdef __APPLE__
#include <alloca.h>
#endif

#define MIR_x86_64 1

#include "mir.c"

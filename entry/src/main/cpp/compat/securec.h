/*
 * Compatibility shim for OpenHarmony's internal <securec.h>.
 *
 * securec is an OpenHarmony-internal secure-coding library that is not
 * exposed in the public HarmonyOS NDK sysroot.  The vendored hdc sources use
 * exactly nine of its functions, in roughly 190 call sites.  Each one is
 * re-implemented here over plain libc with the same signature and the same
 * contract: on a bad argument or a buffer that is too small, return non-zero
 * and leave the destination untouched.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef SW_SHELL_COMPAT_SECUREC_H
#define SW_SHELL_COMPAT_SECUREC_H

#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

typedef int errno_t;

#ifndef EOK
#define EOK 0
#endif

static inline errno_t memset_s(void *dest, size_t destMax, int c, size_t count)
{
    if (dest == NULL || destMax < count) {
        return 1;
    }
    if (count > 0) {
        memset(dest, c, count);
    }
    return EOK;
}

static inline errno_t memcpy_s(void *dest, size_t destMax, const void *src, size_t count)
{
    if (dest == NULL || src == NULL || destMax < count) {
        return 1;
    }
    if (count > 0) {
        memcpy(dest, src, count);
    }
    return EOK;
}

static inline errno_t memmove_s(void *dest, size_t destMax, const void *src, size_t count)
{
    if (dest == NULL || src == NULL || destMax < count) {
        return 1;
    }
    if (count > 0) {
        memmove(dest, src, count);
    }
    return EOK;
}

static inline errno_t strcpy_s(char *destStr, size_t destMax, const char *srcStr)
{
    if (destStr == NULL || srcStr == NULL) {
        return 1;
    }
    size_t len = strlen(srcStr);
    if (len >= destMax) {
        return 1;
    }
    memcpy(destStr, srcStr, len + 1);
    return EOK;
}

static inline errno_t strncpy_s(char *destStr, size_t destMax, const char *srcStr, size_t count)
{
    if (destStr == NULL || srcStr == NULL) {
        return 1;
    }
    size_t len = strnlen(srcStr, count);
    if (len >= destMax) {
        return 1;
    }
    memcpy(destStr, srcStr, len);
    destStr[len] = '\0';
    return EOK;
}

/*
 * The printf family returns the number of characters written, and a negative
 * value on error - that is what the upstream sources test for
 * ("< 0" means failure, "> 0" means something was written).  Returning an
 * errno here silently truncates every string the vendored code formats,
 * including the protocol version string.
 */
static inline int snprintf_s(char *strDest, size_t destMax, size_t count, const char *format, ...)
{
    (void)count;
    if (strDest == NULL || destMax == 0) {
        return -1;
    }
    va_list ap;
    va_start(ap, format);
    int ret = vsnprintf(strDest, destMax, format, ap);
    va_end(ap);
    return ret;
}

static inline int vsnprintf_s(char *strDest, size_t destMax, size_t count, const char *format, va_list ap)
{
    (void)count;
    if (strDest == NULL || destMax == 0) {
        return -1;
    }
    return vsnprintf(strDest, destMax, format, ap);
}

static inline int sprintf_s(char *strDest, size_t destMax, const char *format, ...)
{
    if (strDest == NULL || destMax == 0) {
        return -1;
    }
    va_list ap;
    va_start(ap, format);
    int ret = vsnprintf(strDest, destMax, format, ap);
    va_end(ap);
    return (ret < 0 || (size_t)ret >= destMax) ? -1 : ret;
}

/*
 * OpenHarmony's strtok_s takes the destination buffer, its size, the
 * delimiter and a context pointer, and copies the token into the
 * destination.  The libc strtok_r has the same shape minus the copy.
 */
/* securec's strtok_s returns the token, or NULL when there is none. */
static inline char *strtok_s(char *dest, size_t destMax, const char *delimiter, char **context)
{
    if (dest == NULL || context == NULL || delimiter == NULL) {
        return NULL;
    }
    (void)destMax;
    char *token = strtok_r(*context, delimiter, context);
    if (token == NULL) {
        return NULL;
    }
    memmove(dest, token, strlen(token) + 1);
    return dest;
}

#endif /* SW_SHELL_COMPAT_SECUREC_H */

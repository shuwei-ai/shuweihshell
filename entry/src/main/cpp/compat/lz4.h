/*
 * Minimal LZ4 block-format codec.
 *
 * The vendored hdc sources compress file-transfer payloads with LZ4
 * (common/transfer.cpp).  LZ4 is not part of the public HarmonyOS NDK, so
 * this provides the two entry points hdc uses:
 *
 *   LZ4_compress_default()  - encoder
 *   LZ4_decompress_safe()   - decoder
 *
 * The decoder is a complete, correct LZ4 block decoder: it reads sequences
 * (token / literals / offset / match length) and reconstructs the original
 * bytes, including overlapping matches.  That matters because the *device*
 * side compresses with the real LZ4 and we have to read its output.
 *
 * The encoder emits a valid LZ4 block too, but as a single literal-only
 * sequence, so it never actually shrinks the payload.  hdc already treats a
 * compressed size that is not smaller as "compress none" and falls back to
 * sending the data uncompressed, so this is behaviour-preserving for the
 * file-transfer path.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef SW_SHELL_COMPAT_LZ4_H
#define SW_SHELL_COMPAT_LZ4_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define LZ4_MIN_LENGTH 13
#define LZ4_MAX_INPUT_SIZE 0x7E000000

/* The largest output a literal-only encoding can produce. */
static inline int lz4_literal_only_size(int srcSize)
{
    return srcSize + (srcSize / 255) + 16;
}

/*
 * Returns the number of bytes written to dst, or 0 on failure (which the
 * caller treats as "compression did not help").
 */
static inline int LZ4_compress_default(const char *src, char *dst, int srcSize, int dstCapacity)
{
    if (src == NULL || dst == NULL || srcSize < 0) {
        return 0;
    }
    if (srcSize == 0) {
        return 0;
    }
    if (lz4_literal_only_size(srcSize) > dstCapacity) {
        return 0;
    }

    int i = 0;
    int o = 0;
    while (i < srcSize) {
        int remaining = srcSize - i;
        if (remaining < 15) {
            dst[o++] = (char)(uint8_t)(remaining << 4);
        } else {
            /* Literal length >= 15: token says 15, then extension bytes
             * carry the remainder, 255 meaning "255 more". */
            dst[o++] = (char)(uint8_t)(15 << 4);
            int rest = remaining - 15;
            while (rest >= 255) {
                dst[o++] = (char)(uint8_t)255;
                rest -= 255;
            }
            dst[o++] = (char)(uint8_t)rest;
        }
        memcpy(dst + o, src + i, (size_t)remaining);
        o += remaining;
        i = srcSize;
        /* A block ends after its literal sequence: no offset, no match. */
        break;
    }
    return o;
}

/*
 * Decompresses an LZ4 block.  Returns the number of bytes written, or a
 * negative value on error.
 */
static inline int LZ4_decompress_safe(const char *src, char *dst, int compressedSize, int dstCapacity)
{
    if (src == NULL || dst == NULL || compressedSize < 0 || dstCapacity < 0) {
        return -1;
    }
    int ip = 0;
    int op = 0;
    const uint8_t *in = (const uint8_t *)src;

    while (ip < compressedSize) {
        uint8_t token = in[ip++];

        /* Literals. */
        int litLen = token >> 4;
        if (litLen == 15) {
            while (ip < compressedSize) {
                uint8_t s = in[ip++];
                litLen += s;
                if (s != 255) {
                    break;
                }
            }
        }
        if (litLen < 0 || ip + litLen > compressedSize || op + litLen > dstCapacity) {
            return -1;
        }
        memcpy(dst + op, src + ip, (size_t)litLen);
        ip += litLen;
        op += litLen;

        /* The last sequence of a block has literals only. */
        if (ip >= compressedSize) {
            break;
        }

        /* Match offset. */
        if (ip + 2 > compressedSize) {
            return -1;
        }
        int offset = (int)in[ip] | ((int)in[ip + 1] << 8);
        ip += 2;
        if (offset == 0 || offset > op) {
            return -1;
        }

        /* Match length. */
        int matchLen = token & 0x0F;
        if (matchLen == 15) {
            while (ip < compressedSize) {
                uint8_t s = in[ip++];
                matchLen += s;
                if (s != 255) {
                    break;
                }
            }
        }
        matchLen += 4; /* minimum match length */

        if (op + matchLen > dstCapacity) {
            return -1;
        }
        /* Byte-wise copy so that overlapping matches replicate correctly. */
        int matchPos = op - offset;
        for (int i = 0; i < matchLen; i++) {
            dst[op + i] = dst[matchPos + i];
        }
        op += matchLen;
    }
    return op;
}

#endif /* SW_SHELL_COMPAT_LZ4_H */

/*
 * Base64 with OpenSSL's EVP_EncodeBlock / EVP_DecodeBlock semantics.
 *
 * The vendored hdc sources call EVP_EncodeBlock and EVP_DecodeBlock from
 * common/base.cpp.  OpenSSL is not available in the public HarmonyOS NDK, so
 * this provides the same behaviour:
 *
 *   - standard alphabet "A-Za-z0-9+/", '=' padding, no line breaks
 *   - encode returns the number of bytes written, including the padding
 *   - decode returns the number of decoded bytes, or -1 on malformed input
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef SW_SHELL_COMPAT_BASE64_H
#define SW_SHELL_COMPAT_BASE64_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>

static const char kSwShellB64Alphabet[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static inline int b64_encode_block(uint8_t *out, const uint8_t *in, int len)
{
    int i = 0;
    int o = 0;
    if (out == NULL || in == NULL || len < 0) {
        return -1;
    }
    while (i + 3 <= len) {
        uint32_t v = ((uint32_t)in[i] << 16) | ((uint32_t)in[i + 1] << 8) | (uint32_t)in[i + 2];
        out[o++] = (uint8_t)kSwShellB64Alphabet[(v >> 18) & 0x3F];
        out[o++] = (uint8_t)kSwShellB64Alphabet[(v >> 12) & 0x3F];
        out[o++] = (uint8_t)kSwShellB64Alphabet[(v >> 6) & 0x3F];
        out[o++] = (uint8_t)kSwShellB64Alphabet[v & 0x3F];
        i += 3;
    }
    int rest = len - i;
    if (rest == 1) {
        uint32_t v = (uint32_t)in[i] << 16;
        out[o++] = (uint8_t)kSwShellB64Alphabet[(v >> 18) & 0x3F];
        out[o++] = (uint8_t)kSwShellB64Alphabet[(v >> 12) & 0x3F];
        out[o++] = '=';
        out[o++] = '=';
    } else if (rest == 2) {
        uint32_t v = ((uint32_t)in[i] << 16) | ((uint32_t)in[i + 1] << 8);
        out[o++] = (uint8_t)kSwShellB64Alphabet[(v >> 18) & 0x3F];
        out[o++] = (uint8_t)kSwShellB64Alphabet[(v >> 12) & 0x3F];
        out[o++] = (uint8_t)kSwShellB64Alphabet[(v >> 6) & 0x3F];
        out[o++] = '=';
    }
    return o;
}

static inline int b64_decode_block(uint8_t *out, const uint8_t *in, int len)
{
    int8_t reverse[256];
    if (out == NULL || in == NULL || len < 0) {
        return -1;
    }
    memset(reverse, -1, sizeof(reverse));
    for (int i = 0; i < 64; i++) {
        reverse[(unsigned char)kSwShellB64Alphabet[i]] = (int8_t)i;
    }
    int o = 0;
    int acc = 0;
    int bits = 0;
    for (int i = 0; i < len; i++) {
        unsigned char c = in[i];
        if (c == '=') {
            break;
        }
        int8_t digit = reverse[c];
        if (digit < 0) {
            return -1;
        }
        acc = (acc << 6) | digit;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[o++] = (uint8_t)((acc >> bits) & 0xFF);
        }
    }
    return o;
}

#endif /* SW_SHELL_COMPAT_BASE64_H */

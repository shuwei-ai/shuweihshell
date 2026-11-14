/*
 * Upstream generates this header at build time with scripts/hdc_hash_gen.py.
 * Its entire content is one macro: the first 16 hex characters of the SHA-256
 * of the upstream source tree, which the client appends to the version string
 * it sends in the handshake.
 *
 * We are not building the upstream tree - we are building a patched copy of
 * it - so the correct value is the hash of *our* tree.
 *
 * The device checks the shape of the version string: "Ver: " + the version
 * + sixteen hex characters.  A hash that is not hexadecimal makes the daemon
 * reject the handshake as "client version too low".
 *
 * Regenerate with:
 *   find entry/src/main/cpp/vendor/hdc -type f \( -name '*.cpp' -o -name '*.h' \) \
 *     | sort | xargs cat | shasum -a 256 | cut -c1-16
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef HDC_HASH_GEN_H
#define HDC_HASH_GEN_H

#define HDC_MSG_HASH "4a75add763b60a27"

#endif /* HDC_HASH_GEN_H */

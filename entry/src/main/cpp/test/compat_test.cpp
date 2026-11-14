/*
 * Tests for the compatibility shims.
 *
 * These are the pieces we wrote rather than vendored, so they are the most
 * likely place for a subtle bug.  They run on the host:
 *
 *     clang++ -std=c++17 -I entry/src/main/cpp/compat \
 *         entry/src/main/cpp/test/compat_test.cpp -o /tmp/compat_test && /tmp/compat_test
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include <cassert>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "lz4.h"
#include "ohos_base64.h"
#include "securec.h"

namespace {

int gFailures = 0;

void Check(bool condition, const char *what)
{
    if (!condition) {
        printf("FAIL %s\n", what);
        gFailures++;
    }
}

std::string Encode(const std::string &input)
{
    std::string out;
    out.resize((input.size() + 2) / 3 * 4 + 4);
    int written = b64_encode_block(reinterpret_cast<uint8_t *>(&out[0]),
                                   reinterpret_cast<const uint8_t *>(input.data()),
                                   static_cast<int>(input.size()));
    out.resize(written > 0 ? static_cast<size_t>(written) : 0);
    return out;
}

std::string Decode(const std::string &input)
{
    std::vector<uint8_t> out(input.size() / 4 * 3 + 3);
    int written = b64_decode_block(out.data(), reinterpret_cast<const uint8_t *>(input.data()),
                                   static_cast<int>(input.size()));
    if (written <= 0) {
        return std::string();
    }
    out.resize(static_cast<size_t>(written));
    return std::string(reinterpret_cast<const char *>(out.data()), out.size());
}

void TestBase64()
{
    /* The canonical RFC 4648 vectors. */
    Check(Encode("") == "", "base64 of the empty string");
    Check(Encode("f") == "Zg==", "base64 of 'f'");
    Check(Encode("fo") == "Zm8=", "base64 of 'fo'");
    Check(Encode("foo") == "Zm9v", "base64 of 'foo'");
    Check(Encode("foob") == "Zm9vYg==", "base64 of 'foob'");
    Check(Encode("fooba") == "Zm9vYmE=", "base64 of 'fooba'");
    Check(Encode("foobar") == "Zm9vYmFy", "base64 of 'foobar'");

    Check(Decode("Zg==") == "f", "base64 decode of 'Zg=='");
    Check(Decode("Zm8=") == "fo", "base64 decode of 'Zm8='");
    Check(Decode("Zm9v") == "foo", "base64 decode of 'Zm9v'");
    Check(Decode("Zm9vYg==") == "foob", "base64 decode of 'Zm9vYg=='");
    Check(Decode("Zm9vYmE=") == "fooba", "base64 decode of 'Zm9vYmE='");
    Check(Decode("Zm9vYmFy") == "foobar", "base64 decode of 'Zm9vYmFy'");

    /* Round trip over every byte value. */
    std::string all;
    for (int i = 0; i < 256; i++) {
        all.push_back(static_cast<char>(i));
    }
    Check(Decode(Encode(all)) == all, "base64 round trip over all byte values");

    /* The empty and malformed cases. */
    Check(Decode("").empty(), "base64 decode of an empty string");
    Check(Decode("Zm9v!").empty(), "base64 decode of a malformed string");
}

void TestLz4()
{
    /*
     * The encoder emits a literal-only block, which is a valid LZ4 block.
     * The decoder has to read back what a real LZ4 encoder produces, so
     * the vectors below are hand-built LZ4 blocks.
     */

    /* Literal-only block: token 0x50 (5 literals), then "hello". */
    const uint8_t literalOnly[] = { 0x50, 'h', 'e', 'l', 'l', 'o' };
    char out[64] = { 0 };
    int written = LZ4_decompress_safe(reinterpret_cast<const char *>(literalOnly), out, sizeof(literalOnly), sizeof(out));
    Check(written == 5, "LZ4 decode of a literal-only block");
    Check(std::string(out, 5) == "hello", "LZ4 literal-only block content");

    /*
     * A block with a match: token 0x10 (1 literal, match length 0 + the LZ4 minimum of 4),
     * literal 'a', offset 1 (two bytes, little endian), then the match
     * repeats the last byte four times -> "aaaaa".
     */
    const uint8_t withMatch[] = { 0x10, 'a', 0x01, 0x00 };
    char out2[64] = { 0 };
    written = LZ4_decompress_safe(reinterpret_cast<const char *>(withMatch), out2, sizeof(withMatch), sizeof(out2));
    Check(written == 5, "LZ4 decode of a block with a match");
    Check(std::string(out2, 5) == "aaaaa", "LZ4 overlapping match content");

    /* A truncated block must be rejected rather than read out of bounds. */
    const uint8_t truncated[] = { 0x50, 'h' };
    char out3[64] = { 0 };
    Check(LZ4_decompress_safe(reinterpret_cast<const char *>(truncated), out3, sizeof(truncated), sizeof(out3)) < 0,
          "LZ4 decode of a truncated block is rejected");

    /* An offset that points before the start of the output is invalid. */
    const uint8_t badOffset[] = { 0x10, 'a', 0x05, 0x00 };
    char out4[64] = { 0 };
    Check(LZ4_decompress_safe(reinterpret_cast<const char *>(badOffset), out4, sizeof(badOffset), sizeof(out4)) < 0,
          "LZ4 decode of a block with an out-of-range offset is rejected");

    /* Our own encoder round trips. */
    std::string payload;
    for (int i = 0; i < 300; i++) {
        payload.push_back(static_cast<char>(i % 251));
    }
    std::vector<char> compressed(lz4_literal_only_size(static_cast<int>(payload.size())));
    int encoded = LZ4_compress_default(payload.data(), compressed.data(), static_cast<int>(payload.size()),
                                       static_cast<int>(compressed.size()));
    Check(encoded > 0, "LZ4 compress produces output");
    std::vector<char> restored(compressed.size());
    written = LZ4_decompress_safe(compressed.data(), restored.data(), encoded, static_cast<int>(restored.size()));
    Check(written == static_cast<int>(payload.size()), "LZ4 round trip length");
    Check(std::string(restored.data(), written) == payload, "LZ4 round trip content");
}

void TestSecurec()
{
    char buffer[16] = { 0 };
    Check(memset_s(buffer, sizeof(buffer), 'a', 4) == EOK, "securec memset_s succeeds");
    Check(buffer[0] == 'a' && buffer[3] == 'a' && buffer[4] == '\0', "securec memset_s content");
    Check(memset_s(buffer, 2, 'a', 4) != EOK, "securec memset_s rejects a short buffer");

    char source[] = "hello";
    char copy[16] = { 0 };
    Check(strcpy_s(copy, sizeof(copy), source) == EOK, "securec strcpy_s succeeds");
    Check(std::string(copy) == "hello", "securec strcpy_s content");
    Check(strcpy_s(copy, 3, source) != EOK, "securec strcpy_s rejects a short buffer");

    char formatted[32] = { 0 };
    Check(snprintf_s(formatted, sizeof(formatted), sizeof(formatted), "%s-%d", "x", 7) > 0, "securec snprintf_s succeeds");
    Check(std::string(formatted) == "x-7", "securec snprintf_s content");
}

}  // namespace

int main()
{
    TestBase64();
    TestLz4();
    TestSecurec();

    if (gFailures == 0) {
        printf("all compat shim tests passed\n");
        return 0;
    }
    printf("%d compat shim test(s) failed\n", gFailures);
    return 1;
}

/*
 * Host-executable unit tests for pure C++ SSH-2.0 protocol helpers and RFC 7748 X25519.
 */
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "ssh_protocol.h"

namespace {

int gFailures = 0;

void Check(bool condition, const char *what)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++gFailures;
    }
}

std::vector<uint8_t> HexToBytes(const char *hex)
{
    std::vector<uint8_t> out;
    size_t len = std::strlen(hex);
    for (size_t i = 0; i + 1 < len; i += 2) {
        auto nibble = [](char c) -> uint8_t {
            if (c >= '0' && c <= '9') return static_cast<uint8_t>(c - '0');
            if (c >= 'a' && c <= 'f') return static_cast<uint8_t>(10 + (c - 'a'));
            if (c >= 'A' && c <= 'F') return static_cast<uint8_t>(10 + (c - 'A'));
            return 0;
        };
        out.push_back(static_cast<uint8_t>((nibble(hex[i]) << 4) | nibble(hex[i + 1])));
    }
    return out;
}

// Standalone SHA-256 (FIPS 180-4) so host tests verify RFC 4253 key derivation & OpenSSH fingerprints
bool TestSha256(const uint8_t *data, size_t len, uint8_t out[32])
{
    static const uint32_t k[64] = {
        0x428a2f98U, 0x71374491U, 0xb5c0fbcfU, 0xe9b5dba5U, 0x3956c25bU, 0x59f111f1U, 0x923f82a4U, 0xab1c5ed5U,
        0xd807aa98U, 0x12835b01U, 0x243185beU, 0x550c7dc3U, 0x72be5d74U, 0x80deb1feU, 0x9bdc06a7U, 0xc19bf174U,
        0xe49b69c1U, 0xefbe4786U, 0x0fc19dc6U, 0x240ca1ccU, 0x2de92c6fU, 0x4a7484aaU, 0x5cb0a9dcU, 0x76f988daU,
        0x983e5152U, 0xa831c66dU, 0xb00327c8U, 0xbf597fc7U, 0xc6e00bf3U, 0xd5a79147U, 0x06ca6351U, 0x14292967U,
        0x27b70a85U, 0x2e1b2138U, 0x4d2c6dfcU, 0x53380d13U, 0x650a7354U, 0x766a0abbU, 0x81c2c92eU, 0x92722c85U,
        0xa2bfe8a1U, 0xa81a664bU, 0xc24b8b70U, 0xc76c51a3U, 0xd192e819U, 0xd6990624U, 0xf40e3585U, 0x106aa070U,
        0x19a4c116U, 0x1e376c08U, 0x2748774cU, 0x34b0bcb5U, 0x391c0cb3U, 0x4ed8aa4aU, 0x5b9cca4fU, 0x682e6ff3U,
        0x748f82eeU, 0x78a5636fU, 0x84c87814U, 0x8cc70208U, 0x90befffaU, 0xa4506cebU, 0xbef9a3f7U, 0xc67178f2U
    };
    auto rotr = [](uint32_t x, uint32_t n) -> uint32_t { return (x >> n) | (x << (32U - n)); };
    uint32_t h[8] = {
        0x6a09e667U, 0xbb67ae85U, 0x3c6ef372U, 0xa54ff53aU,
        0x510e527fU, 0x9b05688cU, 0x1f83d9abU, 0x5be0cd19U
    };

    std::vector<uint8_t> msg(data, data + len);
    uint64_t bitLen = static_cast<uint64_t>(len) * 8ULL;
    msg.push_back(0x80U);
    while ((msg.size() % 64) != 56) {
        msg.push_back(0x00U);
    }
    for (int shift = 56; shift >= 0; shift -= 8) {
        msg.push_back(static_cast<uint8_t>((bitLen >> shift) & 0xffU));
    }

    for (size_t off = 0; off < msg.size(); off += 64) {
        uint32_t w[64];
        for (int i = 0; i < 16; ++i) {
            w[i] = (static_cast<uint32_t>(msg[off + i * 4]) << 24) |
                   (static_cast<uint32_t>(msg[off + i * 4 + 1]) << 16) |
                   (static_cast<uint32_t>(msg[off + i * 4 + 2]) << 8) |
                   static_cast<uint32_t>(msg[off + i * 4 + 3]);
        }
        for (int i = 16; i < 64; ++i) {
            uint32_t s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
            uint32_t s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        uint32_t a = h[0], b = h[1], c = h[2], d = h[3];
        uint32_t e = h[4], f = h[5], g = h[6], hh = h[7];
        for (int i = 0; i < 64; ++i) {
            uint32_t S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
            uint32_t ch = (e & f) ^ ((~e) & g);
            uint32_t temp1 = hh + S1 + ch + k[i] + w[i];
            uint32_t S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
            uint32_t maj = (a & b) ^ (a & c) ^ (b & c);
            uint32_t temp2 = S0 + maj;
            hh = g;
            g = f;
            f = e;
            e = d + temp1;
            d = c;
            c = b;
            b = a;
            a = temp1 + temp2;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d;
        h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }

    for (int i = 0; i < 8; ++i) {
        out[i * 4] = static_cast<uint8_t>((h[i] >> 24) & 0xffU);
        out[i * 4 + 1] = static_cast<uint8_t>((h[i] >> 16) & 0xffU);
        out[i * 4 + 2] = static_cast<uint8_t>((h[i] >> 8) & 0xffU);
        out[i * 4 + 3] = static_cast<uint8_t>(h[i] & 0xffU);
    }
    return true;
}

void TestSshBufAndMpint()
{
    swshell::ssh::SshBuf w;
    w.WriteUint8(42);
    w.WriteBool(true);
    w.WriteUint32(0x12345678U);
    w.WriteString("ssh-ed25519");
    w.WriteNameList({"curve25519-sha256", "aes256-ctr"});
    w.WriteMpint({0x00, 0x00, 0x80, 0x01});

    swshell::ssh::SshBuf r(w.Bytes());
    uint8_t u8 = 0;
    bool b = false;
    uint32_t u32 = 0;
    std::string s, nl;
    std::vector<uint8_t> mpintRaw, mpintNorm;
    Check(r.ReadUint8(u8) && u8 == 42, "SshBuf ReadUint8");
    Check(r.ReadBool(b) && b, "SshBuf ReadBool");
    Check(r.ReadUint32(u32) && u32 == 0x12345678U, "SshBuf ReadUint32");
    Check(r.ReadString(s) && s == "ssh-ed25519", "SshBuf ReadString");
    Check(r.ReadString(nl) && nl == "curve25519-sha256,aes256-ctr", "SshBuf WriteNameList");
    Check(r.ReadBytes(mpintRaw) && mpintRaw == std::vector<uint8_t>({0x00, 0x80, 0x01}), "mpint sign byte normalization");
    Check(r.Remaining() == 0, "SshBuf consumed completely");
    Check(!r.ReadUint8(u8), "SshBuf EOF read rejected");

    Check(swshell::ssh::EncodeMpintPayload({0x00, 0x00}).empty(), "EncodeMpintPayload zero is empty");
    Check(swshell::ssh::EncodeMpintPayload({0x00, 0x7f}) == std::vector<uint8_t>({0x7f}), "EncodeMpintPayload positive < 0x80");
}

void TestX25519Rfc7748Vectors()
{
    // RFC 7748 Section 6.1 official Diffie-Hellman test vectors
    const auto alicePriv = HexToBytes("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
    const auto alicePubExpected = HexToBytes("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a");
    const auto bobPriv = HexToBytes("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
    const auto bobPubExpected = HexToBytes("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f");
    const auto sharedExpected = HexToBytes("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742");

    uint8_t alicePub[32] = {0};
    uint8_t bobPub[32] = {0};
    swshell::ssh::X25519PublicFromPrivate(alicePub, alicePriv.data());
    swshell::ssh::X25519PublicFromPrivate(bobPub, bobPriv.data());
    Check(std::memcmp(alicePub, alicePubExpected.data(), 32) == 0, "RFC 7748 Alice public key");
    Check(std::memcmp(bobPub, bobPubExpected.data(), 32) == 0, "RFC 7748 Bob public key");

    uint8_t sharedAB[32] = {0};
    uint8_t sharedBA[32] = {0};
    swshell::ssh::X25519ScalarMult(sharedAB, alicePriv.data(), bobPub);
    swshell::ssh::X25519ScalarMult(sharedBA, bobPriv.data(), alicePub);
    Check(std::memcmp(sharedAB, sharedExpected.data(), 32) == 0, "RFC 7748 Alice*Bob shared secret");
    Check(std::memcmp(sharedBA, sharedExpected.data(), 32) == 0, "RFC 7748 Bob*Alice shared secret");
}

void TestPacketFramingAndKeyDerivation()
{
    auto detRng = [](uint8_t *out, size_t len) -> bool {
        for (size_t i = 0; i < len; ++i) {
            out[i] = static_cast<uint8_t>(i + 1);
        }
        return true;
    };

    std::vector<uint8_t> payload = { 5, 'h', 'e', 'l', 'l', 'o' };
    auto framed = swshell::ssh::FrameSshPacket(payload, 16, detRng);
    Check(framed.size() % 16 == 0, "Framed SSH packet respects 16-byte cipher alignment");
    Check(framed[4] >= 4, "Framed SSH packet enforces >=4 random padding bytes");

    std::vector<uint8_t> unframed;
    Check(swshell::ssh::UnframeSshPacket(framed, unframed) && unframed == payload, "UnframeSshPacket round-trip");

    std::vector<uint8_t> corrupted = framed;
    corrupted[4] = 2;  // invalid pad < 4
    Check(!swshell::ssh::UnframeSshPacket(corrupted, unframed), "UnframeSshPacket rejects padLen < 4");

    uint8_t cPub[32] = {1};
    uint8_t sPub[32] = {2};
    auto hIn = swshell::ssh::BuildCurve25519ExchangeHashInput(
        "SSH-2.0-Client", "SSH-2.0-Server", {20, 1}, {20, 2}, {0, 0, 0, 1, 9}, cPub, sPub, {0x99, 0xaa});
    uint8_t hDigest[32] = {0};
    Check(TestSha256(hIn.data(), hIn.size(), hDigest), "Compute H exchange hash");

    std::vector<uint8_t> keyA, keyC64;
    Check(swshell::ssh::DeriveSshKey({0x99, 0xaa}, hDigest, 'A', hDigest, 16, TestSha256, keyA) && keyA.size() == 16,
          "DeriveSshKey 16-byte IV");
    Check(swshell::ssh::DeriveSshKey({0x99, 0xaa}, hDigest, 'C', hDigest, 64, TestSha256, keyC64) && keyC64.size() == 64,
          "DeriveSshKey iterative 64-byte key");
    Check(keyA != std::vector<uint8_t>(keyC64.begin(), keyC64.begin() + 16), "Different letters derive distinct keys");
}

void TestDerPemAndSignatures()
{
    // Ed25519 host key blob -> 44-byte SPKI DER
    swshell::ssh::SshBuf edBlob;
    edBlob.WriteString("ssh-ed25519");
    std::vector<uint8_t> edRaw(32, 0x42);
    edBlob.WriteString(edRaw);

    std::string algo;
    std::vector<uint8_t> spki;
    Check(swshell::ssh::SshHostKeyToSpkiDer(edBlob.Bytes(), algo, spki) &&
              algo == "ssh-ed25519" && spki.size() == 44 && spki[0] == 0x30,
          "Ed25519 SPKI DER conversion");

    std::string fp;
    Check(swshell::ssh::ComputeSshFingerprint(edBlob.Bytes(), TestSha256, fp) &&
              fp.rfind("SHA256:", 0) == 0 && fp.find('=') == std::string::npos,
          "OpenSSH SHA256 fingerprint format (unpadded base64)");

    // RSA host key blob construction & SPKI conversion
    auto rsaBlob = swshell::ssh::BuildSshRsaPubKeyBlob({0x01, 0x00, 0x01}, {0xc3, 0x01, 0x02, 0x03});
    Check(swshell::ssh::SshHostKeyToSpkiDer(rsaBlob, algo, spki) && algo == "ssh-rsa" && spki[0] == 0x30,
          "RSA SPKI DER conversion");

    // ECDSA P-256 host key blob & (r, s) -> DER signature conversion
    swshell::ssh::SshBuf ecBlob;
    ecBlob.WriteString("ecdsa-sha2-nistp256");
    ecBlob.WriteString("nistp256");
    std::vector<uint8_t> pt(65, 0x11);
    pt[0] = 0x04;
    ecBlob.WriteString(pt);
    Check(swshell::ssh::SshHostKeyToSpkiDer(ecBlob.Bytes(), algo, spki) &&
              algo == "ecdsa-sha2-nistp256" && spki.size() == 91,
          "ECDSA nistp256 SPKI DER conversion");

    swshell::ssh::SshBuf rsInner;
    rsInner.WriteMpint({0x90, 0x01});  // MSB set -> DER integer should get leading 0x00
    rsInner.WriteMpint({0x05});
    swshell::ssh::SshBuf sigWire;
    sigWire.WriteString("ecdsa-sha2-nistp256");
    sigWire.WriteString(rsInner.Bytes());
    std::string sigAlgo;
    std::vector<uint8_t> derSig;
    Check(swshell::ssh::ParseSshSignatureBlob(sigWire.Bytes(), sigAlgo, derSig) &&
              sigAlgo == "ecdsa-sha2-nistp256" && derSig.size() == 10 && derSig[0] == 0x30 && derSig[1] == 0x08 &&
              derSig[2] == 0x02 && derSig[3] == 0x03 && derSig[4] == 0x00 && derSig[5] == 0x90 &&
              derSig[7] == 0x02 && derSig[8] == 0x01 && derSig[9] == 0x05,
          "ECDSA signature mpint pair -> ASN.1 SEQUENCE");

    // PKCS#1 -> PKCS#8 wrapping + PEM decoding
    std::vector<uint8_t> fakePkcs1 = { 0x30, 0x03, 0x02, 0x01, 0x00 };
    auto pkcs8 = swshell::ssh::WrapPkcs1RsaPrivateKeyInPkcs8Der(fakePkcs1);
    Check(pkcs8.size() == 2 + 3 + 15 + 2 + fakePkcs1.size() && pkcs8[0] == 0x30, "WrapPkcs1RsaPrivateKeyInPkcs8Der");

    const std::string pem = "-----BEGIN RSA PRIVATE KEY-----\nMAMCAQA=\n-----END RSA PRIVATE KEY-----\n";
    std::string label;
    std::vector<uint8_t> decoded;
    Check(swshell::ssh::DecodePemBlock(pem, label, decoded) && label == "RSA PRIVATE KEY" && decoded == fakePkcs1,
          "DecodePemBlock base64 round-trip");
}

}  // namespace

int main()
{
    TestSshBufAndMpint();
    TestX25519Rfc7748Vectors();
    TestPacketFramingAndKeyDerivation();
    TestDerPemAndSignatures();

    if (gFailures == 0) {
        printf("all ssh protocol tests passed\n");
        return 0;
    }
    printf("%d ssh protocol test(s) failed\n", gFailures);
    return 1;
}

/*
 * Pure C++ SSH-2.0 protocol helpers, RFC 7748 X25519, KDF, and ASN.1 DER encoders.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "ssh_protocol.h"

#include <algorithm>
#include <cstring>

namespace swshell {
namespace ssh {

namespace {

using Gf = int64_t[16];

void GfZero(Gf o)
{
    for (int i = 0; i < 16; ++i) {
        o[i] = 0;
    }
}

void GfCopy(Gf o, const Gf a)
{
    for (int i = 0; i < 16; ++i) {
        o[i] = a[i];
    }
}

void GfAdd(Gf o, const Gf a, const Gf b)
{
    for (int i = 0; i < 16; ++i) {
        o[i] = a[i] + b[i];
    }
}

void GfSub(Gf o, const Gf a, const Gf b)
{
    for (int i = 0; i < 16; ++i) {
        o[i] = a[i] - b[i];
    }
}

void GfCarry(Gf o)
{
    for (int i = 0; i < 16; ++i) {
        o[i] += static_cast<int64_t>(1) << 16;
        int64_t c = o[i] >> 16;
        o[(i + 1) * (i < 15)] += c - 1 + 37 * (c - 1) * (i == 15);
        o[i] -= c << 16;
    }
}

void GfSel(Gf p, Gf q, int b)
{
    int64_t t;
    int64_t c = ~(b - 1);
    for (int i = 0; i < 16; ++i) {
        t = c & (p[i] ^ q[i]);
        p[i] ^= t;
        q[i] ^= t;
    }
}

void GfMul(Gf o, const Gf a, const Gf b)
{
    int64_t t[31];
    for (int i = 0; i < 31; ++i) {
        t[i] = 0;
    }
    for (int i = 0; i < 16; ++i) {
        for (int j = 0; j < 16; ++j) {
            t[i + j] += a[i] * b[j];
        }
    }
    for (int i = 0; i < 15; ++i) {
        t[i] += 38 * t[i + 16];
    }
    for (int i = 0; i < 16; ++i) {
        o[i] = t[i];
    }
    GfCarry(o);
    GfCarry(o);
}

void GfSqr(Gf o, const Gf a)
{
    GfMul(o, a, a);
}

void GfInv(Gf o, const Gf i)
{
    Gf c;
    GfCopy(c, i);
    for (int a = 253; a >= 0; --a) {
        GfSqr(c, c);
        if (a != 2 && a != 4) {
            GfMul(c, c, i);
        }
    }
    GfCopy(o, c);
}

void GfUnpack(Gf o, const uint8_t n[32])
{
    for (int i = 0; i < 16; ++i) {
        o[i] = static_cast<int64_t>(n[2 * i]) + (static_cast<int64_t>(n[2 * i + 1]) << 8);
    }
    o[15] &= 0x7fff;
}

void GfPack(uint8_t o[32], const Gf n)
{
    Gf m, t;
    GfCopy(t, n);
    GfCarry(t);
    GfCarry(t);
    GfCarry(t);
    for (int j = 0; j < 2; ++j) {
        m[0] = t[0] - 0xffed;
        for (int i = 1; i < 15; ++i) {
            m[i] = t[i] - 0xffff - ((m[i - 1] >> 16) & 1);
            m[i - 1] &= 0xffff;
        }
        m[15] = t[15] - 0x7fff - ((m[14] >> 16) & 1);
        int b = static_cast<int>((m[15] >> 16) & 1);
        m[14] &= 0xffff;
        GfSel(t, m, 1 - b);
    }
    for (int i = 0; i < 16; ++i) {
        o[2 * i] = static_cast<uint8_t>(t[i] & 0xff);
        o[2 * i + 1] = static_cast<uint8_t>(t[i] >> 8);
    }
}

void DerAppendLength(std::vector<uint8_t> &out, size_t len)
{
    if (len < 0x80) {
        out.push_back(static_cast<uint8_t>(len));
    } else if (len <= 0xff) {
        out.push_back(0x81);
        out.push_back(static_cast<uint8_t>(len));
    } else if (len <= 0xffff) {
        out.push_back(0x82);
        out.push_back(static_cast<uint8_t>((len >> 8) & 0xff));
        out.push_back(static_cast<uint8_t>(len & 0xff));
    } else {
        out.push_back(0x83);
        out.push_back(static_cast<uint8_t>((len >> 16) & 0xff));
        out.push_back(static_cast<uint8_t>((len >> 8) & 0xff));
        out.push_back(static_cast<uint8_t>(len & 0xff));
    }
}

void DerAppendTag(std::vector<uint8_t> &out, uint8_t tag, const std::vector<uint8_t> &content)
{
    out.push_back(tag);
    DerAppendLength(out, content.size());
    out.insert(out.end(), content.begin(), content.end());
}

void DerAppendUnsignedInteger(std::vector<uint8_t> &out, const std::vector<uint8_t> &bigEndian)
{
    size_t start = 0;
    while (start + 1 < bigEndian.size() && bigEndian[start] == 0) {
        ++start;
    }
    std::vector<uint8_t> trimmed(bigEndian.begin() + start, bigEndian.end());
    if (trimmed.empty()) {
        trimmed.push_back(0);
    }
    if (trimmed[0] & 0x80) {
        trimmed.insert(trimmed.begin(), 0x00);
    }
    DerAppendTag(out, 0x02, trimmed);
}

int B64Value(char c)
{
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

std::string Base64EncodeNoPad(const uint8_t *data, size_t len)
{
    static constexpr char kAlpha[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    out.reserve(((len + 2) / 3) * 4);
    for (size_t i = 0; i < len; i += 3) {
        uint32_t v = static_cast<uint32_t>(data[i]) << 16;
        if (i + 1 < len) v |= static_cast<uint32_t>(data[i + 1]) << 8;
        if (i + 2 < len) v |= static_cast<uint32_t>(data[i + 2]);
        out.push_back(kAlpha[(v >> 18) & 0x3f]);
        out.push_back(kAlpha[(v >> 12) & 0x3f]);
        if (i + 1 < len) out.push_back(kAlpha[(v >> 6) & 0x3f]);
        if (i + 2 < len) out.push_back(kAlpha[v & 0x3f]);
    }
    return out;
}

}  // namespace

void SshBuf::Clear()
{
    data_.clear();
    pos_ = 0;
}

void SshBuf::WriteUint8(uint8_t v)
{
    data_.push_back(v);
}

void SshBuf::WriteBool(bool v)
{
    data_.push_back(v ? 1 : 0);
}

void SshBuf::WriteUint32(uint32_t v)
{
    data_.push_back(static_cast<uint8_t>((v >> 24) & 0xff));
    data_.push_back(static_cast<uint8_t>((v >> 16) & 0xff));
    data_.push_back(static_cast<uint8_t>((v >> 8) & 0xff));
    data_.push_back(static_cast<uint8_t>(v & 0xff));
}

void SshBuf::WriteRaw(const void *ptr, size_t len)
{
    if (len == 0 || ptr == nullptr) {
        return;
    }
    const auto *bytes = static_cast<const uint8_t *>(ptr);
    data_.insert(data_.end(), bytes, bytes + len);
}

void SshBuf::WriteString(const std::string &s)
{
    WriteUint32(static_cast<uint32_t>(s.size()));
    WriteRaw(s.data(), s.size());
}

void SshBuf::WriteString(const std::vector<uint8_t> &bytes)
{
    WriteUint32(static_cast<uint32_t>(bytes.size()));
    WriteRaw(bytes.data(), bytes.size());
}

void SshBuf::WriteMpint(const std::vector<uint8_t> &unsignedBigEndian)
{
    WriteString(EncodeMpintPayload(unsignedBigEndian));
}

void SshBuf::WriteNameList(const std::vector<std::string> &names)
{
    std::string joined;
    for (size_t i = 0; i < names.size(); ++i) {
        if (i > 0) {
            joined.push_back(',');
        }
        joined.append(names[i]);
    }
    WriteString(joined);
}

bool SshBuf::ReadUint8(uint8_t &out)
{
    if (Remaining() < 1) {
        return false;
    }
    out = data_[pos_++];
    return true;
}

bool SshBuf::ReadBool(bool &out)
{
    uint8_t v = 0;
    if (!ReadUint8(v)) {
        return false;
    }
    out = (v != 0);
    return true;
}

bool SshBuf::ReadUint32(uint32_t &out)
{
    if (Remaining() < 4) {
        return false;
    }
    out = (static_cast<uint32_t>(data_[pos_]) << 24) |
          (static_cast<uint32_t>(data_[pos_ + 1]) << 16) |
          (static_cast<uint32_t>(data_[pos_ + 2]) << 8) |
          static_cast<uint32_t>(data_[pos_ + 3]);
    pos_ += 4;
    return true;
}

bool SshBuf::ReadRaw(size_t len, std::vector<uint8_t> &out)
{
    if (Remaining() < len) {
        return false;
    }
    out.assign(data_.begin() + pos_, data_.begin() + pos_ + len);
    pos_ += len;
    return true;
}

bool SshBuf::ReadString(std::string &out)
{
    uint32_t len = 0;
    if (!ReadUint32(len) || Remaining() < len) {
        return false;
    }
    out.assign(reinterpret_cast<const char *>(data_.data() + pos_), len);
    pos_ += len;
    return true;
}

bool SshBuf::ReadBytes(std::vector<uint8_t> &out)
{
    uint32_t len = 0;
    if (!ReadUint32(len) || Remaining() < len) {
        return false;
    }
    out.assign(data_.begin() + pos_, data_.begin() + pos_ + len);
    pos_ += len;
    return true;
}

bool SshBuf::ReadMpint(std::vector<uint8_t> &outUnsignedBigEndian)
{
    std::vector<uint8_t> raw;
    if (!ReadBytes(raw)) {
        return false;
    }
    size_t start = 0;
    while (start < raw.size() && raw[start] == 0) {
        ++start;
    }
    outUnsignedBigEndian.assign(raw.begin() + start, raw.end());
    return true;
}

void X25519ScalarMult(uint8_t out[32], const uint8_t scalar[32], const uint8_t point[32])
{
    uint8_t z[32];
    std::memcpy(z, scalar, 32);
    z[0] &= 248;
    z[31] &= 127;
    z[31] |= 64;

    Gf x, a, b, c, d, e, f;
    GfUnpack(x, point);
    GfZero(a);
    GfZero(c);
    GfCopy(b, x);
    GfZero(d);
    a[0] = 1;
    d[0] = 1;

    static const Gf k121665 = { 0xdb41, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

    for (int i = 254; i >= 0; --i) {
        int r = (z[i >> 3] >> (i & 7)) & 1;
        GfSel(a, b, r);
        GfSel(c, d, r);
        GfAdd(e, a, c);
        GfSub(a, a, c);
        GfAdd(c, b, d);
        GfSub(b, b, d);
        GfSqr(d, e);
        GfSqr(f, a);
        GfMul(a, c, a);
        GfMul(c, b, e);
        GfAdd(e, a, c);
        GfSub(a, a, c);
        GfSqr(b, a);
        GfSub(c, d, f);
        GfMul(a, c, k121665);
        GfAdd(a, a, d);
        GfMul(c, c, a);
        GfMul(a, d, f);
        GfMul(d, b, x);
        GfSqr(b, e);
        GfSel(a, b, r);
        GfSel(c, d, r);
    }
    GfInv(c, c);
    GfMul(a, a, c);
    GfPack(out, a);
}

void X25519PublicFromPrivate(uint8_t pub[32], const uint8_t scalar[32])
{
    uint8_t basePoint[32] = { 9 };
    X25519ScalarMult(pub, scalar, basePoint);
}

std::vector<uint8_t> EncodeMpintPayload(const std::vector<uint8_t> &unsignedBigEndian)
{
    size_t start = 0;
    while (start < unsignedBigEndian.size() && unsignedBigEndian[start] == 0) {
        ++start;
    }
    if (start == unsignedBigEndian.size()) {
        return {};
    }
    std::vector<uint8_t> out;
    if (unsignedBigEndian[start] & 0x80) {
        out.push_back(0x00);
    }
    out.insert(out.end(), unsignedBigEndian.begin() + start, unsignedBigEndian.end());
    return out;
}

std::vector<uint8_t> FrameSshPacket(const std::vector<uint8_t> &payload, size_t blockAlign, const RandomBytesFn &rng)
{
    if (blockAlign < 8) {
        blockAlign = 8;
    }
    size_t unpadded = 5 + payload.size();
    size_t padLen = blockAlign - (unpadded % blockAlign);
    if (padLen < 4) {
        padLen += blockAlign;
    }
    uint32_t packetLen = static_cast<uint32_t>(1 + payload.size() + padLen);

    std::vector<uint8_t> out(4 + packetLen, 0);
    out[0] = static_cast<uint8_t>((packetLen >> 24) & 0xff);
    out[1] = static_cast<uint8_t>((packetLen >> 16) & 0xff);
    out[2] = static_cast<uint8_t>((packetLen >> 8) & 0xff);
    out[3] = static_cast<uint8_t>(packetLen & 0xff);
    out[4] = static_cast<uint8_t>(padLen);
    if (!payload.empty()) {
        std::memcpy(out.data() + 5, payload.data(), payload.size());
    }
    if (rng) {
        rng(out.data() + 5 + payload.size(), padLen);
    }
    return out;
}

bool UnframeSshPacket(const std::vector<uint8_t> &packetBytes, std::vector<uint8_t> &outPayload)
{
    if (packetBytes.size() < 5) {
        return false;
    }
    uint32_t packetLen = (static_cast<uint32_t>(packetBytes[0]) << 24) |
                         (static_cast<uint32_t>(packetBytes[1]) << 16) |
                         (static_cast<uint32_t>(packetBytes[2]) << 8) |
                         static_cast<uint32_t>(packetBytes[3]);
    if (4 + packetLen != packetBytes.size() || packetLen < 5) {
        return false;
    }
    uint8_t padLen = packetBytes[4];
    if (padLen < 4 || static_cast<size_t>(1 + padLen) > packetLen) {
        return false;
    }
    size_t payloadLen = packetLen - 1 - padLen;
    outPayload.assign(packetBytes.begin() + 5, packetBytes.begin() + 5 + payloadLen);
    return true;
}

std::vector<uint8_t> BuildCurve25519ExchangeHashInput(
    const std::string &clientIdent,
    const std::string &serverIdent,
    const std::vector<uint8_t> &clientKexInitPayload,
    const std::vector<uint8_t> &serverKexInitPayload,
    const std::vector<uint8_t> &serverHostKeyBlob,
    const uint8_t clientEphemeralPub[32],
    const uint8_t serverEphemeralPub[32],
    const std::vector<uint8_t> &sharedSecretRaw)
{
    SshBuf buf;
    buf.WriteString(clientIdent);
    buf.WriteString(serverIdent);
    buf.WriteString(clientKexInitPayload);
    buf.WriteString(serverKexInitPayload);
    buf.WriteString(serverHostKeyBlob);
    buf.WriteString(std::vector<uint8_t>(clientEphemeralPub, clientEphemeralPub + 32));
    buf.WriteString(std::vector<uint8_t>(serverEphemeralPub, serverEphemeralPub + 32));
    buf.WriteMpint(sharedSecretRaw);
    return buf.Bytes();
}

bool DeriveSshKey(
    const std::vector<uint8_t> &sharedSecretRaw,
    const uint8_t exchangeHash[32],
    char letter,
    const uint8_t sessionId[32],
    size_t neededLen,
    const Sha256Fn &sha256Fn,
    std::vector<uint8_t> &outKey)
{
    outKey.clear();
    if (!sha256Fn || neededLen == 0) {
        return false;
    }

    SshBuf prefix;
    prefix.WriteMpint(sharedSecretRaw);
    prefix.WriteRaw(exchangeHash, 32);

    std::vector<uint8_t> roundInput = prefix.Bytes();
    roundInput.push_back(static_cast<uint8_t>(letter));
    roundInput.insert(roundInput.end(), sessionId, sessionId + 32);

    uint8_t block[32];
    if (!sha256Fn(roundInput.data(), roundInput.size(), block)) {
        return false;
    }
    outKey.insert(outKey.end(), block, block + 32);

    while (outKey.size() < neededLen) {
        std::vector<uint8_t> nextInput = prefix.Bytes();
        nextInput.insert(nextInput.end(), outKey.begin(), outKey.end());
        if (!sha256Fn(nextInput.data(), nextInput.size(), block)) {
            return false;
        }
        outKey.insert(outKey.end(), block, block + 32);
    }
    outKey.resize(neededLen);
    return true;
}

bool SshHostKeyToSpkiDer(const std::vector<uint8_t> &hostKeyBlob,
                         std::string &outAlgoName,
                         std::vector<uint8_t> &outSpkiDer)
{
    SshBuf buf(hostKeyBlob);
    if (!buf.ReadString(outAlgoName)) {
        return false;
    }

    if (outAlgoName == "ssh-rsa") {
        std::vector<uint8_t> eBytes, nBytes;
        if (!buf.ReadMpint(eBytes) || !buf.ReadMpint(nBytes) || eBytes.empty() || nBytes.empty()) {
            return false;
        }
        std::vector<uint8_t> rsaPubSeq;
        DerAppendUnsignedInteger(rsaPubSeq, nBytes);
        DerAppendUnsignedInteger(rsaPubSeq, eBytes);
        std::vector<uint8_t> rsaPubSeqWrapped;
        DerAppendTag(rsaPubSeqWrapped, 0x30, rsaPubSeq);

        // BIT STRING with 0 unused bits
        std::vector<uint8_t> bitString;
        bitString.push_back(0x00);
        bitString.insert(bitString.end(), rsaPubSeqWrapped.begin(), rsaPubSeqWrapped.end());

        // rsaEncryption OID: 1.2.840.113549.1.1.1 + NULL
        static const uint8_t kRsaAlgId[] = {
            0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
            0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00
        };
        std::vector<uint8_t> spkiBody(kRsaAlgId, kRsaAlgId + sizeof(kRsaAlgId));
        DerAppendTag(spkiBody, 0x03, bitString);
        outSpkiDer.clear();
        DerAppendTag(outSpkiDer, 0x30, spkiBody);
        return true;
    }

    if (outAlgoName == "ecdsa-sha2-nistp256") {
        std::string curveName;
        std::vector<uint8_t> pointBytes;
        if (!buf.ReadString(curveName) || !buf.ReadBytes(pointBytes)) {
            return false;
        }
        if (curveName != "nistp256" || pointBytes.size() != 65 || pointBytes[0] != 0x04) {
            return false;
        }
        static const uint8_t kP256SpkiPrefix[] = {
            0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01,
            0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00
        };
        outSpkiDer.assign(kP256SpkiPrefix, kP256SpkiPrefix + sizeof(kP256SpkiPrefix));
        outSpkiDer.insert(outSpkiDer.end(), pointBytes.begin(), pointBytes.end());
        return true;
    }

    if (outAlgoName == "ssh-ed25519") {
        std::vector<uint8_t> keyBytes;
        if (!buf.ReadBytes(keyBytes) || keyBytes.size() != 32) {
            return false;
        }
        static const uint8_t kEd25519SpkiPrefix[] = {
            0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x03, 0x21, 0x00
        };
        outSpkiDer.assign(kEd25519SpkiPrefix, kEd25519SpkiPrefix + sizeof(kEd25519SpkiPrefix));
        outSpkiDer.insert(outSpkiDer.end(), keyBytes.begin(), keyBytes.end());
        return true;
    }

    return false;
}

bool ParseSshSignatureBlob(const std::vector<uint8_t> &sigBlob,
                           std::string &outSigAlgo,
                           std::vector<uint8_t> &outVerifyBytes)
{
    SshBuf buf(sigBlob);
    std::vector<uint8_t> rawSig;
    if (!buf.ReadString(outSigAlgo) || !buf.ReadBytes(rawSig) || rawSig.empty()) {
        return false;
    }
    if (outSigAlgo == "ecdsa-sha2-nistp256") {
        SshBuf rsBuf(rawSig);
        std::vector<uint8_t> r, s;
        if (!rsBuf.ReadMpint(r) || !rsBuf.ReadMpint(s)) {
            return false;
        }
        std::vector<uint8_t> seqBody;
        DerAppendUnsignedInteger(seqBody, r);
        DerAppendUnsignedInteger(seqBody, s);
        outVerifyBytes.clear();
        DerAppendTag(outVerifyBytes, 0x30, seqBody);
        return true;
    }
    outVerifyBytes = std::move(rawSig);
    return true;
}

std::vector<uint8_t> BuildSshRsaPubKeyBlob(const std::vector<uint8_t> &eBytes,
                                            const std::vector<uint8_t> &nBytes)
{
    SshBuf buf;
    buf.WriteString("ssh-rsa");
    buf.WriteMpint(eBytes);
    buf.WriteMpint(nBytes);
    return buf.Bytes();
}

std::vector<uint8_t> WrapPkcs1RsaPrivateKeyInPkcs8Der(const std::vector<uint8_t> &pkcs1Der)
{
    std::vector<uint8_t> body;
    // version INTEGER 0
    body.push_back(0x02);
    body.push_back(0x01);
    body.push_back(0x00);
    // rsaEncryption AlgorithmIdentifier
    static const uint8_t kRsaAlgId[] = {
        0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
        0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00
    };
    body.insert(body.end(), kRsaAlgId, kRsaAlgId + sizeof(kRsaAlgId));
    // OCTET STRING containing PKCS#1 RSAPrivateKey DER
    DerAppendTag(body, 0x04, pkcs1Der);

    std::vector<uint8_t> pkcs8;
    DerAppendTag(pkcs8, 0x30, body);
    return pkcs8;
}

bool DecodePemBlock(const std::string &pemText, std::string &outLabel, std::vector<uint8_t> &outDer)
{
    outLabel.clear();
    outDer.clear();
    const std::string beginPrefix = "-----BEGIN ";
    size_t beginPos = pemText.find(beginPrefix);
    if (beginPos == std::string::npos) {
        return false;
    }
    size_t labelStart = beginPos + beginPrefix.size();
    size_t labelEnd = pemText.find("-----", labelStart);
    if (labelEnd == std::string::npos) {
        return false;
    }
    outLabel = pemText.substr(labelStart, labelEnd - labelStart);
    std::string endMarker = "-----END " + outLabel + "-----";
    size_t bodyStart = labelEnd + 5;
    size_t endPos = pemText.find(endMarker, bodyStart);
    if (endPos == std::string::npos) {
        return false;
    }

    uint32_t acc = 0;
    int bits = 0;
    for (size_t i = bodyStart; i < endPos; ++i) {
        char ch = pemText[i];
        if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' || ch == '=') {
            continue;
        }
        int val = B64Value(ch);
        if (val < 0) {
            return false;
        }
        acc = (acc << 6) | static_cast<uint32_t>(val);
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            outDer.push_back(static_cast<uint8_t>((acc >> bits) & 0xff));
        }
    }
    return !outDer.empty();
}

bool ComputeSshFingerprint(const std::vector<uint8_t> &hostKeyBlob,
                           const Sha256Fn &sha256Fn,
                           std::string &outFingerprint)
{
    if (!sha256Fn || hostKeyBlob.empty()) {
        return false;
    }
    uint8_t digest[32];
    if (!sha256Fn(hostKeyBlob.data(), hostKeyBlob.size(), digest)) {
        return false;
    }
    outFingerprint = "SHA256:" + Base64EncodeNoPad(digest, sizeof(digest));
    return true;
}

}  // namespace ssh
}  // namespace swshell

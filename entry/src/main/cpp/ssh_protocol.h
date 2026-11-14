/*
 * Pure C++ SSH-2.0 wire encoding, X25519 (RFC 7748), KEX/key derivation, and ASN.1 DER helpers.
 * Intentionally free of HarmonyOS-only headers so it can be unit-tested on the host.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef SW_SHELL_SSH_PROTOCOL_H
#define SW_SHELL_SSH_PROTOCOL_H

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace swshell {
namespace ssh {

using Sha256Fn = std::function<bool(const uint8_t *data, size_t len, uint8_t outDigest[32])>;
using RandomBytesFn = std::function<bool(uint8_t *out, size_t len)>;

class SshBuf {
public:
    SshBuf() = default;
    explicit SshBuf(const std::vector<uint8_t> &raw) : data_(raw), pos_(0) {}
    SshBuf(const uint8_t *ptr, size_t len) : data_(ptr, ptr + len), pos_(0) {}

    void Clear();
    void WriteUint8(uint8_t v);
    void WriteBool(bool v);
    void WriteUint32(uint32_t v);
    void WriteRaw(const void *ptr, size_t len);
    void WriteString(const std::string &s);
    void WriteString(const std::vector<uint8_t> &bytes);
    void WriteMpint(const std::vector<uint8_t> &unsignedBigEndian);
    void WriteNameList(const std::vector<std::string> &names);

    bool ReadUint8(uint8_t &out);
    bool ReadBool(bool &out);
    bool ReadUint32(uint32_t &out);
    bool ReadRaw(size_t len, std::vector<uint8_t> &out);
    bool ReadString(std::string &out);
    bool ReadBytes(std::vector<uint8_t> &out);
    bool ReadMpint(std::vector<uint8_t> &outUnsignedBigEndian);

    size_t Remaining() const { return pos_ < data_.size() ? data_.size() - pos_ : 0; }
    size_t Position() const { return pos_; }
    const std::vector<uint8_t> &Bytes() const { return data_; }
    std::vector<uint8_t> &MutableBytes() { return data_; }

private:
    std::vector<uint8_t> data_;
    size_t pos_ = 0;
};

/** RFC 7748 X25519 scalar multiplication: out = scalar * point. */
void X25519ScalarMult(uint8_t out[32], const uint8_t scalar[32], const uint8_t point[32]);

/** Computes basepoint public key out = scalar * 9. */
void X25519PublicFromPrivate(uint8_t pub[32], const uint8_t scalar[32]);

/** Normalizes unsigned big-endian integer bytes into SSH mpint (stripping extra leading 0s, adding sign 0 if MSB>=0x80). */
std::vector<uint8_t> EncodeMpintPayload(const std::vector<uint8_t> &unsignedBigEndian);

/** Builds full SSH packet bytes (4-byte len + 1-byte padLen + payload + padding), aligned to blockAlign. */
std::vector<uint8_t> FrameSshPacket(const std::vector<uint8_t> &payload, size_t blockAlign, const RandomBytesFn &rng);

/** Extracts payload from a decrypted packet whose leading 4-byte packet_length is included at offset 0. */
bool UnframeSshPacket(const std::vector<uint8_t> &packetBytes, std::vector<uint8_t> &outPayload);

/** Builds the RFC 8731 / RFC 5656 Curve25519 exchange hash H input buffer. */
std::vector<uint8_t> BuildCurve25519ExchangeHashInput(
    const std::string &clientIdent,
    const std::string &serverIdent,
    const std::vector<uint8_t> &clientKexInitPayload,
    const std::vector<uint8_t> &serverKexInitPayload,
    const std::vector<uint8_t> &serverHostKeyBlob,
    const uint8_t clientEphemeralPub[32],
    const uint8_t serverEphemeralPub[32],
    const std::vector<uint8_t> &sharedSecretRaw);

/** RFC 4253 Section 7.2 iterative SHA-256 key expansion (letter = 'A'..'F'). */
bool DeriveSshKey(
    const std::vector<uint8_t> &sharedSecretRaw,
    const uint8_t exchangeHash[32],
    char letter,
    const uint8_t sessionId[32],
    size_t neededLen,
    const Sha256Fn &sha256Fn,
    std::vector<uint8_t> &outKey);

/** Parses SSH hostkey blob and builds X.509 SPKI DER suitable for CryptoKit verification. */
bool SshHostKeyToSpkiDer(const std::vector<uint8_t> &hostKeyBlob,
                         std::string &outAlgoName,
                         std::vector<uint8_t> &outSpkiDer);

/** Parses SSH signature blob ("algoName", sigBytes) and normalizes ECDSA signatures to ASN.1 DER if needed. */
bool ParseSshSignatureBlob(const std::vector<uint8_t> &sigBlob,
                           std::string &outSigAlgo,
                           std::vector<uint8_t> &outVerifyBytes);

/** Encodes raw RSA (n, e) positive big-endian bytes into SSH "ssh-rsa" wire public key blob. */
std::vector<uint8_t> BuildSshRsaPubKeyBlob(const std::vector<uint8_t> &eBytes,
                                            const std::vector<uint8_t> &nBytes);

/** Encodes RSA PKCS#1 private key DER bytes into PKCS#8 PrivateKeyInfo DER bytes. */
std::vector<uint8_t> WrapPkcs1RsaPrivateKeyInPkcs8Der(const std::vector<uint8_t> &pkcs1Der);

/** Decodes PEM block matching optional header keyword (or first BEGIN block) into DER bytes. */
bool DecodePemBlock(const std::string &pemText, std::string &outLabel, std::vector<uint8_t> &outDer);

/** Formats OpenSSH-style SHA256:<base64-no-pad> fingerprint from raw host key blob. */
bool ComputeSshFingerprint(const std::vector<uint8_t> &hostKeyBlob,
                           const Sha256Fn &sha256Fn,
                           std::string &outFingerprint);

}  // namespace ssh
}  // namespace swshell

#endif /* SW_SHELL_SSH_PROTOCOL_H */

/*
 * Native SSH-2.0 client implementation using POSIX TCP sockets and HarmonyOS libohcrypto.so.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "ssh_client.h"
#include "ssh_protocol.h"

#include "CryptoArchitectureKit/crypto_asym_key.h"
#include "CryptoArchitectureKit/crypto_common.h"
#include "CryptoArchitectureKit/crypto_digest.h"
#include "CryptoArchitectureKit/crypto_rand.h"
#include "CryptoArchitectureKit/crypto_signature.h"
#include "CryptoArchitectureKit/crypto_sym_cipher.h"
#include "CryptoArchitectureKit/crypto_sym_key.h"

#include <algorithm>
#include <arpa/inet.h>
#include <chrono>
#include <cerrno>
#include <cstring>
#include <fcntl.h>
#include <memory>
#include <netdb.h>
#include <poll.h>
#include <sstream>
#include <string>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>
#include <vector>

namespace swshell {

namespace {

constexpr const char *kClientIdent = "SSH-2.0-SwShellOHOS_1.0";
constexpr size_t kMaxSshPacketBytes = 256 * 1024;
constexpr size_t kMaxOutputCaptureBytes = 512 * 1024;
constexpr uint32_t kInitialWindowSize = 2 * 1024 * 1024;
constexpr uint32_t kMaxChannelPacketSize = 32768;

enum SshMsg : uint8_t {
    SSH_MSG_DISCONNECT = 1,
    SSH_MSG_IGNORE = 2,
    SSH_MSG_UNIMPLEMENTED = 3,
    SSH_MSG_DEBUG = 4,
    SSH_MSG_SERVICE_REQUEST = 5,
    SSH_MSG_SERVICE_ACCEPT = 6,
    SSH_MSG_EXT_INFO = 7,
    SSH_MSG_KEXINIT = 20,
    SSH_MSG_NEWKEYS = 21,
    SSH_MSG_KEX_ECDH_INIT = 30,
    SSH_MSG_KEX_ECDH_REPLY = 31,
    SSH_MSG_USERAUTH_REQUEST = 50,
    SSH_MSG_USERAUTH_FAILURE = 51,
    SSH_MSG_USERAUTH_SUCCESS = 52,
    SSH_MSG_USERAUTH_BANNER = 53,
    SSH_MSG_USERAUTH_INFO_REQUEST = 60,
    SSH_MSG_USERAUTH_INFO_RESPONSE = 61,
    SSH_MSG_USERAUTH_PK_OK = 60,
    SSH_MSG_GLOBAL_REQUEST = 80,
    SSH_MSG_REQUEST_SUCCESS = 81,
    SSH_MSG_REQUEST_FAILURE = 82,
    SSH_MSG_CHANNEL_OPEN = 90,
    SSH_MSG_CHANNEL_OPEN_CONFIRMATION = 91,
    SSH_MSG_CHANNEL_OPEN_FAILURE = 92,
    SSH_MSG_CHANNEL_WINDOW_ADJUST = 93,
    SSH_MSG_CHANNEL_DATA = 94,
    SSH_MSG_CHANNEL_EXTENDED_DATA = 95,
    SSH_MSG_CHANNEL_EOF = 96,
    SSH_MSG_CHANNEL_CLOSE = 97,
    SSH_MSG_CHANNEL_REQUEST = 98,
    SSH_MSG_CHANNEL_SUCCESS = 99,
    SSH_MSG_CHANNEL_FAILURE = 100,
};

bool CryptoRandomBytes(uint8_t *out, size_t len)
{
    if (len == 0 || out == nullptr) {
        return true;
    }
    OH_CryptoRand *randCtx = nullptr;
    if (OH_CryptoRand_Create(&randCtx) == CRYPTO_SUCCESS && randCtx != nullptr) {
        Crypto_DataBlob blob = { nullptr, 0 };
        OH_Crypto_ErrCode ret = OH_CryptoRand_GenerateRandom(randCtx, static_cast<int>(len), &blob);
        OH_CryptoRand_Destroy(randCtx);
        if (ret == CRYPTO_SUCCESS && blob.data != nullptr && blob.len == len) {
            std::memcpy(out, blob.data, len);
            OH_Crypto_FreeDataBlob(&blob);
            return true;
        }
        if (blob.data != nullptr) {
            OH_Crypto_FreeDataBlob(&blob);
        }
    }
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd < 0) {
        return false;
    }
    size_t readTotal = 0;
    while (readTotal < len) {
        ssize_t n = read(fd, out + readTotal, len - readTotal);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) {
                continue;
            }
            close(fd);
            return false;
        }
        readTotal += static_cast<size_t>(n);
    }
    close(fd);
    return true;
}

bool CryptoSha256(const uint8_t *data, size_t len, uint8_t outDigest[32])
{
    OH_CryptoDigest *ctx = nullptr;
    if (OH_CryptoDigest_Create("SHA256", &ctx) != CRYPTO_SUCCESS || ctx == nullptr) {
        return false;
    }
    OH_Crypto_ErrCode st = CRYPTO_SUCCESS;
    if (len > 0) {
        Crypto_DataBlob inBlob = { const_cast<uint8_t *>(data), len };
        st = OH_CryptoDigest_Update(ctx, &inBlob);
    }
    Crypto_DataBlob outBlob = { nullptr, 0 };
    if (st == CRYPTO_SUCCESS) {
        st = OH_CryptoDigest_Final(ctx, &outBlob);
    }
    OH_DigestCrypto_Destroy(ctx);
    if (st != CRYPTO_SUCCESS || outBlob.data == nullptr || outBlob.len != 32) {
        if (outBlob.data != nullptr) {
            OH_Crypto_FreeDataBlob(&outBlob);
        }
        return false;
    }
    std::memcpy(outDigest, outBlob.data, 32);
    OH_Crypto_FreeDataBlob(&outBlob);
    return true;
}

bool ComputeHmacSha256(const std::vector<uint8_t> &key,
                       const uint8_t *data, size_t len,
                       uint8_t outMac[32])
{
    if (key.empty()) {
        return false;
    }
    uint8_t paddedKey[64] = {0};
    if (key.size() > 64) {
        if (!CryptoSha256(key.data(), key.size(), paddedKey)) {
            return false;
        }
    } else {
        std::memcpy(paddedKey, key.data(), key.size());
    }

    uint8_t ipad[64];
    uint8_t opad[64];
    for (int i = 0; i < 64; ++i) {
        ipad[i] = static_cast<uint8_t>(paddedKey[i] ^ 0x36);
        opad[i] = static_cast<uint8_t>(paddedKey[i] ^ 0x5c);
    }

    std::vector<uint8_t> inner;
    inner.reserve(64 + len);
    inner.insert(inner.end(), ipad, ipad + 64);
    if (len > 0 && data != nullptr) {
        inner.insert(inner.end(), data, data + len);
    }
    uint8_t innerHash[32];
    if (!CryptoSha256(inner.data(), inner.size(), innerHash)) {
        return false;
    }

    uint8_t outer[64 + 32];
    std::memcpy(outer, opad, 64);
    std::memcpy(outer + 64, innerHash, 32);
    return CryptoSha256(outer, sizeof(outer), outMac);
}

bool ConstantTimeEqual(const uint8_t *a, const uint8_t *b, size_t len)
{
    uint8_t diff = 0;
    for (size_t i = 0; i < len; ++i) {
        diff |= static_cast<uint8_t>(a[i] ^ b[i]);
    }
    return diff == 0;
}

std::vector<std::string> SplitCsv(const std::string &csv)
{
    std::vector<std::string> out;
    std::stringstream ss(csv);
    std::string item;
    while (std::getline(ss, item, ',')) {
        if (!item.empty()) {
            out.push_back(item);
        }
    }
    return out;
}

std::string NegotiateFirst(const std::vector<std::string> &clientPref, const std::vector<std::string> &serverList)
{
    for (const auto &c : clientPref) {
        for (const auto &s : serverList) {
            if (c == s) {
                return c;
            }
        }
    }
    return std::string();
}

struct SymStreamCipher {
    OH_CryptoSymCipher *ctx = nullptr;
    OH_CryptoSymKey *symKey = nullptr;
    OH_CryptoSymCipherParams *params = nullptr;
    std::vector<uint8_t> macKey;
    bool active = false;

    ~SymStreamCipher()
    {
        if (ctx != nullptr) {
            OH_CryptoSymCipher_Destroy(ctx);
        }
        if (symKey != nullptr) {
            OH_CryptoSymKey_Destroy(symKey);
        }
        if (params != nullptr) {
            OH_CryptoSymCipherParams_Destroy(params);
        }
    }

    bool Init(const std::string &cipherName, Crypto_CipherMode mode,
              const std::vector<uint8_t> &keyBytes,
              const std::vector<uint8_t> &ivBytes,
              const std::vector<uint8_t> &hmacKeyBytes,
              std::string &outError)
    {
        size_t expectedKeyLen = (cipherName == "aes128-ctr") ? 16 : 32;
        const char *symAlgo = (cipherName == "aes128-ctr") ? "AES128" : "AES256";
        const char *cipherSpec = (cipherName == "aes128-ctr") ? "AES128|CTR|NoPadding" : "AES256|CTR|NoPadding";

        if (keyBytes.size() < expectedKeyLen || ivBytes.size() < 16) {
            outError = "Insufficient derived key/IV length";
            return false;
        }

        OH_CryptoSymKeyGenerator *kg = nullptr;
        if (OH_CryptoSymKeyGenerator_Create(symAlgo, &kg) != CRYPTO_SUCCESS || kg == nullptr) {
            outError = std::string("OH_CryptoSymKeyGenerator_Create failed for ") + symAlgo;
            return false;
        }
        Crypto_DataBlob kBlob = { const_cast<uint8_t *>(keyBytes.data()), expectedKeyLen };
        OH_Crypto_ErrCode st = OH_CryptoSymKeyGenerator_Convert(kg, &kBlob, &symKey);
        OH_CryptoSymKeyGenerator_Destroy(kg);
        if (st != CRYPTO_SUCCESS || symKey == nullptr) {
            outError = "OH_CryptoSymKeyGenerator_Convert failed";
            return false;
        }

        if (OH_CryptoSymCipherParams_Create(&params) != CRYPTO_SUCCESS || params == nullptr) {
            outError = "OH_CryptoSymCipherParams_Create failed";
            return false;
        }
        Crypto_DataBlob ivBlob = { const_cast<uint8_t *>(ivBytes.data()), 16 };
        if (OH_CryptoSymCipherParams_SetParam(params, CRYPTO_IV_DATABLOB, &ivBlob) != CRYPTO_SUCCESS) {
            outError = "OH_CryptoSymCipherParams_SetParam(IV) failed";
            return false;
        }
        if (OH_CryptoSymCipher_Create(cipherSpec, &ctx) != CRYPTO_SUCCESS || ctx == nullptr) {
            outError = std::string("OH_CryptoSymCipher_Create failed for ") + cipherSpec;
            return false;
        }
        if (OH_CryptoSymCipher_Init(ctx, mode, symKey, params) != CRYPTO_SUCCESS) {
            outError = std::string("OH_CryptoSymCipher_Init failed for ") + cipherSpec;
            return false;
        }
        macKey = hmacKeyBytes;
        active = true;
        return true;
    }

    bool UpdateExactBlocks(const uint8_t *inData, size_t inLen, std::vector<uint8_t> &outData)
    {
        if (!active || ctx == nullptr) {
            return false;
        }
        Crypto_DataBlob inBlob = { const_cast<uint8_t *>(inData), inLen };
        Crypto_DataBlob outBlob = { nullptr, 0 };
        OH_Crypto_ErrCode st = OH_CryptoSymCipher_Update(ctx, &inBlob, &outBlob);
        if (st != CRYPTO_SUCCESS || outBlob.data == nullptr || outBlob.len != inLen) {
            if (outBlob.data != nullptr) {
                OH_Crypto_FreeDataBlob(&outBlob);
            }
            return false;
        }
        outData.assign(outBlob.data, outBlob.data + outBlob.len);
        OH_Crypto_FreeDataBlob(&outBlob);
        return true;
    }
};

class SshSocket {
public:
    ~SshSocket() { Close(); }

    bool Connect(const std::string &host, int port, int timeoutSec, std::string &outError)
    {
        struct addrinfo hints {};
        hints.ai_family = AF_UNSPEC;
        hints.ai_socktype = SOCK_STREAM;
        struct addrinfo *res = nullptr;
        std::string portStr = std::to_string(port);
        int gaiErr = getaddrinfo(host.c_str(), portStr.c_str(), &hints, &res);
        if (gaiErr != 0 || res == nullptr) {
            outError = std::string("DNS resolution failed: ") + gai_strerror(gaiErr);
            return false;
        }

        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(std::max(3, timeoutSec));
        int lastErr = 0;

        for (struct addrinfo *rp = res; rp != nullptr; rp = rp->ai_next) {
            int s = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
            if (s < 0) {
                lastErr = errno;
                continue;
            }
            int flags = fcntl(s, F_GETFL, 0);
            fcntl(s, F_SETFL, flags | O_NONBLOCK);

            int rc = ::connect(s, rp->ai_addr, rp->ai_addrlen);
            if (rc == 0) {
                fd_ = s;
                break;
            }
            if (errno == EINPROGRESS) {
                auto remainingMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                    deadline - std::chrono::steady_clock::now()).count();
                if (remainingMs <= 0) {
                    close(s);
                    lastErr = ETIMEDOUT;
                    break;
                }
                struct pollfd pfd { s, POLLOUT, 0 };
                int pr = poll(&pfd, 1, static_cast<int>(remainingMs));
                if (pr > 0) {
                    int soErr = 0;
                    socklen_t len = sizeof(soErr);
                    getsockopt(s, SOL_SOCKET, SO_ERROR, &soErr, &len);
                    if (soErr == 0) {
                        fd_ = s;
                        break;
                    }
                    lastErr = soErr;
                } else {
                    lastErr = (pr == 0) ? ETIMEDOUT : errno;
                }
            } else {
                lastErr = errno;
            }
            close(s);
        }
        freeaddrinfo(res);

        if (fd_ < 0) {
            outError = "TCP connect to " + host + ":" + portStr + " failed: " + std::strerror(lastErr);
            return false;
        }
        return true;
    }

    void Close()
    {
        if (fd_ >= 0) {
            close(fd_);
            fd_ = -1;
        }
    }

    bool WriteAll(const uint8_t *data, size_t len, std::chrono::steady_clock::time_point deadline, std::string &outError)
    {
        size_t sent = 0;
        while (sent < len) {
            auto remMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                deadline - std::chrono::steady_clock::now()).count();
            if (remMs <= 0) {
                outError = "SSH write timed out";
                return false;
            }
            struct pollfd pfd { fd_, POLLOUT, 0 };
            int pr = poll(&pfd, 1, static_cast<int>(std::min<int64_t>(remMs, 5000)));
            if (pr < 0) {
                if (errno == EINTR) continue;
                outError = std::string("Socket poll error: ") + std::strerror(errno);
                return false;
            }
            if (pr == 0) continue;

            ssize_t n = send(fd_, data + sent, len - sent, MSG_NOSIGNAL);
            if (n < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) continue;
                outError = std::string("Socket send error: ") + std::strerror(errno);
                return false;
            }
            sent += static_cast<size_t>(n);
        }
        return true;
    }

    bool ReadExact(uint8_t *out, size_t len, std::chrono::steady_clock::time_point deadline, std::string &outError)
    {
        size_t got = 0;
        while (got < len) {
            auto remMs = std::chrono::duration_cast<std::chrono::milliseconds>(
                deadline - std::chrono::steady_clock::now()).count();
            if (remMs <= 0) {
                outError = "SSH read timed out";
                return false;
            }
            struct pollfd pfd { fd_, POLLIN, 0 };
            int pr = poll(&pfd, 1, static_cast<int>(std::min<int64_t>(remMs, 5000)));
            if (pr < 0) {
                if (errno == EINTR) continue;
                outError = std::string("Socket poll error: ") + std::strerror(errno);
                return false;
            }
            if (pr == 0) continue;

            ssize_t n = recv(fd_, out + got, len - got, 0);
            if (n == 0) {
                outError = "Remote host closed SSH connection unexpectedly";
                return false;
            }
            if (n < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) continue;
                outError = std::string("Socket recv error: ") + std::strerror(errno);
                return false;
            }
            got += static_cast<size_t>(n);
        }
        return true;
    }

    bool ReadLine(std::string &outLine, std::chrono::steady_clock::time_point deadline, std::string &outError)
    {
        outLine.clear();
        while (outLine.size() < 512) {
            uint8_t ch = 0;
            if (!ReadExact(&ch, 1, deadline, outError)) {
                return false;
            }
            if (ch == '\n') {
                if (!outLine.empty() && outLine.back() == '\r') {
                    outLine.pop_back();
                }
                return true;
            }
            outLine.push_back(static_cast<char>(ch));
        }
        outError = "SSH banner line exceeded maximum length";
        return false;
    }

private:
    int fd_ = -1;
};

bool VerifyHostKeySignature(const std::vector<uint8_t> &hostKeyBlob,
                            const std::vector<uint8_t> &sigBlob,
                            const uint8_t exchangeHash[32],
                            std::string &outError)
{
    std::string keyType;
    std::vector<uint8_t> spkiDer;
    if (!ssh::SshHostKeyToSpkiDer(hostKeyBlob, keyType, spkiDer)) {
        outError = "Unsupported server host key type or malformed key blob";
        return false;
    }

    std::string sigAlgo;
    std::vector<uint8_t> verifySigBytes;
    if (!ssh::ParseSshSignatureBlob(sigBlob, sigAlgo, verifySigBytes)) {
        outError = "Malformed server host key signature blob";
        return false;
    }

    std::vector<const char *> keyGenAlgos;
    std::vector<const char *> verifyAlgos;
    if (keyType == "ssh-rsa") {
        keyGenAlgos = { "RSA", "RSA2048", "RSA3072", "RSA4096" };
        if (sigAlgo == "rsa-sha2-512") {
            verifyAlgos = { "RSA|PKCS1|SHA512", "RSA2048|PKCS1|SHA512", "RSA3072|PKCS1|SHA512", "RSA4096|PKCS1|SHA512" };
        } else if (sigAlgo == "rsa-sha2-256") {
            verifyAlgos = { "RSA|PKCS1|SHA256", "RSA2048|PKCS1|SHA256", "RSA3072|PKCS1|SHA256", "RSA4096|PKCS1|SHA256" };
        } else if (sigAlgo == "ssh-rsa") {
            verifyAlgos = { "RSA|PKCS1|SHA1", "RSA2048|PKCS1|SHA1", "RSA1024|PKCS1|SHA1" };
        } else {
            outError = "Unsupported RSA signature algorithm: " + sigAlgo;
            return false;
        }
    } else if (keyType == "ecdsa-sha2-nistp256") {
        keyGenAlgos = { "ECC256", "ECC" };
        verifyAlgos = { "ECC256|SHA256", "ECC|SHA256" };
    } else if (keyType == "ssh-ed25519") {
        keyGenAlgos = { "Ed25519" };
        verifyAlgos = { "Ed25519" };
    } else {
        outError = "Unsupported host key type: " + keyType;
        return false;
    }

    OH_CryptoKeyPair *kp = nullptr;
    for (const char *algo : keyGenAlgos) {
        OH_CryptoAsymKeyGenerator *gen = nullptr;
        if (OH_CryptoAsymKeyGenerator_Create(algo, &gen) != CRYPTO_SUCCESS || gen == nullptr) {
            continue;
        }
        Crypto_DataBlob pubBlob = { spkiDer.data(), spkiDer.size() };
        OH_Crypto_ErrCode st = OH_CryptoAsymKeyGenerator_Convert(gen, CRYPTO_DER, &pubBlob, nullptr, &kp);
        OH_CryptoAsymKeyGenerator_Destroy(gen);
        if (st == CRYPTO_SUCCESS && kp != nullptr) {
            break;
        }
        kp = nullptr;
    }
    if (kp == nullptr) {
        outError = "Failed to import server public key (" + keyType + ") into CryptoKit";
        return false;
    }

    OH_CryptoPubKey *pubKey = OH_CryptoKeyPair_GetPubKey(kp);
    bool verified = false;
    bool triedAny = false;
    for (const char *vAlgo : verifyAlgos) {
        OH_CryptoVerify *verifyCtx = nullptr;
        if (OH_CryptoVerify_Create(vAlgo, &verifyCtx) != CRYPTO_SUCCESS || verifyCtx == nullptr) {
            continue;
        }
        if (OH_CryptoVerify_Init(verifyCtx, pubKey) == CRYPTO_SUCCESS) {
            triedAny = true;
            Crypto_DataBlob dataBlob = { const_cast<uint8_t *>(exchangeHash), 32 };
            Crypto_DataBlob sigData = { verifySigBytes.data(), verifySigBytes.size() };
            verified = OH_CryptoVerify_Final(verifyCtx, &dataBlob, &sigData);
        }
        OH_CryptoVerify_Destroy(verifyCtx);
        if (triedAny) {
            break;
        }
    }
    OH_CryptoKeyPair_Destroy(kp);

    if (!triedAny) {
        outError = "CryptoKit does not support verification for " + sigAlgo;
        return false;
    }
    if (!verified) {
        outError = "Server host key signature verification FAILED (" + sigAlgo + ")";
        return false;
    }
    return true;
}

class SshTransport {
public:
    SshSocket sock;
    SymStreamCipher c2sCipher;
    SymStreamCipher s2cCipher;
    uint32_t c2sSeq = 0;
    uint32_t s2cSeq = 0;

    bool SendPacket(const std::vector<uint8_t> &payload,
                    std::chrono::steady_clock::time_point deadline,
                    std::string &outError)
    {
        size_t align = c2sCipher.active ? 16 : 8;
        std::vector<uint8_t> plain = ssh::FrameSshPacket(payload, align, CryptoRandomBytes);

        std::vector<uint8_t> wire;
        if (!c2sCipher.active) {
            wire = std::move(plain);
        } else {
            uint8_t mac[32];
            ssh::SshBuf macIn;
            macIn.WriteUint32(c2sSeq);
            macIn.WriteRaw(plain.data(), plain.size());
            if (!ComputeHmacSha256(c2sCipher.macKey, macIn.Bytes().data(), macIn.Bytes().size(), mac)) {
                outError = "Failed to compute outbound SSH HMAC-SHA256";
                return false;
            }
            if (!c2sCipher.UpdateExactBlocks(plain.data(), plain.size(), wire)) {
                outError = "Failed to encrypt outbound SSH packet";
                return false;
            }
            wire.insert(wire.end(), mac, mac + 32);
        }
        c2sSeq++;
        return sock.WriteAll(wire.data(), wire.size(), deadline, outError);
    }

    bool RecvRawPacket(std::vector<uint8_t> &outPayload,
                       std::chrono::steady_clock::time_point deadline,
                       std::string &outError)
    {
        std::vector<uint8_t> plainPacket;
        if (!s2cCipher.active) {
            uint8_t lenBuf[4];
            if (!sock.ReadExact(lenBuf, 4, deadline, outError)) {
                return false;
            }
            uint32_t pktLen = (static_cast<uint32_t>(lenBuf[0]) << 24) |
                              (static_cast<uint32_t>(lenBuf[1]) << 16) |
                              (static_cast<uint32_t>(lenBuf[2]) << 8) |
                              static_cast<uint32_t>(lenBuf[3]);
            if (pktLen < 5 || pktLen > kMaxSshPacketBytes) {
                outError = "Invalid unencrypted SSH packet length";
                return false;
            }
            plainPacket.resize(4 + pktLen);
            std::memcpy(plainPacket.data(), lenBuf, 4);
            if (!sock.ReadExact(plainPacket.data() + 4, pktLen, deadline, outError)) {
                return false;
            }
        } else {
            // Read and decrypt the first full 16-byte cipher block so AES-CTR never sees partial blocks.
            uint8_t firstEnc[16];
            if (!sock.ReadExact(firstEnc, 16, deadline, outError)) {
                return false;
            }
            std::vector<uint8_t> firstPlain;
            if (!s2cCipher.UpdateExactBlocks(firstEnc, 16, firstPlain) || firstPlain.size() != 16) {
                outError = "Failed to decrypt SSH packet header block";
                return false;
            }
            uint32_t pktLen = (static_cast<uint32_t>(firstPlain[0]) << 24) |
                              (static_cast<uint32_t>(firstPlain[1]) << 16) |
                              (static_cast<uint32_t>(firstPlain[2]) << 8) |
                              static_cast<uint32_t>(firstPlain[3]);
            if (pktLen < 12 || pktLen > kMaxSshPacketBytes || ((4 + pktLen) % 16) != 0) {
                outError = "Invalid encrypted SSH packet length: " + std::to_string(pktLen);
                return false;
            }
            size_t totalPktBytes = 4 + static_cast<size_t>(pktLen);
            size_t remCipherBytes = totalPktBytes - 16;

            std::vector<uint8_t> remEnc(remCipherBytes);
            if (remCipherBytes > 0 && !sock.ReadExact(remEnc.data(), remCipherBytes, deadline, outError)) {
                return false;
            }
            uint8_t peerMac[32];
            if (!sock.ReadExact(peerMac, 32, deadline, outError)) {
                return false;
            }

            plainPacket = std::move(firstPlain);
            if (remCipherBytes > 0) {
                std::vector<uint8_t> remPlain;
                if (!s2cCipher.UpdateExactBlocks(remEnc.data(), remCipherBytes, remPlain)) {
                    outError = "Failed to decrypt SSH packet payload";
                    return false;
                }
                plainPacket.insert(plainPacket.end(), remPlain.begin(), remPlain.end());
            }

            ssh::SshBuf macIn;
            macIn.WriteUint32(s2cSeq);
            macIn.WriteRaw(plainPacket.data(), plainPacket.size());
            uint8_t expectedMac[32];
            if (!ComputeHmacSha256(s2cCipher.macKey, macIn.Bytes().data(), macIn.Bytes().size(), expectedMac)) {
                outError = "Failed to compute inbound HMAC-SHA256";
                return false;
            }
            if (!ConstantTimeEqual(peerMac, expectedMac, 32)) {
                outError = "SSH packet MAC verification failed";
                return false;
            }
        }
        s2cSeq++;

        if (!ssh::UnframeSshPacket(plainPacket, outPayload) || outPayload.empty()) {
            outError = "Malformed SSH packet framing";
            return false;
        }
        return true;
    }

    /** Reads next meaningful packet, skipping IGNORE/DEBUG/EXT_INFO and failing cleanly on DISCONNECT. */
    bool RecvNextPacket(std::vector<uint8_t> &outPayload,
                        std::chrono::steady_clock::time_point deadline,
                        std::string &outError)
    {
        for (;;) {
            if (!RecvRawPacket(outPayload, deadline, outError)) {
                return false;
            }
            uint8_t msgType = outPayload[0];
            if (msgType == SSH_MSG_IGNORE || msgType == SSH_MSG_DEBUG || msgType == SSH_MSG_EXT_INFO) {
                continue;
            }
            if (msgType == SSH_MSG_DISCONNECT) {
                ssh::SshBuf b(outPayload);
                uint8_t mt = 0;
                uint32_t reason = 0;
                std::string desc;
                b.ReadUint8(mt);
                b.ReadUint32(reason);
                b.ReadString(desc);
                outError = "Server disconnected (" + std::to_string(reason) + "): " + desc;
                return false;
            }
            return true;
        }
    }
};

struct RsaClientKey {
    OH_CryptoKeyPair *kp = nullptr;
    std::vector<uint8_t> sshPubKeyBlob;

    ~RsaClientKey()
    {
        if (kp != nullptr) {
            OH_CryptoKeyPair_Destroy(kp);
        }
    }

    bool LoadFromPem(const std::string &pemText, std::string &outError)
    {
        std::string label;
        std::vector<uint8_t> der;
        if (!ssh::DecodePemBlock(pemText, label, der)) {
            outError = "Private key is not a valid PEM block";
            return false;
        }
        if (label.find("OPENSSH") != std::string::npos) {
            outError = "OpenSSH new-format private key is not supported yet; convert to PEM PKCS8/RSA (`ssh-keygen -p -m PEM` or `openssl pkcs8 -topk8 -nocrypt`) or use password auth";
            return false;
        }
        std::vector<uint8_t> pkcs8Der = (label == "RSA PRIVATE KEY")
            ? ssh::WrapPkcs1RsaPrivateKeyInPkcs8Der(der)
            : der;

        for (const char *algo : { "RSA", "RSA2048", "RSA3072", "RSA4096" }) {
            OH_CryptoAsymKeyGenerator *gen = nullptr;
            if (OH_CryptoAsymKeyGenerator_Create(algo, &gen) != CRYPTO_SUCCESS || gen == nullptr) {
                continue;
            }
            Crypto_DataBlob priBlob = { pkcs8Der.data(), pkcs8Der.size() };
            OH_Crypto_ErrCode st = OH_CryptoAsymKeyGenerator_Convert(gen, CRYPTO_DER, nullptr, &priBlob, &kp);
            OH_CryptoAsymKeyGenerator_Destroy(gen);
            if (st == CRYPTO_SUCCESS && kp != nullptr) {
                break;
            }
            kp = nullptr;
        }
        if (kp == nullptr) {
            outError = "Failed to import RSA private key into CryptoKit (ensure unencrypted PEM PKCS#8 or RSA PRIVATE KEY)";
            return false;
        }

        OH_CryptoPubKey *pub = OH_CryptoKeyPair_GetPubKey(kp);
        Crypto_DataBlob eBlob = { nullptr, 0 };
        Crypto_DataBlob nBlob = { nullptr, 0 };
        OH_Crypto_ErrCode stE = OH_CryptoPubKey_GetParam(pub, CRYPTO_RSA_E_DATABLOB, &eBlob);
        OH_Crypto_ErrCode stN = OH_CryptoPubKey_GetParam(pub, CRYPTO_RSA_N_DATABLOB, &nBlob);
        if (stE != CRYPTO_SUCCESS || stN != CRYPTO_SUCCESS || eBlob.data == nullptr || nBlob.data == nullptr) {
            if (eBlob.data) OH_Crypto_FreeDataBlob(&eBlob);
            if (nBlob.data) OH_Crypto_FreeDataBlob(&nBlob);
            outError = "Failed to extract RSA modulus/exponent from private key";
            return false;
        }
        std::vector<uint8_t> eVec(eBlob.data, eBlob.data + eBlob.len);
        std::vector<uint8_t> nVec(nBlob.data, nBlob.data + nBlob.len);
        OH_Crypto_FreeDataBlob(&eBlob);
        OH_Crypto_FreeDataBlob(&nBlob);
        sshPubKeyBlob = ssh::BuildSshRsaPubKeyBlob(eVec, nVec);
        return true;
    }

    bool Sign(const std::vector<uint8_t> &message, const std::string &sshSigAlgo,
              std::vector<uint8_t> &outSshSigBlob, std::string &outError)
    {
        if (kp == nullptr) {
            outError = "Client RSA keypair not loaded";
            return false;
        }
        std::vector<const char *> signAlgos;
        if (sshSigAlgo == "rsa-sha2-512") {
            signAlgos = { "RSA|PKCS1|SHA512", "RSA2048|PKCS1|SHA512", "RSA3072|PKCS1|SHA512", "RSA4096|PKCS1|SHA512" };
        } else if (sshSigAlgo == "rsa-sha2-256") {
            signAlgos = { "RSA|PKCS1|SHA256", "RSA2048|PKCS1|SHA256", "RSA3072|PKCS1|SHA256", "RSA4096|PKCS1|SHA256" };
        } else {
            signAlgos = { "RSA|PKCS1|SHA1", "RSA2048|PKCS1|SHA1" };
        }

        OH_CryptoPrivKey *priv = OH_CryptoKeyPair_GetPrivKey(kp);
        Crypto_DataBlob rawSig = { nullptr, 0 };
        bool signedOk = false;
        for (const char *algo : signAlgos) {
            OH_CryptoSign *signCtx = nullptr;
            if (OH_CryptoSign_Create(algo, &signCtx) != CRYPTO_SUCCESS || signCtx == nullptr) {
                continue;
            }
            if (OH_CryptoSign_Init(signCtx, priv) == CRYPTO_SUCCESS) {
                Crypto_DataBlob msgBlob = { const_cast<uint8_t *>(message.data()), message.size() };
                if (OH_CryptoSign_Update(signCtx, &msgBlob) == CRYPTO_SUCCESS &&
                    OH_CryptoSign_Final(signCtx, nullptr, &rawSig) == CRYPTO_SUCCESS &&
                    rawSig.data != nullptr) {
                    signedOk = true;
                }
            }
            OH_CryptoSign_Destroy(signCtx);
            if (signedOk) break;
            if (rawSig.data != nullptr) {
                OH_Crypto_FreeDataBlob(&rawSig);
                rawSig = { nullptr, 0 };
            }
        }
        if (!signedOk) {
            outError = "CryptoKit RSA signature failed for " + sshSigAlgo;
            return false;
        }

        ssh::SshBuf sigBuf;
        sigBuf.WriteString(sshSigAlgo);
        sigBuf.WriteString(std::vector<uint8_t>(rawSig.data, rawSig.data + rawSig.len));
        OH_Crypto_FreeDataBlob(&rawSig);
        outSshSigBlob = sigBuf.Bytes();
        return true;
    }
};

std::vector<uint8_t> BuildClientKexInit()
{
    ssh::SshBuf buf;
    buf.WriteUint8(SSH_MSG_KEXINIT);
    uint8_t cookie[16] = {0};
    CryptoRandomBytes(cookie, sizeof(cookie));
    buf.WriteRaw(cookie, sizeof(cookie));
    buf.WriteNameList({ "curve25519-sha256", "curve25519-sha256@libssh.org", "ext-info-c" });
    buf.WriteNameList({ "rsa-sha2-512", "rsa-sha2-256", "ecdsa-sha2-nistp256", "ssh-ed25519", "ssh-rsa" });
    buf.WriteNameList({ "aes256-ctr", "aes128-ctr" });
    buf.WriteNameList({ "aes256-ctr", "aes128-ctr" });
    buf.WriteNameList({ "hmac-sha2-256" });
    buf.WriteNameList({ "hmac-sha2-256" });
    buf.WriteNameList({ "none" });
    buf.WriteNameList({ "none" });
    buf.WriteNameList({});
    buf.WriteNameList({});
    buf.WriteBool(false);
    buf.WriteUint32(0);
    return buf.Bytes();
}

bool PerformHandshakeAndKex(SshTransport &t, const SshExecRequest &req,
                            std::chrono::steady_clock::time_point deadline,
                            uint8_t outSessionId[32], std::string &outFingerprint,
                            std::string &outError)
{
    // 1. Exchange SSH-2.0 banners
    std::string clientBannerLine = std::string(kClientIdent) + "\r\n";
    if (!t.sock.WriteAll(reinterpret_cast<const uint8_t *>(clientBannerLine.data()),
                         clientBannerLine.size(), deadline, outError)) {
        return false;
    }
    std::string serverIdent;
    bool gotServerIdent = false;
    for (int i = 0; i < 32; ++i) {
        std::string line;
        if (!t.sock.ReadLine(line, deadline, outError)) {
            return false;
        }
        if (line.rfind("SSH-2.0-", 0) == 0 || line.rfind("SSH-1.99-", 0) == 0) {
            serverIdent = line;
            gotServerIdent = true;
            break;
        }
    }
    if (!gotServerIdent) {
        outError = "Did not receive valid SSH-2.0 server identification banner";
        return false;
    }

    // 2. Exchange KEXINIT
    std::vector<uint8_t> clientKexInit = BuildClientKexInit();
    if (!t.SendPacket(clientKexInit, deadline, outError)) {
        return false;
    }

    std::vector<uint8_t> serverKexInit;
    if (!t.RecvNextPacket(serverKexInit, deadline, outError)) {
        return false;
    }
    if (serverKexInit.empty() || serverKexInit[0] != SSH_MSG_KEXINIT) {
        outError = "Expected SSH_MSG_KEXINIT from server";
        return false;
    }

    ssh::SshBuf sk(serverKexInit);
    uint8_t kexMsg = 0;
    std::vector<uint8_t> cookie;
    std::string kexStr, hkStr, encC2S, encS2C, macC2S, macS2C, cmpC2S, cmpS2C, lang1, lang2;
    bool firstKexFollows = false;
    if (!sk.ReadUint8(kexMsg) || !sk.ReadRaw(16, cookie) ||
        !sk.ReadString(kexStr) || !sk.ReadString(hkStr) ||
        !sk.ReadString(encC2S) || !sk.ReadString(encS2C) ||
        !sk.ReadString(macC2S) || !sk.ReadString(macS2C) ||
        !sk.ReadString(cmpC2S) || !sk.ReadString(cmpS2C) ||
        !sk.ReadString(lang1) || !sk.ReadString(lang2) ||
        !sk.ReadBool(firstKexFollows)) {
        outError = "Failed to parse server SSH_MSG_KEXINIT";
        return false;
    }

    std::string chosenKex = NegotiateFirst({ "curve25519-sha256", "curve25519-sha256@libssh.org" }, SplitCsv(kexStr));
    std::string chosenHostKey = NegotiateFirst(
        { "rsa-sha2-512", "rsa-sha2-256", "ecdsa-sha2-nistp256", "ssh-ed25519", "ssh-rsa" }, SplitCsv(hkStr));
    std::string chosenC2SCipher = NegotiateFirst({ "aes256-ctr", "aes128-ctr" }, SplitCsv(encC2S));
    std::string chosenS2CCipher = NegotiateFirst({ "aes256-ctr", "aes128-ctr" }, SplitCsv(encS2C));
    std::string chosenC2SMac = NegotiateFirst({ "hmac-sha2-256" }, SplitCsv(macC2S));
    std::string chosenS2CMac = NegotiateFirst({ "hmac-sha2-256" }, SplitCsv(macS2C));

    if (chosenKex.empty() || chosenHostKey.empty() ||
        chosenC2SCipher.empty() || chosenS2CCipher.empty() ||
        chosenC2SMac.empty() || chosenS2CMac.empty()) {
        outError = "SSH algorithm negotiation failed (kex=" + kexStr + ", hk=" + hkStr +
                   ", enc=" + encC2S + ", mac=" + macC2S + ")";
        return false;
    }

    if (firstKexFollows) {
        auto srvKexFirst = SplitCsv(kexStr);
        if (srvKexFirst.empty() || srvKexFirst[0] != chosenKex) {
            std::vector<uint8_t> discarded;
            if (!t.RecvNextPacket(discarded, deadline, outError)) {
                return false;
            }
        }
    }

    // 3. Curve25519 ECDH exchange
    uint8_t clientPriv[32];
    if (!CryptoRandomBytes(clientPriv, sizeof(clientPriv))) {
        outError = "Failed to generate ephemeral X25519 key";
        return false;
    }
    uint8_t clientPub[32];
    ssh::X25519PublicFromPrivate(clientPub, clientPriv);

    ssh::SshBuf ecdhInit;
    ecdhInit.WriteUint8(SSH_MSG_KEX_ECDH_INIT);
    ecdhInit.WriteString(std::vector<uint8_t>(clientPub, clientPub + 32));
    if (!t.SendPacket(ecdhInit.Bytes(), deadline, outError)) {
        return false;
    }

    std::vector<uint8_t> replyPkt;
    if (!t.RecvNextPacket(replyPkt, deadline, outError)) {
        return false;
    }
    if (replyPkt.empty() || replyPkt[0] != SSH_MSG_KEX_ECDH_REPLY) {
        outError = "Expected SSH_MSG_KEX_ECDH_REPLY from server";
        return false;
    }

    ssh::SshBuf rb(replyPkt);
    uint8_t replyType = 0;
    std::vector<uint8_t> serverHostKeyBlob, serverPubVec, sigBlob;
    if (!rb.ReadUint8(replyType) ||
        !rb.ReadBytes(serverHostKeyBlob) ||
        !rb.ReadBytes(serverPubVec) ||
        !rb.ReadBytes(sigBlob) ||
        serverPubVec.size() != 32) {
        outError = "Malformed SSH_MSG_KEX_ECDH_REPLY";
        return false;
    }

    uint8_t serverPub[32];
    std::memcpy(serverPub, serverPubVec.data(), 32);
    uint8_t sharedSecret[32];
    ssh::X25519ScalarMult(sharedSecret, clientPriv, serverPub);
    std::memset(clientPriv, 0, sizeof(clientPriv));

    // Check shared secret is non-zero (RFC 7748 contributory behavior)
    bool allZero = true;
    for (uint8_t b : sharedSecret) {
        if (b != 0) {
            allZero = false;
            break;
        }
    }
    if (allZero) {
        outError = "Invalid zero shared secret in Curve25519 KEX";
        return false;
    }

    std::vector<uint8_t> sharedRaw(sharedSecret, sharedSecret + 32);
    std::vector<uint8_t> hashInput = ssh::BuildCurve25519ExchangeHashInput(
        kClientIdent, serverIdent, clientKexInit, serverKexInit,
        serverHostKeyBlob, clientPub, serverPub, sharedRaw);

    uint8_t exchangeHash[32];
    if (!CryptoSha256(hashInput.data(), hashInput.size(), exchangeHash)) {
        outError = "Failed to hash SSH KEX exchange transcript";
        return false;
    }
    std::memcpy(outSessionId, exchangeHash, 32);

    if (!ssh::ComputeSshFingerprint(serverHostKeyBlob, CryptoSha256, outFingerprint)) {
        outError = "Failed to compute server host key fingerprint";
        return false;
    }
    if (!req.expectedFingerprint.empty() && req.expectedFingerprint != outFingerprint) {
        outError = "Host key fingerprint mismatch! Expected " + req.expectedFingerprint +
                   ", server presented " + outFingerprint;
        return false;
    }

    if (!VerifyHostKeySignature(serverHostKeyBlob, sigBlob, exchangeHash, outError)) {
        return false;
    }

    // 4. Switch to encrypted transport keys (NEWKEYS)
    if (!t.SendPacket({ SSH_MSG_NEWKEYS }, deadline, outError)) {
        return false;
    }
    std::vector<uint8_t> srvNewKeys;
    if (!t.RecvNextPacket(srvNewKeys, deadline, outError) || srvNewKeys.empty() || srvNewKeys[0] != SSH_MSG_NEWKEYS) {
        outError = outError.empty() ? "Expected SSH_MSG_NEWKEYS from server" : outError;
        return false;
    }

    std::vector<uint8_t> ivC2S, ivS2C, keyC2S, keyS2C, macKeyC2S, macKeyS2C;
    size_t c2sKeyLen = (chosenC2SCipher == "aes128-ctr") ? 16 : 32;
    size_t s2cKeyLen = (chosenS2CCipher == "aes128-ctr") ? 16 : 32;
    if (!ssh::DeriveSshKey(sharedRaw, exchangeHash, 'A', outSessionId, 16, CryptoSha256, ivC2S) ||
        !ssh::DeriveSshKey(sharedRaw, exchangeHash, 'B', outSessionId, 16, CryptoSha256, ivS2C) ||
        !ssh::DeriveSshKey(sharedRaw, exchangeHash, 'C', outSessionId, c2sKeyLen, CryptoSha256, keyC2S) ||
        !ssh::DeriveSshKey(sharedRaw, exchangeHash, 'D', outSessionId, s2cKeyLen, CryptoSha256, keyS2C) ||
        !ssh::DeriveSshKey(sharedRaw, exchangeHash, 'E', outSessionId, 32, CryptoSha256, macKeyC2S) ||
        !ssh::DeriveSshKey(sharedRaw, exchangeHash, 'F', outSessionId, 32, CryptoSha256, macKeyS2C)) {
        outError = "Failed to derive SSH transport keys";
        return false;
    }

    if (!t.c2sCipher.Init(chosenC2SCipher, CRYPTO_ENCRYPT_MODE, keyC2S, ivC2S, macKeyC2S, outError) ||
        !t.s2cCipher.Init(chosenS2CCipher, CRYPTO_DECRYPT_MODE, keyS2C, ivS2C, macKeyS2C, outError)) {
        return false;
    }
    return true;
}

bool AuthenticateSession(SshTransport &t, const SshExecRequest &req,
                         const uint8_t sessionId[32],
                         std::chrono::steady_clock::time_point deadline,
                         std::string &outError)
{
    ssh::SshBuf svcReq;
    svcReq.WriteUint8(SSH_MSG_SERVICE_REQUEST);
    svcReq.WriteString("ssh-userauth");
    if (!t.SendPacket(svcReq.Bytes(), deadline, outError)) {
        return false;
    }

    std::vector<uint8_t> svcResp;
    if (!t.RecvNextPacket(svcResp, deadline, outError) || svcResp.empty() || svcResp[0] != SSH_MSG_SERVICE_ACCEPT) {
        outError = outError.empty() ? "Server rejected ssh-userauth service request" : outError;
        return false;
    }

    // Try RSA public key authentication first if privateKeyPem is configured
    std::string availableMethods;
    if (!req.privateKeyPem.empty()) {
        RsaClientKey clientKey;
        if (!clientKey.LoadFromPem(req.privateKeyPem, outError)) {
            return false;
        }

        for (const std::string &sigAlg : { std::string("rsa-sha2-256"), std::string("rsa-sha2-512"), std::string("ssh-rsa") }) {
            ssh::SshBuf body;
            body.WriteUint8(SSH_MSG_USERAUTH_REQUEST);
            body.WriteString(req.username);
            body.WriteString("ssh-connection");
            body.WriteString("publickey");
            body.WriteBool(true);
            body.WriteString(sigAlg);
            body.WriteString(clientKey.sshPubKeyBlob);

            ssh::SshBuf toSign;
            toSign.WriteString(std::vector<uint8_t>(sessionId, sessionId + 32));
            toSign.WriteRaw(body.Bytes().data(), body.Bytes().size());

            std::vector<uint8_t> sigBlob;
            if (!clientKey.Sign(toSign.Bytes(), sigAlg, sigBlob, outError)) {
                return false;
            }
            body.WriteString(sigBlob);
            if (!t.SendPacket(body.Bytes(), deadline, outError)) {
                return false;
            }

            for (;;) {
                std::vector<uint8_t> authResp;
                if (!t.RecvNextPacket(authResp, deadline, outError)) {
                    return false;
                }
                if (authResp[0] == SSH_MSG_USERAUTH_BANNER) {
                    continue;
                }
                if (authResp[0] == SSH_MSG_USERAUTH_SUCCESS) {
                    return true;
                }
                if (authResp[0] == SSH_MSG_USERAUTH_FAILURE) {
                    ssh::SshBuf fb(authResp);
                    uint8_t mt = 0;
                    fb.ReadUint8(mt);
                    fb.ReadString(availableMethods);
                    break;
                }
            }
        }
        if (req.password.empty()) {
            outError = "Public key authentication rejected by server (allowed: " + availableMethods + ")";
            return false;
        }
    }

    if (req.password.empty()) {
        outError = "SSH password or private key is required";
        return false;
    }

    // Attempt password authentication
    ssh::SshBuf pwReq;
    pwReq.WriteUint8(SSH_MSG_USERAUTH_REQUEST);
    pwReq.WriteString(req.username);
    pwReq.WriteString("ssh-connection");
    pwReq.WriteString("password");
    pwReq.WriteBool(false);
    pwReq.WriteString(req.password);
    if (!t.SendPacket(pwReq.Bytes(), deadline, outError)) {
        return false;
    }

    for (;;) {
        std::vector<uint8_t> authResp;
        if (!t.RecvNextPacket(authResp, deadline, outError)) {
            return false;
        }
        if (authResp[0] == SSH_MSG_USERAUTH_BANNER) {
            continue;
        }
        if (authResp[0] == SSH_MSG_USERAUTH_SUCCESS) {
            return true;
        }
        if (authResp[0] == SSH_MSG_USERAUTH_FAILURE) {
            ssh::SshBuf fb(authResp);
            uint8_t mt = 0;
            fb.ReadUint8(mt);
            fb.ReadString(availableMethods);
            break;
        }
    }

    // Fallback to keyboard-interactive (common with PAM-enabled OpenSSH servers)
    if (availableMethods.find("keyboard-interactive") != std::string::npos) {
        ssh::SshBuf kiReq;
        kiReq.WriteUint8(SSH_MSG_USERAUTH_REQUEST);
        kiReq.WriteString(req.username);
        kiReq.WriteString("ssh-connection");
        kiReq.WriteString("keyboard-interactive");
        kiReq.WriteString("");
        kiReq.WriteString("");
        if (!t.SendPacket(kiReq.Bytes(), deadline, outError)) {
            return false;
        }
        for (;;) {
            std::vector<uint8_t> resp;
            if (!t.RecvNextPacket(resp, deadline, outError)) {
                return false;
            }
            if (resp[0] == SSH_MSG_USERAUTH_BANNER) {
                continue;
            }
            if (resp[0] == SSH_MSG_USERAUTH_SUCCESS) {
                return true;
            }
            if (resp[0] == SSH_MSG_USERAUTH_INFO_REQUEST) {
                ssh::SshBuf ir(resp);
                uint8_t mt = 0;
                std::string name, instr, lang;
                uint32_t numPrompts = 0;
                ir.ReadUint8(mt);
                ir.ReadString(name);
                ir.ReadString(instr);
                ir.ReadString(lang);
                ir.ReadUint32(numPrompts);

                ssh::SshBuf irAns;
                irAns.WriteUint8(SSH_MSG_USERAUTH_INFO_RESPONSE);
                irAns.WriteUint32(numPrompts);
                for (uint32_t i = 0; i < numPrompts; ++i) {
                    irAns.WriteString(req.password);
                }
                if (!t.SendPacket(irAns.Bytes(), deadline, outError)) {
                    return false;
                }
                continue;
            }
            if (resp[0] == SSH_MSG_USERAUTH_FAILURE) {
                break;
            }
        }
    }

    outError = "SSH authentication failed for user '" + req.username + "' (server methods: " +
               (availableMethods.empty() ? "unknown" : availableMethods) + ")";
    return false;
}

void AppendBounded(std::string &dst, const std::string &chunk, bool &truncatedFlag)
{
    if (truncatedFlag || chunk.empty()) {
        return;
    }
    if (dst.size() + chunk.size() <= kMaxOutputCaptureBytes) {
        dst.append(chunk);
    } else {
        size_t avail = kMaxOutputCaptureBytes > dst.size() ? kMaxOutputCaptureBytes - dst.size() : 0;
        if (avail > 0) {
            dst.append(chunk.substr(0, avail));
        }
        dst.append("\n...[remote output truncated at 512 KB]");
        truncatedFlag = true;
    }
}

}  // namespace

SshExecResult ExecuteSshCommand(const SshExecRequest &request)
{
    SshExecResult res;
    if (request.host.empty() || request.username.empty() || request.command.empty()) {
        res.error = "SSH host, username, and command are required";
        return res;
    }

    const int port = (request.port > 0 && request.port <= 65535) ? request.port : 22;
    const int timeoutSec = std::max(3, std::min(300, request.timeoutSeconds > 0 ? request.timeoutSeconds : 30));
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(timeoutSec);

    SshTransport t;
    if (!t.sock.Connect(request.host, port, timeoutSec, res.error)) {
        return res;
    }

    uint8_t sessionId[32] = {0};
    if (!PerformHandshakeAndKex(t, request, deadline, sessionId, res.hostFingerprint, res.error)) {
        return res;
    }

    if (!AuthenticateSession(t, request, sessionId, deadline, res.error)) {
        return res;
    }

    // Open session channel
    constexpr uint32_t kLocalChanId = 0;
    ssh::SshBuf chOpen;
    chOpen.WriteUint8(SSH_MSG_CHANNEL_OPEN);
    chOpen.WriteString("session");
    chOpen.WriteUint32(kLocalChanId);
    chOpen.WriteUint32(kInitialWindowSize);
    chOpen.WriteUint32(kMaxChannelPacketSize);
    if (!t.SendPacket(chOpen.Bytes(), deadline, res.error)) {
        return res;
    }

    uint32_t remoteChanId = 0;
    for (;;) {
        std::vector<uint8_t> pkt;
        if (!t.RecvNextPacket(pkt, deadline, res.error)) {
            return res;
        }
        if (pkt[0] == SSH_MSG_GLOBAL_REQUEST) {
            continue;
        }
        if (pkt[0] == SSH_MSG_CHANNEL_OPEN_CONFIRMATION) {
            ssh::SshBuf ob(pkt);
            uint8_t mt = 0;
            uint32_t recipient = 0;
            ob.ReadUint8(mt);
            ob.ReadUint32(recipient);
            if (!ob.ReadUint32(remoteChanId)) {
                res.error = "Malformed SSH_MSG_CHANNEL_OPEN_CONFIRMATION";
                return res;
            }
            break;
        }
        if (pkt[0] == SSH_MSG_CHANNEL_OPEN_FAILURE) {
            ssh::SshBuf fb(pkt);
            uint8_t mt = 0;
            uint32_t recip = 0, reason = 0;
            std::string desc;
            fb.ReadUint8(mt);
            fb.ReadUint32(recip);
            fb.ReadUint32(reason);
            fb.ReadString(desc);
            res.error = "Server refused session channel (" + std::to_string(reason) + "): " + desc;
            return res;
        }
    }

    // Request "exec"
    ssh::SshBuf execReq;
    execReq.WriteUint8(SSH_MSG_CHANNEL_REQUEST);
    execReq.WriteUint32(remoteChanId);
    execReq.WriteString("exec");
    execReq.WriteBool(true);
    execReq.WriteString(request.command);
    if (!t.SendPacket(execReq.Bytes(), deadline, res.error)) {
        return res;
    }

    bool execConfirmed = false;
    bool gotExitStatus = false;
    bool sawEof = false;
    bool sawClose = false;
    bool outTrunc = false;
    bool errTrunc = false;
    uint32_t unackedWindowBytes = 0;

    while (!sawClose) {
        std::vector<uint8_t> pkt;
        std::string recvErr;
        if (!t.RecvNextPacket(pkt, deadline, recvErr)) {
            if (gotExitStatus && sawEof) {
                // Server already sent exit-status + EOF before closing TCP
                break;
            }
            res.error = recvErr;
            return res;
        }
        uint8_t mt = pkt[0];
        if (mt == SSH_MSG_GLOBAL_REQUEST) {
            continue;
        }
        if (mt == SSH_MSG_CHANNEL_SUCCESS) {
            execConfirmed = true;
            continue;
        }
        if (mt == SSH_MSG_CHANNEL_FAILURE && !execConfirmed) {
            res.error = "Remote SSH server rejected 'exec' request";
            return res;
        }
        if (mt == SSH_MSG_CHANNEL_DATA) {
            ssh::SshBuf db(pkt);
            uint8_t msg = 0;
            uint32_t ch = 0;
            std::string chunk;
            db.ReadUint8(msg);
            db.ReadUint32(ch);
            if (db.ReadString(chunk)) {
                AppendBounded(res.output, chunk, outTrunc);
                unackedWindowBytes += static_cast<uint32_t>(chunk.size());
            }
        } else if (mt == SSH_MSG_CHANNEL_EXTENDED_DATA) {
            ssh::SshBuf db(pkt);
            uint8_t msg = 0;
            uint32_t ch = 0, dataType = 0;
            std::string chunk;
            db.ReadUint8(msg);
            db.ReadUint32(ch);
            db.ReadUint32(dataType);
            if (db.ReadString(chunk)) {
                AppendBounded(res.stderrOutput, chunk, errTrunc);
                unackedWindowBytes += static_cast<uint32_t>(chunk.size());
            }
        } else if (mt == SSH_MSG_CHANNEL_REQUEST) {
            ssh::SshBuf rb(pkt);
            uint8_t msg = 0;
            uint32_t ch = 0;
            std::string reqType;
            bool wantReply = false;
            rb.ReadUint8(msg);
            rb.ReadUint32(ch);
            rb.ReadString(reqType);
            rb.ReadBool(wantReply);
            if (reqType == "exit-status") {
                uint32_t code = 0;
                if (rb.ReadUint32(code)) {
                    res.exitCode = static_cast<int>(code);
                    gotExitStatus = true;
                }
            } else if (reqType == "exit-signal") {
                std::string sigName;
                rb.ReadString(sigName);
                if (!gotExitStatus) {
                    res.exitCode = 128;
                    res.error = "Remote process terminated by signal " + sigName;
                    gotExitStatus = true;
                }
            }
            if (wantReply) {
                ssh::SshBuf ack;
                ack.WriteUint8(SSH_MSG_CHANNEL_SUCCESS);
                ack.WriteUint32(remoteChanId);
                t.SendPacket(ack.Bytes(), deadline, res.error);
            }
        } else if (mt == SSH_MSG_CHANNEL_EOF) {
            sawEof = true;
        } else if (mt == SSH_MSG_CHANNEL_CLOSE) {
            sawClose = true;
        }

        if (!sawClose && !sawEof && unackedWindowBytes >= kInitialWindowSize / 2) {
            ssh::SshBuf winAdj;
            winAdj.WriteUint8(SSH_MSG_CHANNEL_WINDOW_ADJUST);
            winAdj.WriteUint32(remoteChanId);
            winAdj.WriteUint32(unackedWindowBytes);
            if (!t.SendPacket(winAdj.Bytes(), deadline, res.error)) {
                return res;
            }
            unackedWindowBytes = 0;
        }
    }

    if (!gotExitStatus) {
        res.exitCode = 0;
    }
    res.ok = (res.exitCode == 0);
    if (!res.ok && res.error.empty()) {
        res.error = "Remote command exited with status " + std::to_string(res.exitCode);
    }
    return res;
}

}  // namespace swshell

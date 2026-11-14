/*
 * HDC client key management and token signing - Crypto Architecture Kit
 * implementation.  See hdc_crypto.h for the protocol it implements.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#include "hdc_crypto.h"

#include "CryptoArchitectureKit/crypto_asym_cipher.h"
#include "CryptoArchitectureKit/crypto_asym_key.h"
#include "CryptoArchitectureKit/crypto_common.h"
#include "CryptoArchitectureKit/crypto_signature.h"
#include "ohos_base64.h"

#include <cctype>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace swshell {

namespace {

constexpr const char *kKeyAlgo = "RSA3072";
constexpr const char *kSignAlgo = "RSA3072|PSS|SHA512|MGF1_SHA512";
constexpr const char *kPublicKeyFile = "hdckey.pub.der";
constexpr const char *kPrivateKeyFile = "hdckey.pk8.der";

/* "X.509" is the SubjectPublicKeyInfo encoding; the daemon reads it with
 * PEM_read_bio_RSA_PUBKEY, so the public key must be handed over as SPKI. */

/* The daemon accepts any salt length up to the digest length; the upstream
 * client uses exactly the digest length, so ask for the same. */
constexpr int32_t kPssSaltLen = 64;

/* PEM-wrap a DER blob.  `label` is e.g. "PUBLIC KEY". */
std::string DerToPem(const Crypto_DataBlob &der, const char *label)
{
    if (der.data == nullptr || der.len == 0) {
        return std::string();
    }
    std::string base64;
    base64.resize((der.len + 2) / 3 * 4 + 4);
    int written = b64_encode_block(reinterpret_cast<uint8_t *>(&base64[0]), der.data, static_cast<int>(der.len));
    if (written <= 0) {
        return std::string();
    }
    base64.resize(static_cast<size_t>(written));

    std::string pem = "-----BEGIN ";
    pem += label;
    pem += "-----\n";
    for (size_t i = 0; i < base64.size(); i += 64) {
        pem += base64.substr(i, 64);
        pem += '\n';
    }
    pem += "-----END ";
    pem += label;
    pem += "-----\n";
    return pem;
}

bool ReadFile(const std::string &path, std::string &out)
{
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        return false;
    }
    out.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
    return true;
}

bool WriteFileAtomic(const std::string &path, const std::string &data, mode_t mode)
{
    std::string tmp = path + ".tmp";
    {
        std::ofstream out(tmp, std::ios::binary | std::ios::trunc);
        if (!out) {
            return false;
        }
        out.write(data.data(), static_cast<std::streamsize>(data.size()));
        if (!out) {
            return false;
        }
    }
    chmod(tmp.c_str(), mode);
    return rename(tmp.c_str(), path.c_str()) == 0;
}

std::string ErrText(const char *what, OH_Crypto_ErrCode code)
{
    return std::string(what) + " failed: " + std::to_string(code);
}

Crypto_DataBlob MakeBlob(std::string &data)
{
    Crypto_DataBlob blob = { reinterpret_cast<uint8_t *>(const_cast<char *>(data.data())), data.size() };
    return blob;
}

}  // namespace

HdcCrypto &HdcCrypto::Instance()
{
    static HdcCrypto instance;
    return instance;
}

HdcCrypto::~HdcCrypto()
{
    if (keyPair_ != nullptr) {
        OH_CryptoKeyPair_Destroy(static_cast<OH_CryptoKeyPair *>(keyPair_));
        keyPair_ = nullptr;
    }
}

bool HdcCrypto::EnsureKeypair(const std::string &keyDir, std::string &error)
{
    if (keyPair_ != nullptr) {
        return true;
    }
    if (!LoadKeypair(keyDir, error) && !GenerateKeypair(keyDir, error)) {
        return false;
    }
    if (hostName_.empty()) {
        char buffer[256] = {0};
        if (gethostname(buffer, sizeof(buffer) - 1) == 0) {
            hostName_ = buffer;
        }
        if (hostName_.empty()) {
            hostName_ = "swshell";
        }
    }
    return true;
}

bool HdcCrypto::ExportPublicPem(std::string &pem, std::string &error)
{
    /*
     * The Crypto Architecture Kit spells the encoding standard differently in
     * different builds ("X.509" vs "X509" vs "PKCS#1"), and a wrong spelling
     * comes back as "format is invalid".  Try the known spellings, in the
     * order we want them: SubjectPublicKeyInfo first, because that is what
     * the device's OpenSSL reads with PEM_read_bio_RSA_PUBKEY.
     */
    static const char *kEncodings[] = {"X.509", "X509", "PKCS#1", "PKCS1"};
    OH_Crypto_ErrCode lastError = CRYPTO_SUCCESS;
    for (const char *encoding : kEncodings) {
        Crypto_DataBlob encoded = { nullptr, 0 };
        OH_Crypto_ErrCode ret = OH_CryptoPubKey_Encode(
            OH_CryptoKeyPair_GetPubKey(static_cast<OH_CryptoKeyPair *>(keyPair_)), CRYPTO_DER, encoding, &encoded);
        if (ret != CRYPTO_SUCCESS) {
            lastError = ret;
            continue;
        }
        pem = DerToPem(encoded, "PUBLIC KEY");
        OH_Crypto_FreeDataBlob(&encoded);
        if (!pem.empty()) {
            return true;
        }
    }
    error = ErrText("OH_CryptoPubKey_Encode", lastError);
    return false;
}

bool HdcCrypto::LoadKeypair(const std::string &keyDir, std::string &error)
{
    std::string pubDer;
    std::string priDer;
    if (!ReadFile(keyDir + "/" + kPublicKeyFile, pubDer) || !ReadFile(keyDir + "/" + kPrivateKeyFile, priDer)) {
        error = "no saved keypair yet";
        return false;
    }
    Crypto_DataBlob pubBlob = MakeBlob(pubDer);
    Crypto_DataBlob priBlob = MakeBlob(priDer);

    OH_CryptoAsymKeyGenerator *generator = nullptr;
    OH_Crypto_ErrCode ret = OH_CryptoAsymKeyGenerator_Create(kKeyAlgo, &generator);
    if (ret != CRYPTO_SUCCESS) {
        error = ErrText("OH_CryptoAsymKeyGenerator_Create", ret);
        return false;
    }
    OH_CryptoKeyPair *pair = nullptr;
    ret = OH_CryptoAsymKeyGenerator_Convert(generator, CRYPTO_DER, &pubBlob, &priBlob, &pair);
    OH_CryptoAsymKeyGenerator_Destroy(generator);
    if (ret != CRYPTO_SUCCESS) {
        error = ErrText("OH_CryptoAsymKeyGenerator_Convert", ret);
        return false;
    }
    keyPair_ = pair;
    return ExportPublicPem(publicKeyPem_, error);
}

bool HdcCrypto::GenerateKeypair(const std::string &keyDir, std::string &error)
{
    OH_CryptoAsymKeyGenerator *generator = nullptr;
    OH_Crypto_ErrCode ret = OH_CryptoAsymKeyGenerator_Create(kKeyAlgo, &generator);
    if (ret != CRYPTO_SUCCESS) {
        error = ErrText("OH_CryptoAsymKeyGenerator_Create", ret);
        return false;
    }
    OH_CryptoKeyPair *pair = nullptr;
    ret = OH_CryptoAsymKeyGenerator_Generate(generator, &pair);
    OH_CryptoAsymKeyGenerator_Destroy(generator);
    if (ret != CRYPTO_SUCCESS) {
        error = ErrText("OH_CryptoAsymKeyGenerator_Generate", ret);
        return false;
    }
    keyPair_ = pair;

    /*
     * Persist the keypair.  The device remembers our public key in
     * /data/service/el1/public/hdc/hdc_keys and only skips the permit dialog
     * when the same key comes back, so the keypair has to survive restarts.
     */
    Crypto_DataBlob pubEncoded = { nullptr, 0 };
    bool publicEncoded = false;
    for (const char *encoding : {"X.509", "X509", "PKCS#1", "PKCS1"}) {
        ret = OH_CryptoPubKey_Encode(OH_CryptoKeyPair_GetPubKey(pair), CRYPTO_DER, encoding, &pubEncoded);
        if (ret == CRYPTO_SUCCESS) {
            publicEncoded = true;
            break;
        }
    }
    if (!publicEncoded) {
        error = ErrText("OH_CryptoPubKey_Encode", ret);
        return false;
    }
    Crypto_DataBlob priEncoded = { nullptr, 0 };
    bool privateEncoded = false;
    for (const char *encoding : {"PKCS8", "PKCS#8"}) {
        ret = OH_CryptoPrivKey_Encode(OH_CryptoKeyPair_GetPrivKey(pair), CRYPTO_DER, encoding, nullptr,
                                       &priEncoded);
        if (ret == CRYPTO_SUCCESS) {
            privateEncoded = true;
            break;
        }
    }
    if (!privateEncoded) {
        OH_Crypto_FreeDataBlob(&pubEncoded);
        error = ErrText("OH_CryptoPrivKey_Encode", ret);
        return false;
    }
    std::string pubDer(reinterpret_cast<const char *>(pubEncoded.data), pubEncoded.len);
    std::string priDer(reinterpret_cast<const char *>(priEncoded.data), priEncoded.len);
    OH_Crypto_FreeDataBlob(&pubEncoded);
    OH_Crypto_FreeDataBlob(&priEncoded);

    WriteFileAtomic(keyDir + "/" + kPublicKeyFile, pubDer, 0644);
    if (!WriteFileAtomic(keyDir + "/" + kPrivateKeyFile, priDer, 0600)) {
        error = "failed to save the private key";
        return false;
    }
    return ExportPublicPem(publicKeyPem_, error);
}

bool HdcCrypto::SignToken(const std::string &token, std::string &signatureBase64, std::string &error)
{
    if (keyPair_ == nullptr) {
        error = "no private key loaded";
        return false;
    }
    OH_CryptoSign *sign = nullptr;
    OH_Crypto_ErrCode ret = OH_CryptoSign_Create(kSignAlgo, &sign);
    if (ret != CRYPTO_SUCCESS) {
        ret = OH_CryptoSign_Create("RSA|PSS|SHA512|MGF1_SHA512", &sign);
    }
    if (ret != CRYPTO_SUCCESS) {
        error = ErrText("OH_CryptoSign_Create", ret);
        return false;
    }
    ret = OH_CryptoSign_Init(sign, OH_CryptoKeyPair_GetPrivKey(static_cast<OH_CryptoKeyPair *>(keyPair_)));
    if (ret != CRYPTO_SUCCESS) {
        OH_CryptoSign_Destroy(sign);
        error = ErrText("OH_CryptoSign_Init", ret);
        return false;
    }
    int32_t saltLen = kPssSaltLen;
    Crypto_DataBlob saltBlob = { reinterpret_cast<uint8_t *>(&saltLen), sizeof(saltLen) };
    OH_CryptoSign_SetParam(sign, CRYPTO_PSS_SALT_LEN_INT, &saltBlob);

    Crypto_DataBlob input = { reinterpret_cast<uint8_t *>(const_cast<char *>(token.data())), token.size() };
    ret = OH_CryptoSign_Update(sign, &input);
    if (ret != CRYPTO_SUCCESS) {
        OH_CryptoSign_Destroy(sign);
        error = ErrText("OH_CryptoSign_Update", ret);
        return false;
    }
    Crypto_DataBlob signature = { nullptr, 0 };
    ret = OH_CryptoSign_Final(sign, nullptr, &signature);
    if (ret != CRYPTO_SUCCESS) {
        OH_CryptoSign_Destroy(sign);
        error = ErrText("OH_CryptoSign_Final", ret);
        return false;
    }
    OH_CryptoSign_Destroy(sign);

    std::string base64;
    base64.resize((signature.len + 2) / 3 * 4 + 4);
    int written = b64_encode_block(reinterpret_cast<uint8_t *>(&base64[0]), signature.data, static_cast<int>(signature.len));
    OH_Crypto_FreeDataBlob(&signature);
    if (written <= 0) {
        error = "failed to base64-encode the signature";
        return false;
    }
    base64.resize(static_cast<size_t>(written));
    signatureBase64 = base64;
    return true;
}

}  // namespace swshell

/*
 * HDC client key management and token signing.
 *
 * The device-side hdc daemon authenticates the client with a challenge /
 * response scheme (developtools_hdc/src/daemon/daemon.cpp):
 *
 *   1. the client sends its RSA public key (PEM, SubjectPublicKeyInfo);
 *   2. the daemon stores the SHA-256 of that key and, on the device, shows a
 *      permit dialog;
 *   3. the daemon sends a random token;
 *   4. the client signs the token and sends the signature back;
 *   5. the daemon verifies it with the stored public key.
 *
 * The signature is RSA-PSS with SHA-512 and a salt of the digest length, over
 * SHA-512(token), base64 encoded.  That is exactly what the daemon's
 * HdcDaemon::AuthVerifyRsaSign expects:
 *
 *     SHA512(token) -> EVP_PKEY_verify(ctx, sig, siglen, digest, 64)
 *
 * The upstream implementation uses OpenSSL, which is not part of the public
 * HarmonyOS NDK, so this uses the Crypto Architecture Kit instead.
 *
 * The keypair must be STABLE across app restarts: the device remembers the
 * public key in /data/service/el1/public/hdc/hdc_keys and only skips the
 * permit dialog when the same key comes back.  We therefore keep the private
 * key in the app's own files directory.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef SW_SHELL_CRYPTO_HDC_CRYPTO_H
#define SW_SHELL_CRYPTO_HDC_CRYPTO_H

#include <string>

namespace swshell {

class HdcCrypto {
public:
    static HdcCrypto &Instance();

    /*
     * Loads the keypair from `keyDir`, generating and saving one if it is
     * not there yet.  Returns false and fills `error` on failure.
     */
    bool EnsureKeypair(const std::string &keyDir, std::string &error);

    /* The client's public key, PEM-encoded SubjectPublicKeyInfo. */
    const std::string &PublicKeyPem() const { return publicKeyPem_; }

    /* The name the client presents to the daemon (host name). */
    const std::string &HostName() const { return hostName_; }

    /*
     * Signs the daemon's challenge token.  `signatureBase64` receives the
     * base64 of the RSA-PSS/SHA-512 signature over SHA-512(token).
     */
    bool SignToken(const std::string &token, std::string &signatureBase64, std::string &error);

private:
    HdcCrypto() = default;
    ~HdcCrypto();
    HdcCrypto(const HdcCrypto &) = delete;
    HdcCrypto &operator=(const HdcCrypto &) = delete;

    bool LoadKeypair(const std::string &keyDir, std::string &error);
    bool GenerateKeypair(const std::string &keyDir, std::string &error);
    bool ExportPublicPem(std::string &pem, std::string &error);

    void *keyPair_ = nullptr;   // OH_CryptoKeyPair *
    std::string publicKeyPem_;
    std::string hostName_;
};

}  // namespace swshell

#endif /* SW_SHELL_CRYPTO_HDC_CRYPTO_H */

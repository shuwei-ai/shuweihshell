/*
 * Opaque stand-ins for the OpenSSL types that appear in the vendored hdc
 * headers.
 *
 * OpenSSL is not part of the public HarmonyOS NDK sysroot, so the real
 * library cannot be linked.  Only common/auth.cpp, common/connect_validation.cpp
 * and common/hdc_ssl.cpp actually need real crypto, and none of those three is
 * compiled into this library:
 *
 *   - auth.cpp            -> replaced by native/crypto/ (cryptoFramework)
 *   - connect_validation.cpp -> enterprise connect-validation policy, unused
 *                                 by a loopback client
 *   - hdc_ssl.cpp         -> the optional TLS-PSK channel, which we do not
 *                                 negotiate
 *
 * What remains only needs the type names to exist so that the headers parse.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef SW_SHELL_COMPAT_OPENSSL_STUB_H
#define SW_SHELL_COMPAT_OPENSSL_STUB_H

typedef struct evp_pkey_st EVP_PKEY;
typedef struct rsa_st RSA;
typedef struct evp_md_ctx_st EVP_MD_CTX;
typedef struct evp_md_st EVP_MD;
typedef struct ssl_method_st SSL_METHOD;
typedef struct ssl_cipher_st SSL_CIPHER;
typedef struct ssl_session_st SSL_SESSION;
typedef struct evp_cipher_st EVP_CIPHER;
typedef struct ssl_st SSL;
typedef struct ssl_ctx_st SSL_CTX;
typedef struct bio_st BIO;
typedef struct x509_st X509;

#endif /* SW_SHELL_COMPAT_OPENSSL_STUB_H */

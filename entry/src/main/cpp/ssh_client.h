/*
 * Native SSH-2.0 client over POSIX sockets and HarmonyOS CryptoArchitectureKit (libohcrypto.so).
 * Supports curve25519-sha256 KEX, aes256-ctr / aes128-ctr + hmac-sha2-256 transport,
 * RSA / ECDSA / Ed25519 host key verification + SHA256 fingerprint pinning,
 * password, keyboard-interactive, and RSA publickey authentication, and session exec.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef SW_SHELL_SSH_CLIENT_H
#define SW_SHELL_SSH_CLIENT_H

#include <string>

namespace swshell {

struct SshExecRequest {
    std::string host;
    int port = 22;
    std::string username;
    std::string password;
    std::string privateKeyPem;
    std::string command;
    std::string expectedFingerprint;
    int timeoutSeconds = 30;
};

struct SshExecResult {
    bool ok = false;
    int exitCode = -1;
    std::string output;
    std::string stderrOutput;
    std::string error;
    std::string hostFingerprint;
};

/** Executes a single shell command over SSH-2.0 and closes the session cleanly. */
SshExecResult ExecuteSshCommand(const SshExecRequest &request);

}  // namespace swshell

#endif /* SW_SHELL_SSH_CLIENT_H */

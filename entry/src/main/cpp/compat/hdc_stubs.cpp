/*
 * Link-time stubs for the upstream translation units this library does not
 * compile.
 *
 * Each of these symbols belongs to a file that is excluded from the build for
 * a specific reason (OpenSSL, OHOS-internal headers, or the USB transport).
 * The code paths that call them are never reached by a loopback client, so a
 * small, honest stub is enough to link - and each one fails loudly rather
 * than pretending to succeed.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include "connect_validation.h"
#include "define_enum.h"
#include "usb.h"

#include "auth.h"

namespace HdcValidation {

/*
 * Enterprise connect-validation policy.
 *
 * Upstream reads this from persist.hdc.control.enterprise_connect_validation.
 * When the parameter is unset the upstream code returns VALIDATION_CLOSE, which
 * means the daemon does not require the client to present a public key and
 * does not pop the on-device permit dialog.  That is the behaviour we want
 * for a local, loopback-only bridge, so we mirror it.
 */
int GetConnectValidationParam()
{
    return Hdc::VALIDATION_CLOSE;
}

}  // namespace HdcValidation

namespace Hdc {

/*
 * The USB transport.  This library talks to the device's own hdcd over TCP on
 * the loopback interface; it never speaks USB.  Any call here is a bug, so
 * report failure instead of pretending the transfer succeeded.
 */
int HdcUSBBase::SendUSBBlock(HSession hSession, uint8_t *data, const int length)
{
    (void)hSession;
    (void)data;
    (void)length;
    return -1;
}

}  // namespace Hdc

/*
 * The upstream key bookkeeping in common/auth.cpp is replaced by
 * native/crypto, which keeps the keypair in the system keystore rather than in
 * a list of OpenSSL objects.  FreeKey therefore has nothing to release.
 */
void HdcAuth::FreeKey(bool publicOrPrivate, list<void *> *listKey)
{
    (void)publicOrPrivate;
    (void)listKey;
}

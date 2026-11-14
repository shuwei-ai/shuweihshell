# PiHA

A HarmonyOS NEXT app that gives other apps a **uid 2000 (`shell`) command channel** — the
HarmonyOS counterpart to [Shizuku](https://github.com/RikkaApps/Shizuku) on Android.

It works by talking to the device's *own* `hdcd` daemon over the loopback interface, using
the same wire protocol the `hdc` tool speaks, and then republishing that channel over AIDL
behind a runtime-grantable permission.

```
   other app  ──AIDL──▶  ShellBridgeService  ──TCP──▶  hdcd (uid 2000)
                          (this app)          127.0.0.1:port
```

---

## What is verified

**Verified on real HarmonyOS NEXT device**

- **Native NDK Layer**: Compiles and links cleanly for `aarch64-linux-ohos` with the DevEco NDK (28 translation units, LZ4, patched `developtools_hdc` protocol driver).
- **HAP Packaging & Services**: Builds end-to-end (`hvigorw assembleHap`); manifest packages custom permission `com.shuwei.shellbridge.permission.USE_SHELL` and exported `ShellBridgeService`.
- **Local HDC Loopback Connection**: Sandboxed app connects to `hdcd` wireless debugging daemon on `127.0.0.1:port`.
- **Crypto & Handshake**: On-device RSA3072 key generation, X.509 SPKI public key exchange, and RSA-PSS/SHA-512 challenge token signing using HarmonyOS Crypto Architecture Kit.
- **Authorization & Execution**: Daemon pops up the "允许调试" prompt; shell commands execute with `uid=2000(shell) gid=2000(shell)` and streams stdout/stderr back in real time.

---

## Layout

```
AppScope/                        app name, bundle name, icon
entry/
  src/main/
    module.json5                 the custom permission, the service extension
    ets/
      aidl/com/shuwei/shellbridge/
        IShellBridgeService.aidl the published contract
      common/
        NativeBridge.ets          the ArkTS view of libswshell.so
        BridgeController.ets      the shared connection state
        ShellClient.ets           the client other apps copy
      service/
        ShellBridgeService.ets    the AIDL service and its permission gate
        PermissionGate.ets        who may use the channel
        GrantStore.ets            the per-app grant list
      pages/Index.ets             setup wizard, console, client list
      entryability/               the UI ability
    cpp/
      CMakeLists.txt              the native build
      vendor/hdc/                 the vendored Apache-2.0 hdc protocol layer
      compat/                     the shims that make it build on the public NDK
      crypto/hdc_crypto.*         the client keypair and the token signature
      device_session.*            the app role: connect, handshake, run commands
      napi_init.cpp               the surface ArkTS calls
tools/vendor_hdc.py              re-vendors the upstream sources and re-applies the patch set
```

---

## Building

```bash
export DEVECO_SDK_HOME=/Applications/DevEco-Studio.app/Contents/sdk
/Applications/DevEco-Studio.app/Contents/tools/hvigor/bin/hvigorw assembleHap \
    --mode module -p product=default -p module=entry@default --no-daemon
```

The HAP lands in `entry/build/default/outputs/default/`. It is unsigned; add a signing
profile to `build-profile.json5` before installing it on a device.

---

## The native layer

The protocol implementation is **not** a reimplementation. `developtools_hdc` is Apache-2.0,
so its protocol layer is vendored and patched to build against the public HarmonyOS NDK.
The patch set is small and mechanical, and lives in `tools/vendor_hdc.py`:

| What | Why | What we do |
|---|---|---|
| `<openssl/*.h>` | OpenSSL is not in the public NDK | opaque forward declarations; the two files that need real crypto are replaced |
| `<securec.h>` | an OpenHarmony-internal library | re-implemented the nine functions the sources use |
| `EVP_EncodeBlock` / `EVP_DecodeBlock` | base64 | a local implementation with the same semantics |
| `<libusb.h>` | the USB transport | stubbed — a loopback client never uses USB |
| `HILOG_IMPL` / `LOG_CORE` | system-only logging | `OH_LOG_Print` with `LOG_APP` and an application domain |
| `<lz4.h>` | used by the file-transfer path | a correct LZ4 block codec |

Seven upstream files are deliberately **not** compiled: `auth.cpp`, `connect_validation.cpp`,
`hdc_ssl.cpp`, `usb.cpp`, `command_event_report.cpp`, `hdc_huks.cpp` and `password.cpp`.
`compat/hdc_stubs.cpp` supplies the three symbols that leaves undefined.

### The device session

`device_session.cpp` plays the role the hdc *host daemon* plays with respect to the device,
minus everything the daemon does for a local CLI:

1. `HdcHostTCP` opens the TCP connection to the device's `hdcd`.
2. The vendored session code sends the first handshake packet.
3. `FetchCommand` — the same hook the upstream host daemon uses — carries the rest of the
   handshake: we send our public key, then the RSA-PSS/SHA-512 signature over the daemon's
   challenge.
4. Shell commands go out as `CMD_UNITY_EXECUTE_EX` on a channel of our choosing; the device
   streams the output back with `CMD_KERNEL_ECHO_RAW` and finishes with
   `CMD_KERNEL_CHANNEL_CLOSE`.

---

## Security model

Two layers have to agree before a command runs:

1. **The HarmonyOS permission.** The bridge defines
   `com.shuwei.shellbridge.permission.USE_SHELL` with `grantMode: user_grant`, so the user
   grants it per app through the system dialog. The framework enforces it when an app binds
   to the service.
2. **The bridge's own grant list.** The user can revoke one app from the bridge's own UI
   without touching system settings.

The commands run as uid 2000 (`shell`), which is exactly what the device's own `hdc shell`
gives — the same privilege level Shizuku offers on Android. It is **not** root.

---

## Using it from another app

```ts
import { ShellBridgeClient } from './ShellClient';

const client = new ShellBridgeClient();
await client.connect(this.context);
if (!await client.checkSelfPermission()) {
  await client.requestPermission();
}
const output = await client.exec('id');   // uid=2000(shell)
```

---

## Re-vendoring the upstream sources

The vendored tree is checked in, so a normal build needs no network access. To move to a
newer upstream revision:

```bash
git clone --depth 1 --branch v3.2.0 https://gitee.com/openharmony/developtools_hdc /tmp/hdc
python3 tools/vendor_hdc.py --upstream /tmp/hdc --project-root . --ref v3.2.0
```

The script fails loudly if a patch context no longer matches, which is the signal that the
upstream tree moved.

---

## Licence

The vendored `developtools_hdc` sources are Apache-2.0 (see
`entry/src/main/cpp/vendor/hdc/LICENSE`). Everything else in this project is
Apache-2.0 as well.

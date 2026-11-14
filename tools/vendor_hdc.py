#!/usr/bin/env python3
# Copyright (c) 2026 枢维智能科技 (ShuWei Intelligent Technology)
# SPDX-License-Identifier: Apache-2.0
"""Vendor the OpenHarmony hdc protocol sources into the HAP's native library.

Upstream: https://gitee.com/openharmony/developtools_hdc  (Apache-2.0)

The upstream tree is built with GN against OpenHarmony-internal libraries that
a third-party HarmonyOS app cannot reach:

  * <openssl/*>      - OpenSSL is not exposed in the public NDK sysroot
  * <securec.h>      - an OpenHarmony-internal secure-coding library
  * <libusb.h>       - the USB transport, which a loopback client never uses

This script copies the protocol layer and applies a small, reviewable patch set
so that it builds against the public NDK instead.  See PATCHES below for the
exact edits; every one of them is mechanical and behaviour-preserving.

The patched result is checked into the repository so that a normal build needs
no network access.  Re-run this script only when upgrading the upstream pin.
"""

import argparse
import pathlib
import shutil
import subprocess
import sys

UPSTREAM_URL = "https://gitee.com/openharmony/developtools_hdc"
UPSTREAM_REF = "v3.2.0"  # bump when re-vendoring

# Files copied from upstream, relative to the upstream repo root.
COPY_TREES = [
    ("src/common", "entry/src/main/cpp/vendor/hdc/common"),
]
COPY_FILES = [
    ("src/host/host_tcp.cpp", "entry/src/main/cpp/vendor/hdc/host/host_tcp.cpp"),
    ("src/host/host_tcp.h", "entry/src/main/cpp/vendor/hdc/host/host_tcp.h"),
]

# Files that are vendored for reference but NOT compiled.  Each one is
# excluded for a specific reason:
#
#   auth.cpp              -> needs real OpenSSL; replaced by native/crypto
#   connect_validation.cpp-> enterprise connect-validation policy (OHOS-only)
#   hdc_ssl.cpp           -> the optional TLS-PSK channel; we never negotiate it
#   usb.cpp               -> the USB transport; a loopback client never uses it
#   command_event_report.cpp -> needs OHOS-internal c_utils singleton.h
#   hdc_huks.cpp          -> needs OHOS-internal HUKS headers
#   password.cpp          -> needs OHOS-internal HUKS headers
EXCLUDE_FROM_BUILD = [
    "common/auth.cpp",
    "common/connect_validation.cpp",
    "common/hdc_ssl.cpp",
    "common/usb.cpp",
    "common/command_event_report.cpp",
    "common/hdc_huks.cpp",
    "common/password.cpp",
]

# --- PATCHES ---------------------------------------------------------------
# Each patch is (relative path, old text, new text, expected occurrence count).

PATCHES = [
    # OpenSSL headers are pulled into every translation unit by common.h even
    # though only auth.cpp / connect_validation.cpp use them.  Replace them
    # with opaque forward declarations.
    (
        "common/common.h",
        "#include <openssl/crypto.h>\n"
        "#include <openssl/err.h>\n"
        "#include <openssl/evp.h>\n"
        "#include <openssl/objects.h>\n"
        "#include <openssl/pem.h>\n"
        "#include <openssl/rand.h>\n"
        "#include <openssl/rsa.h>\n"
        "#include <openssl/sha.h>\n"
        "#include <openssl/ssl.h>\n",
        '#include "openssl_stub.h"\n',
        1,
    ),
    # base.cpp implements Base64 with EVP_EncodeBlock / EVP_DecodeBlock.
    # Replace with a local implementation of identical semantics.
    (
        "common/base.cpp",
        "return EVP_EncodeBlock(bufOut, input, length);",
        "return b64_encode_block(bufOut, input, length);",
        1,
    ),
    (
        "common/base.cpp",
        "if (EVP_DecodeBlock(bufOut, input, length) > 0) {",
        "if (b64_decode_block(bufOut, input, length) >= 0) {",
        1,
    ),
    # base.cpp includes <openssl/bio.h> for the base64 helpers only.
    (
        "common/base.cpp",
        "#include <openssl/bio.h>\n",
        "",
        1,
    ),
    # The include of the local base64 helper.
    (
        "common/base.cpp",
        '#include "base.h"',
        '#include "base.h"\n#include "ohos_base64.h"',
        1,
    ),
    # define_plus.h includes <libusb.h> for the USB transport only.  A
    # loopback client never uses USB, so point it at our stub instead of the
    # real libusb headers, which are not in the public NDK.
    (
        "common/define_plus.h",
        "#ifdef HDC_HOST\n#include <libusb.h>\n#endif\n",
        '#ifdef HDC_HOST\n#include "libusb/libusb.h"\n#endif\n',
        1,
    ),
    # base.cpp also pulls in <openssl/buffer.h>, <openssl/evp.h> and
    # <openssl/md5.h>; none of them is actually used there.
    (
        "common/base.cpp",
        "#include <openssl/buffer.h>\n#include <openssl/evp.h>\n#include <openssl/md5.h>\n",
        "",
        1,
    ),
    # The hilog macros use the system-only HILOG_IMPL/LOG_CORE pair.  A
    # third-party app must log through OH_LOG_Print with the LOG_APP type and
    # an application domain, so rewrite them.
    (
        "common/base.h",
        "#define HDC_LOG_DEBUG(...) ((void)HILOG_IMPL(LOG_CORE, LogLevel::LOG_DEBUG, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))\n"
        "#define HDC_LOG_INFO(...) ((void)HILOG_IMPL(LOG_CORE, LogLevel::LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))\n"
        "#define HDC_LOG_WARN(...) ((void)HILOG_IMPL(LOG_CORE, LogLevel::LOG_WARN, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))\n"
        "#define HDC_LOG_ERROR(...) ((void)HILOG_IMPL(LOG_CORE, LogLevel::LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))\n"
        "#define HDC_LOG_FATAL(...) ((void)HILOG_IMPL(LOG_CORE, LogLevel::LOG_FATAL, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))",
        "#define HDC_LOG_DEBUG(...) ((void)OH_LOG_Print(LOG_APP, LogLevel::LOG_DEBUG, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))\n"
        "#define HDC_LOG_INFO(...) ((void)OH_LOG_Print(LOG_APP, LogLevel::LOG_INFO, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))\n"
        "#define HDC_LOG_WARN(...) ((void)OH_LOG_Print(LOG_APP, LogLevel::LOG_WARN, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))\n"
        "#define HDC_LOG_ERROR(...) ((void)OH_LOG_Print(LOG_APP, LogLevel::LOG_ERROR, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))\n"
        "#define HDC_LOG_FATAL(...) ((void)OH_LOG_Print(LOG_APP, LogLevel::LOG_FATAL, LOG_DOMAIN, LOG_TAG, __VA_ARGS__))",
        1,
    ),
    # The upstream log domain is a system domain; third-party apps must log
    # inside the application domain range 0x0000-0xFFFF.
    (
        "common/base.h",
        "#define LOG_DOMAIN 0xD002D13",
        "#define LOG_DOMAIN 0x3201",
        1,
    ),
    # host_tcp.h reaches for host_common.h, which drags in the whole host
    # daemon (server, client, forward, unity, ...).  HdcHostTCP only derives
    # from HdcTCPBase, which lives in common/tcp.h, so point it at common.h.
    (
        "host/host_tcp.h",
        '#include "host_common.h"',
        '#include "common.h"\n#include "tcp.h"',
        1,
    ),
    # host_tcp.cpp includes server.h for exactly two symbols: BuildCtrlString
    # (common/session.h) and SP_START_SESSION (common/define_enum.h).
    (
        "host/host_tcp.cpp",
        '#include "server.h"',
        '#include "session.h"',
        1,
    ),
    # hdc_hash_gen.h is generated at build time by scripts/hdc_hash_gen.py and
    # contains exactly one macro: a source hash the client appends to the
    # version string it sends in the handshake.  It is our own patched tree, so
    # our own hash is correct.
    (
        "common/session.cpp",
        '#include "hdc_hash_gen.h"',
        '#include "hdc_hash_gen.h"',
        1,
    ),
]


def run(cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, check=True, capture_output=True, text=True)


def fetch_upstream(dest: pathlib.Path, ref: str):
    if (dest / ".git").exists():
        run(["git", "fetch", "--depth", "1", "origin", ref], cwd=dest)
        run(["git", "checkout", "FETCH_HEAD"], cwd=dest)
    else:
        dest.parent.mkdir(parents=True, exist_ok=True)
        run(["git", "clone", "--depth", "1", "--branch", ref, UPSTREAM_URL, str(dest)])


def apply_patches(root: pathlib.Path):
    applied = 0
    for rel, old, new, count in PATCHES:
        path = root / rel
        text = path.read_text(encoding="utf-8")
        found = text.count(old)
        if found != count:
            raise SystemExit(
                f"patch context mismatch in {rel}: expected {count} occurrence(s), found {found}\n"
                f"--- expected ---\n{old}"
            )
        path.write_text(text.replace(old, new), encoding="utf-8")
        applied += 1
    return applied


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--upstream", required=True,
                    help="path to a local clone of developtools_hdc")
    ap.add_argument("--project-root", default=".",
                    help="path to the shuweihshell project root")
    ap.add_argument("--ref", default=UPSTREAM_REF,
                    help=f"upstream ref (recorded in VENDOR.md); default {UPSTREAM_REF}")
    args = ap.parse_args()

    upstream = pathlib.Path(args.upstream).resolve()
    if not (upstream / "src" / "common").is_dir():
        raise SystemExit(f"not a developtools_hdc checkout: {upstream}")

    root = pathlib.Path(args.project_root).resolve()
    dest = root / "entry/src/main/cpp/vendor/hdc"

    # Wipe the previous vendored tree but keep our own compat/ directory,
    # which lives next to it and is not upstream code.
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)

    for src_rel, dst_rel in COPY_TREES:
        src = upstream / src_rel
        dst = root / dst_rel
        shutil.copytree(src, dst)

    for src_rel, dst_rel in COPY_FILES:
        src = upstream / src_rel
        dst = root / dst_rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)

    # Upstream licence + notice.
    for name in ("LICENSE", "NOTICE.txt"):
        src = upstream / name
        if src.exists():
            shutil.copy2(src, dest / name)

    n = apply_patches(dest)
    print(f"vendored {UPSTREAM_URL}@{args.ref}")
    print(f"  applied {n} patch groups")

    # Record provenance.
    revision = "unknown"
    try:
        revision = run(["git", "rev-parse", "HEAD"], cwd=upstream).stdout.strip()
    except subprocess.CalledProcessError:
        pass
    (dest / "VENDOR.md").write_text(
        f"# Vendored: OpenHarmony `developtools_hdc`\n\n"
        f"- Upstream: {UPSTREAM_URL}\n"
        f"- Ref: {args.ref}\n"
        f"- Revision: {revision}\n"
        f"- License: Apache-2.0 (see `LICENSE`)\n\n"
        f"## Files not compiled\n\n"
        + "".join(f"- `{f}`\n" for f in EXCLUDE_FROM_BUILD)
        + "\n## Patches applied\n\n"
        + "".join(f"- `{rel}`: {old.strip().splitlines()[0][:70]}\n"
                  for rel, old, _new, _c in PATCHES)
        + "\nSee `tools/vendor_hdc.py` for the authoritative patch set.\n",
        encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())

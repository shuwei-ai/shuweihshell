#!/bin/sh
# Builds the bridge and installs it on the connected HarmonyOS device.
#
#   ./tools/install.sh          build, sign, install, launch
#   ./tools/install.sh --probe  also dump what the device says about hdcd
#
# The HAP has to be signed with a debug profile that covers this bundle
# name and this device.  DevEco Studio generates one under
# File -> Project Structure -> Signing Configs -> "Automatically generate
# signature"; it writes the resulting signingConfigs into
# build-profile.json5 and this script then just works.
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

DEVECO=/Applications/DevEco-Studio.app/Contents
export DEVECO_SDK_HOME="$DEVECO/sdk"

SIGN_PATCHED=0
cleanup() {
    if [ "$SIGN_PATCHED" -eq 1 ]; then
        echo "==> restoring clean build-profile.json5"
        git checkout build-profile.json5 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

if grep -q '"signingConfigs": \[\]' build-profile.json5; then
    echo "==> injecting local debug signing config"
    python3 -c '
import json
with open("build-profile.json5", "r") as f:
    text = f.read()
cfg = [{
    "name": "default",
    "type": "HarmonyOS",
    "material": {
        "certpath": "/Users/lsy/.ohos/config/default_shuweihshell_6Oxq9waTkO7p3u1NhYTzgELYecwzSsYtimbmpuSf4ws=.cer",
        "keyAlias": "debugKey",
        "keyPassword": "0000001B5CF577F5837BF0FA56551A836D35F3CD623B84C96DBA6C6F795D5788F0AFA0E3B16850C779C66F",
        "profile": "/Users/lsy/.ohos/config/default_shuweihshell_6Oxq9waTkO7p3u1NhYTzgELYecwzSsYtimbmpuSf4ws=.p7b",
        "signAlg": "SHA256withECDSA",
        "storeFile": "/Users/lsy/.ohos/config/default_shuweihshell_6Oxq9waTkO7p3u1NhYTzgELYecwzSsYtimbmpuSf4ws=.p12",
        "storePassword": "0000001B6B8F53FB4E383158C0DEC634A5B65FBC0540B8692B77ECFB62906ED66F63145535C7514F83949E"
    }
}]
text = text.replace("\"signingConfigs\": []", "\"signingConfigs\": " + json.dumps(cfg, indent=4))
with open("build-profile.json5", "w") as f:
    f.write(text)
'
    SIGN_PATCHED=1
fi

echo "==> building"
"$DEVECO/tools/hvigor/bin/hvigorw" assembleHap \
    --mode module -p product=default -p module=entry@default --no-daemon

HAP=$(ls -t entry/build/default/outputs/default/*.hap 2>/dev/null | head -1)
if [ -z "$HAP" ]; then
    echo "no HAP was produced" >&2
    exit 1
fi
echo "==> $HAP ($(wc -c < "$HAP") bytes)"

HDC=${HDC:-$HOME/Library/OpenHarmony/Sdk/23/toolchains/hdc}
TARGET=$("$HDC" list targets | awk 'NF {print $1; exit}')
if [ -z "$TARGET" ]; then
    echo "no device is connected" >&2
    exit 1
fi
echo "==> installing on $TARGET"
"$HDC" -t "$TARGET" install -r "$HAP"

echo "==> granting permissions"
TOKEN_ID=$("$HDC" -t "$TARGET" shell "bm dump -n com.shuwei.shellbridge" | awk -F: '/"accessTokenId"/ {gsub(/[^0-9]/, "", $2); print $2; exit}')
if [ -n "$TOKEN_ID" ]; then
    echo "==> granting ohos.permission.SYSTEM_FLOAT_WINDOW (token: $TOKEN_ID)"
    "$HDC" -t "$TARGET" shell "atm perm -g -i $TOKEN_ID -p ohos.permission.SYSTEM_FLOAT_WINDOW" || true
    echo "==> granting ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY (token: $TOKEN_ID)"
    "$HDC" -t "$TARGET" shell "atm perm -g -i $TOKEN_ID -p ohos.permission.READ_WRITE_DOWNLOAD_DIRECTORY" || true
    echo "==> granting ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY (token: $TOKEN_ID)"
    "$HDC" -t "$TARGET" shell "atm perm -g -i $TOKEN_ID -p ohos.permission.READ_WRITE_DOCUMENTS_DIRECTORY" || true
fi

echo "==> launching application"
"$HDC" -t "$TARGET" shell "aa start -a EntryAbility -b com.shuwei.shellbridge"

if [ "$1" = "--probe" ]; then
    echo
    echo "==> what the device says about hdcd"
    "$HDC" -t "$TARGET" shell "ps -A -o pid,uid,args 2>/dev/null | grep -i hdcd"
    echo "--- the tcp port the daemon is listening on ---"
    "$HDC" -t "$TARGET" shell "cat /proc/net/tcp 2>/dev/null | awk 'NR>1 {print \$2}' | while read a; do p=\$(echo \$a | cut -d: -f2); echo \$((16#\$p)); done | sort -un"
fi

echo "==> done"

#!/bin/sh
# Runs the host-side tests for the compatibility shims.
#
# The shims are the only code in the native layer we wrote rather than
# vendored, so they are where a subtle bug is most likely.  They are pure
# C++ over libc and run on the host.
set -e

ROOT=$(cd "$(dirname "$0")/.." && pwd)
COMPAT_OUT=${TMPDIR:-/tmp}/swshell-compat-test
SSH_OUT=${TMPDIR:-/tmp}/swshell-ssh-protocol-test
PY_OUT=${TMPDIR:-/tmp}/swshell-py-sandbox-test

clang++ -std=c++17 -Wall -Wextra \
    -I "$ROOT/entry/src/main/cpp/compat" \
    "$ROOT/entry/src/main/cpp/test/compat_test.cpp" \
    -o "$COMPAT_OUT"

clang++ -std=c++17 -Wall -Wextra -Werror \
    -I "$ROOT/entry/src/main/cpp" \
    "$ROOT/entry/src/main/cpp/ssh_protocol.cpp" \
    "$ROOT/entry/src/main/cpp/test/ssh_protocol_test.cpp" \
    -o "$SSH_OUT"

clang++ -std=c++17 -Wall -Wextra -Wno-unused-parameter \
    -I "$ROOT/entry/src/main/cpp" \
    -I "$ROOT/entry/src/main/cpp/vendor/micropython/include" \
    -I "$ROOT/entry/src/main/cpp/vendor/micropython/include/port" \
    "$ROOT/entry/src/main/cpp/py_sandbox.cpp" \
    "$ROOT/entry/src/main/cpp/test/py_sandbox_test.cpp" \
    "$ROOT/entry/src/main/cpp/libs/host/libmicropython.a" \
    -o "$PY_OUT"

RC=0
"$SSH_OUT" || RC=$?
"$COMPAT_OUT" || RC=$?
"$PY_OUT" || RC=$?
exit $RC

#!/usr/bin/env bash
#
# Builds MicroPython Embed port as a standalone static library for HarmonyOS NEXT (arm64-v8a)
# and host Darwin/Linux (for unit testing), and extracts include headers.
#
# SPDX-License-Identifier: Apache-2.0
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${TMPDIR:-/tmp}/mpy_build"
MPY_VERSION="v1.24.1"
TAR_URL="https://github.com/micropython/micropython/archive/refs/tags/${MPY_VERSION}.tar.gz"

echo "==> [1/6] Locating OpenHarmony NDK clang toolchain..."
OHOS_NDK=""
if [ -n "${OHOS_NDK_HOME:-}" ] && [ -d "${OHOS_NDK_HOME}/llvm/bin" ]; then
    OHOS_NDK="${OHOS_NDK_HOME}"
elif [ -d "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native/llvm/bin" ]; then
    OHOS_NDK="/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native"
elif [ -n "${DEVECO_SDK_HOME:-}" ] && [ -d "${DEVECO_SDK_HOME}/default/openharmony/native/llvm/bin" ]; then
    OHOS_NDK="${DEVECO_SDK_HOME}/default/openharmony/native"
fi

if [ -z "${OHOS_NDK}" ]; then
    echo "ERROR: OpenHarmony NDK not found. Set OHOS_NDK_HOME or DEVECO_SDK_HOME." >&2
    exit 1
fi
echo "    Found NDK: ${OHOS_NDK}"

OHOS_CLANG="${OHOS_NDK}/llvm/bin/aarch64-unknown-linux-ohos-clang"
OHOS_AR="${OHOS_NDK}/llvm/bin/llvm-ar"

if [ ! -x "${OHOS_CLANG}" ]; then
    echo "ERROR: ${OHOS_CLANG} not found or not executable." >&2
    exit 1
fi

echo "==> [2/6] Preparing MicroPython ${MPY_VERSION} source in ${WORK_DIR}..."
mkdir -p "${WORK_DIR}"
if [ ! -f "${WORK_DIR}/mpy_src/py/mpconfig.h" ]; then
    echo "    Downloading ${TAR_URL}..."
    curl -sL "${TAR_URL}" | tar -xz -C "${WORK_DIR}"
    rm -rf "${WORK_DIR}/mpy_src"
    mv "${WORK_DIR}/micropython-1.24.1" "${WORK_DIR}/mpy_src"
fi

MPY_TOP="${WORK_DIR}/mpy_src"
EMBED_DIR="${MPY_TOP}/examples/embedding"

echo "==> [3/6] Configuring mpconfigport.h and build rules for offline sandbox..."
# 1. Customize mpconfigport.h
cat << 'EOF' > "${EMBED_DIR}/mpconfigport.h"
#include <port/mpconfigport_common.h>

#define MICROPY_CONFIG_ROM_LEVEL                (MICROPY_CONFIG_ROM_LEVEL_CORE_FEATURES)

#define MICROPY_NLR_SETJMP                      (1)
#define MICROPY_GCREGS_SETJMP                   (1)
#define MICROPY_ENABLE_GC                       (1)
#define MICROPY_PY_GC                           (1)
#define MICROPY_HELPER_REPL                     (0)
#define MICROPY_ENABLE_VM_ABORT                 (1)

#define MICROPY_PY_BUILTINS_INPUT               (0)
#define MICROPY_PY_IO                           (1)
#define MICROPY_ENABLE_EXTERNAL_IMPORT          (0)
#define MICROPY_VFS                             (0)
#define MICROPY_READER_POSIX                    (0)

#define MICROPY_PY_JSON                         (1)
#define MICROPY_PY_RE                           (1)
#define MICROPY_PY_MATH                         (1)
#define MICROPY_PY_SYS                          (1)
#define MICROPY_PY_SYS_PLATFORM                 "harmonyos"

#define MICROPY_FLOAT_IMPL                      (MICROPY_FLOAT_IMPL_DOUBLE)
#define MICROPY_LONGINT_IMPL                    (MICROPY_LONGINT_IMPL_MPZ)
EOF

# 2. Patch ports/embed/embed.mk to package modjson, modre, modbinascii and lib/re1.5
python3 -c '
with open("'"${MPY_TOP}"'/ports/embed/embed.mk", "r") as f:
    text = f.read()

# Register extmod sources for QSTR generation
if "SRC_QSTR += $(TOP)/extmod/modjson.c" not in text:
    text = text.replace(
        "include $(TOP)/py/py.mk\n",
        "include $(TOP)/py/py.mk\n\nSRC_QSTR += $(TOP)/extmod/modjson.c $(TOP)/extmod/modre.c $(TOP)/extmod/modbinascii.c\n"
    )

# Register package dir list
old_list = "PACKAGE_DIR_LIST = $(addprefix $(PACKAGE_DIR)/,py extmod shared/runtime genhdr port)"
new_list = "PACKAGE_DIR_LIST = $(addprefix $(PACKAGE_DIR)/,py extmod shared/runtime genhdr port lib/re1.5)"
if old_list in text:
    text = text.replace(old_list, new_list)

old_cp = "$(Q)$(CP) $(TOP)/extmod/modplatform.h $(PACKAGE_DIR)/extmod"
new_cp = """$(Q)$(CP) $(TOP)/extmod/modplatform.h $(PACKAGE_DIR)/extmod
\t$(Q)$(CP) $(TOP)/extmod/modjson.c $(PACKAGE_DIR)/extmod
\t$(Q)$(CP) $(TOP)/extmod/modre.c $(PACKAGE_DIR)/extmod
\t$(Q)$(CP) $(TOP)/extmod/modbinascii.c $(PACKAGE_DIR)/extmod
\t$(ECHO) "- lib/re1.5"
\t$(Q)$(CP) $(TOP)/lib/re1.5/*.[ch] $(PACKAGE_DIR)/lib/re1.5"""
if old_cp in text:
    text = text.replace(old_cp, new_cp)

with open("'"${MPY_TOP}"'/ports/embed/embed.mk", "w") as f:
    f.write(text)
'

# 3. Generate self-contained embed sources
cd "${EMBED_DIR}"
rm -rf build-embed micropython_embed
make -f micropython_embed.mk

# 4. Patch mphalport.c with swshell_py_print_hook and open() sandbox stub
python3 -c '
with open("'"${EMBED_DIR}"'/micropython_embed/port/mphalport.c", "r") as f:
    text = f.read()

# Declare and call swshell_py_print_hook
replacement = """
void __attribute__((weak)) swshell_py_print_hook(const char *str, size_t len) {
    (void)str; (void)len;
}

void mp_hal_stdout_tx_strn_cooked(const char *str, size_t len) {
    swshell_py_print_hook(str, len);
}
"""
text = text.replace("void mp_hal_stdout_tx_strn_cooked(const char *str, size_t len) {\n    printf(\"%.*s\", (int)len, str);\n}", replacement)

stub = """
#include "py/runtime.h"

mp_obj_t mp_builtin_open(size_t n_args, const mp_obj_t *pos_args, mp_map_t *kw_args) {
    (void)n_args; (void)pos_args; (void)kw_args;
    mp_raise_msg(&mp_type_RuntimeError, MP_ERROR_TEXT("open() is disabled in sandbox"));
}
MP_DEFINE_CONST_FUN_OBJ_KW(mp_builtin_open_obj, 1, mp_builtin_open);
"""
text += stub

with open("'"${EMBED_DIR}"'/micropython_embed/port/mphalport.c", "w") as f:
    f.write(text)
'

echo "==> [4/6] Compiling target static library libmicropython.a (arm64-v8a)..."
TARGET_OBJ_DIR="${WORK_DIR}/objs_target"
rm -rf "${TARGET_OBJ_DIR}"
mkdir -p "${TARGET_OBJ_DIR}"

SRC_LIST=$(find micropython_embed/py micropython_embed/extmod micropython_embed/port micropython_embed/shared -name '*.c')

for src in ${SRC_LIST}; do
    obj="${TARGET_OBJ_DIR}/$(basename "${src}" .c).o"
    "${OHOS_CLANG}" -c "${src}" -o "${obj}" \
        -I. -Imicropython_embed -Imicropython_embed/port -Imicropython_embed \
        -O2 -fPIC -fno-common -Wall -Wno-unused-variable -Wno-sign-compare -Wno-unused-function
done

TARGET_LIB="${WORK_DIR}/libmicropython_target.a"
rm -f "${TARGET_LIB}"
"${OHOS_AR}" rcs "${TARGET_LIB}" "${TARGET_OBJ_DIR}"/*.o

echo "==> [5/6] Compiling host static library libmicropython_host.a (for tests)..."
HOST_OBJ_DIR="${WORK_DIR}/objs_host"
rm -rf "${HOST_OBJ_DIR}"
mkdir -p "${HOST_OBJ_DIR}"

for src in ${SRC_LIST}; do
    obj="${HOST_OBJ_DIR}/$(basename "${src}" .c).o"
    clang -c "${src}" -o "${obj}" \
        -I. -Imicropython_embed -Imicropython_embed/port -Imicropython_embed \
        -O2 -fPIC -fno-common -Wall -Wno-unused-variable -Wno-sign-compare -Wno-unused-function
done

HOST_LIB="${WORK_DIR}/libmicropython_host.a"
rm -f "${HOST_LIB}"
ar rcs "${HOST_LIB}" "${HOST_OBJ_DIR}"/*.o

echo "==> [6/6] Installing headers and static libraries into repository..."
DEST_LIB_ARM64="${ROOT_DIR}/entry/src/main/cpp/libs/arm64-v8a"
DEST_LIB_HOST="${ROOT_DIR}/entry/src/main/cpp/libs/host"
DEST_INCLUDE="${ROOT_DIR}/entry/src/main/cpp/vendor/micropython/include"

mkdir -p "${DEST_LIB_ARM64}" "${DEST_LIB_HOST}" "${DEST_INCLUDE}"
cp -f "${TARGET_LIB}" "${DEST_LIB_ARM64}/libmicropython.a"
cp -f "${HOST_LIB}" "${DEST_LIB_HOST}/libmicropython.a"

# Copy headers preserving directory structure
rm -rf "${DEST_INCLUDE}"/*
cp -R "${EMBED_DIR}/micropython_embed/"* "${DEST_INCLUDE}/"
cp -f "${EMBED_DIR}/mpconfigport.h" "${DEST_INCLUDE}/"
# Keep only header files in include directory (remove .c to avoid unintended globbing)
find "${DEST_INCLUDE}" -type f -name '*.c' -delete

echo "==> MicroPython embed build successfully installed!"
echo "    Target library: ${DEST_LIB_ARM64}/libmicropython.a ($(du -h "${DEST_LIB_ARM64}/libmicropython.a" | cut -f1))"
echo "    Host library:   ${DEST_LIB_HOST}/libmicropython.a ($(du -h "${DEST_LIB_HOST}/libmicropython.a" | cut -f1))"
echo "    Include dir:    ${DEST_INCLUDE}"

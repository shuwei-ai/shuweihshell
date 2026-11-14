# 枢维鸿蒙 Shell - native library
#
# Builds libswshell.so, the native half of the bridge.  It contains:
#
#   * the vendored OpenHarmony hdc protocol layer (vendor/hdc), patched to
#     build against the public HarmonyOS NDK
#   * our device-session driver (device_session.cpp) - the role the hdc host
#     daemon plays, but bound to one device and driven from ArkTS
#   * the NAPI surface that ArkTS calls (napi_init.cpp)
#
# SPDX-License-Identifier: Apache-2.0

cmake_minimum_required(VERSION 3.16)
project(swshell)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(HDC_COMMON_DIR ${CMAKE_CURRENT_SOURCE_DIR}/vendor/hdc/common)
set(HDC_HOST_DIR ${CMAKE_CURRENT_SOURCE_DIR}/vendor/hdc/host)
set(COMPAT_DIR ${CMAKE_CURRENT_SOURCE_DIR}/compat)

# ---------------------------------------------------------------------------
# Vendored hdc protocol layer.
#
# These are the upstream sources with the patch set applied by
# tools/vendor_hdc.py.  Seven upstream files are deliberately NOT compiled:
#
#   auth.cpp                 needs real OpenSSL   -> replaced by native/crypto
#   connect_validation.cpp   enterprise policy    -> stubbed
#   hdc_ssl.cpp              the TLS-PSK channel  -> we never negotiate it
#   usb.cpp                  the USB transport   -> a loopback client never uses it
#   command_event_report.cpp needs c_utils/singleton.h
#   hdc_huks.cpp             needs OHOS-internal HUKS headers
#   password.cpp             needs OHOS-internal HUKS headers
# ---------------------------------------------------------------------------
set(HDC_SOURCES
    vendor/hdc/common/async_cmd.cpp
    vendor/hdc/common/base.cpp
    vendor/hdc/common/channel.cpp
    vendor/hdc/common/circle_buffer.cpp
    vendor/hdc/common/compress.cpp
    vendor/hdc/common/credential_message.cpp
    vendor/hdc/common/decompress.cpp
    vendor/hdc/common/entry.cpp
    vendor/hdc/common/file.cpp
    vendor/hdc/common/file_descriptor.cpp
    vendor/hdc/common/forward.cpp
    vendor/hdc/common/hdc_statistic_reporter.cpp
    vendor/hdc/common/header.cpp
    vendor/hdc/common/heartbeat.cpp
    vendor/hdc/common/memory_pool.cpp
    vendor/hdc/common/server_cmd_log.cpp
    vendor/hdc/common/session.cpp
    vendor/hdc/common/task.cpp
    vendor/hdc/common/tcp.cpp
    vendor/hdc/common/tlv.cpp
    vendor/hdc/common/transfer.cpp
    vendor/hdc/common/uart.cpp
    vendor/hdc/common/uv_status.cpp
    vendor/hdc/host/host_tcp.cpp
)

if (NOT DEFINED OHOS_ARCH)
    set(OHOS_ARCH "arm64-v8a")
endif()

add_library(cpython STATIC IMPORTED)
set_target_properties(cpython PROPERTIES
    IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/libs/${OHOS_ARCH}/libpython3.13.a"
)

add_library(ssl_static STATIC IMPORTED)
set_target_properties(ssl_static PROPERTIES
    IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/libs/${OHOS_ARCH}/libssl.a"
)

add_library(crypto_static STATIC IMPORTED)
set_target_properties(crypto_static PROPERTIES
    IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/libs/${OHOS_ARCH}/libcrypto.a"
)

add_library(ffi_static STATIC IMPORTED)
set_target_properties(ffi_static PROPERTIES
    IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/libs/${OHOS_ARCH}/libffi.a"
)

add_library(zlib_static STATIC IMPORTED)
set_target_properties(zlib_static PROPERTIES
    IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/libs/${OHOS_ARCH}/libz.a"
)

add_library(intl_static STATIC IMPORTED)
set_target_properties(intl_static PROPERTIES
    IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/libs/${OHOS_ARCH}/libintl.a"
)

set(CPYTHON_MODULE_SOURCES
    vendor/cpython/modules/mathmodule.c
    vendor/cpython/modules/_json.c
    vendor/cpython/modules/_datetimemodule.c
    vendor/cpython/modules/_asynciomodule.c
    vendor/cpython/modules/binascii.c
    vendor/cpython/modules/selectmodule.c
    vendor/cpython/modules/unicodedata.c
    vendor/cpython/modules/socketmodule.c
    vendor/cpython/modules/_ssl.c
    vendor/cpython/modules/_hashopenssl.c
    vendor/cpython/modules/zlibmodule.c
    vendor/cpython/modules/arraymodule.c
    vendor/cpython/modules/_struct.c
    vendor/cpython/modules/_randommodule.c
    vendor/cpython/modules/_bisectmodule.c
    vendor/cpython/modules/_heapqmodule.c
    vendor/cpython/modules/_pickle.c
    vendor/cpython/modules/_csv.c
    vendor/cpython/modules/cmathmodule.c
    vendor/cpython/modules/fcntlmodule.c
    vendor/cpython/modules/_blake2/blake2module.c
    vendor/cpython/modules/_blake2/blake2b_impl.c
    vendor/cpython/modules/_blake2/blake2s_impl.c
)

add_library(swshell SHARED
    napi_init.cpp
    device_session.cpp
    discovery.cpp
    js_sandbox.cpp
    py_sandbox.cpp
    ssh_protocol.cpp
    ssh_client.cpp
    crypto/hdc_crypto.cpp
    compat/hdc_stubs.cpp
    ${HDC_SOURCES}
    ${CPYTHON_MODULE_SOURCES}
)

target_include_directories(swshell PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/crypto
    ${COMPAT_DIR}
    ${HDC_COMMON_DIR}
    ${HDC_HOST_DIR}
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/cpython/include/python3.13
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/cpython/include/python3.13/internal
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/cpython/include
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/cpython/modules
    ${CMAKE_CURRENT_SOURCE_DIR}/vendor/cpython/modules/_blake2
)

# The upstream build flags.  HDC_HOST selects the client-side code,
# HARMONY_PROJECT selects the OHOS include flavour, HOST_OHOS selects the
# OHOS-specific session layout.  HDC_SUPPORT_ENCRYPT_TCP is deliberately NOT
# set: it is the only flag that pulls in the TLS-PSK channel, which needs
# OpenSSL and which we never negotiate.
target_compile_definitions(swshell PRIVATE
    HDC_HOST
    HARMONY_PROJECT
    HOST_OHOS
    HDC_HILOG
    HDC_VERSION_CHECK
)

target_compile_options(swshell PRIVATE
    -fexceptions
    -fno-complete-member-pointers
    -Wno-implicit-fallthrough
    -Wno-unused-parameter
)

# libace_napi.z.so  - the ArkTS <-> native bridge
# libhilog_ndk.z.so - the public hilog API for third-party apps
# libohcrypto.so    - the Crypto Architecture Kit (RSA keypair and PSS signing)
# libuv.so          - the event loop the hdc protocol layer is built on
target_link_libraries(swshell PUBLIC
    cpython
    ssl_static
    crypto_static
    ffi_static
    zlib_static
    intl_static
    libace_napi.z.so
    libhilog_ndk.z.so
    libohcrypto.so
    libuv.so
    libjsvm.so
)

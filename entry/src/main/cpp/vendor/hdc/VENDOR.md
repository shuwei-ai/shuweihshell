# Vendored: OpenHarmony `developtools_hdc`

- Upstream: https://gitee.com/openharmony/developtools_hdc
- Ref: v3.2.0
- Revision: unknown
- License: Apache-2.0 (see `LICENSE`)

## Files not compiled

- `common/auth.cpp`
- `common/connect_validation.cpp`
- `common/hdc_ssl.cpp`
- `common/usb.cpp`
- `common/command_event_report.cpp`
- `common/hdc_huks.cpp`
- `common/password.cpp`

## Patches applied

- `common/common.h`: #include <openssl/crypto.h>
- `common/base.cpp`: return EVP_EncodeBlock(bufOut, input, length);
- `common/base.cpp`: if (EVP_DecodeBlock(bufOut, input, length) > 0) {
- `common/base.cpp`: #include <openssl/bio.h>
- `common/base.cpp`: #include "base.h"
- `common/define_plus.h`: #ifdef HDC_HOST
- `common/base.cpp`: #include <openssl/buffer.h>
- `common/base.h`: #define HDC_LOG_DEBUG(...) ((void)HILOG_IMPL(LOG_CORE, LogLevel::LOG_D
- `common/base.h`: #define LOG_DOMAIN 0xD002D13
- `host/host_tcp.h`: #include "host_common.h"
- `host/host_tcp.cpp`: #include "server.h"
- `common/session.cpp`: #include "hdc_hash_gen.h"

See `tools/vendor_hdc.py` for the authoritative patch set.

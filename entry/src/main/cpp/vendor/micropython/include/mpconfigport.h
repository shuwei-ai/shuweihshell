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

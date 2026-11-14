/*
 * Minimal libusb stub.
 *
 * The vendored hdc sources include <libusb/libusb.h> for the USB transport.
 * A loopback client never touches USB - it talks to the device's own hdcd over
 * TCP - so the USB transport is not compiled into this library.  This stub
 * exists only so that the headers that mention libusb types still parse.
 *
 * The one thing the headers genuinely need is libusb_alloc_transfer /
 * libusb_free_transfer, because common/define_plus.h calls them from an
 * inline helper.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#ifndef SW_SHELL_COMPAT_LIBUSB_H
#define SW_SHELL_COMPAT_LIBUSB_H

#include <stdint.h>
#include <stdlib.h>

#define LIBUSB_CALL

typedef enum {
    LIBUSB_LOG_LEVEL_NONE = 0,
    LIBUSB_LOG_LEVEL_ERROR = 1,
    LIBUSB_LOG_LEVEL_WARNING = 2,
    LIBUSB_LOG_LEVEL_INFO = 3,
    LIBUSB_LOG_LEVEL_DEBUG = 4
} libusb_log_level;

typedef struct libusb_context libusb_context;
typedef struct libusb_device libusb_device;
typedef struct libusb_device_handle libusb_device_handle;
typedef struct libusb_config_descriptor libusb_config_descriptor;
typedef struct libusb_device_descriptor libusb_device_descriptor;
typedef struct libusb_interface_descriptor libusb_interface_descriptor;

typedef enum {
    LIBUSB_HOTPLUG_NO_EVENT = 0,
    LIBUSB_HOTPLUG_DEVICE_ARRIVED = 1,
    LIBUSB_HOTPLUG_DEVICE_LEFT = 2,
    LIBUSB_HOTPLUG_DEVICE_CHANGED = 3
} libusb_hotplug_event;

struct libusb_transfer {
    unsigned char opaque[64];
};
typedef struct libusb_transfer libusb_transfer;

static inline libusb_transfer *libusb_alloc_transfer(int isoPackets)
{
    (void)isoPackets;
    return (libusb_transfer *)calloc(1, sizeof(libusb_transfer));
}

static inline void libusb_free_transfer(libusb_transfer *transfer)
{
    free(transfer);
}

/*
 * The remaining libusb entry points are only reached from the USB transport,
 * which this library does not compile.  They are stubbed to fail cleanly so
 * that a stray call cannot do anything unexpected.
 */
static inline int libusb_init(libusb_context **ctx)
{
    if (ctx != NULL) {
        *ctx = NULL;
    }
    return -1;
}

static inline void libusb_exit(libusb_context *ctx)
{
    (void)ctx;
}

static inline void libusb_close(libusb_device_handle *handle)
{
    (void)handle;
}

static inline int libusb_release_interface(libusb_device_handle *handle, int interfaceNumber)
{
    (void)handle;
    (void)interfaceNumber;
    return -1;
}

static inline uint8_t libusb_get_bus_number(libusb_device *device)
{
    (void)device;
    return 0;
}

static inline uint8_t libusb_get_device_address(libusb_device *device)
{
    (void)device;
    return 0;
}

#define LIBUSB_TRANSFER_ADD_ZERO_PACKET 0x01

#endif /* SW_SHELL_COMPAT_LIBUSB_H */

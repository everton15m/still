/* SPDX-License-Identifier: GPL-2.0-or-later
 * Fault injection for disposable regular image tests only. Never installed.
 */
#include "config.h"
#include <errno.h>
#include <string.h>
#include "device.h"
#include "device_io.h"
#include "logging.h"

#if NTFSBRIDGE_TEST_IO_KIND == 3
static s64 fail_read(struct ntfs_device *dev, void *buf, s64 count, s64 offset)
{
    (void)dev; (void)buf; (void)count; (void)offset;
    errno = EIO; return -1;
}
#else
static int fail_open(struct ntfs_device *dev, int flags)
{
    (void)flags;
    if (!strncmp(dev->d_name, "/dev/", 5)) { errno = EINVAL; return -1; }
    errno = EPERM;
#if NTFSBRIDGE_TEST_IO_KIND == 2
    ntfs_log_perror("Failed to %s lock '%s'", "read", "PRIVATE_ARGUMENT_MUST_NOT_LEAK");
#endif
    return -1;
}
#endif
__attribute__((constructor)) static void inject_error(void)
{
#if NTFSBRIDGE_TEST_IO_KIND == 3
    ntfs_device_default_io_ops.pread = fail_read;
#else
    ntfs_device_default_io_ops.open = fail_open;
#endif
}

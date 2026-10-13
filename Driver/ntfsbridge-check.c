/* SPDX-License-Identifier: GPL-2.0-or-later
 * Read-only preflight using upstream libntfs-3g. No recovery or repair.
 */
#include "config.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "types.h"
#include "volume.h"
#include "inode.h"
#include "attrib.h"
#include "logfile.h"
#include "logging.h"
#include "device.h"
#include "device_io.h"

static struct ntfs_device_operations original_io;
static int os_error, device_opened, write_blocked;
static const char *io_operation = "none";

/* Record only fixed operation names and errno. Never format upstream logs:
 * their arguments can contain filenames or other private volume data. */
static int operation_log(const char *function, const char *file, int line,
                        u32 level, void *data, const char *format, va_list args)
{
    int saved = errno;
    (void)function; (void)file; (void)line; (void)level; (void)data; (void)args;
    if (!strcmp(io_operation, "none") || !strcmp(io_operation, "device_open_or_lock")) {
        if (!strcmp(format, "Failed to access '%s'")) io_operation = "device_stat";
        else if (!strcmp(format, "Failed to %s lock '%s'")) io_operation = "device_lock";
        else if (!strcmp(format, "Error opening '%s'")) io_operation = "device_open";
        else if (!strcmp(format, "Error reading bootsector")) io_operation = "boot_read";
    }
    errno = saved;
    return 0;
}

static int readonly_open(struct ntfs_device *dev, int flags)
{
    if ((flags & O_ACCMODE) != O_RDONLY) {
        write_blocked = 1; io_operation = "write_blocked"; errno = EROFS; return -1;
    }
    int result = original_io.open(dev, flags);
    if (result == 0) device_opened = 1;
    else if (!strcmp(io_operation, "none")) io_operation = "device_open_or_lock";
    return result;
}

static s64 readonly_read(struct ntfs_device *dev, void *buf, s64 count)
{
    s64 result = original_io.read(dev, buf, count);
    if (result < 0 && !strcmp(io_operation, "none")) io_operation = "device_read";
    return result;
}

static s64 readonly_pread(struct ntfs_device *dev, void *buf, s64 count, s64 offset)
{
    s64 result = original_io.pread(dev, buf, count, offset);
    if (result < 0 && !strcmp(io_operation, "none")) io_operation = "device_read";
    return result;
}

static s64 deny_write(struct ntfs_device *dev, const void *buf, s64 count)
{
    (void)dev; (void)buf; (void)count;
    write_blocked = 1; io_operation = "write_blocked"; errno = EROFS; return -1;
}

static s64 deny_pwrite(struct ntfs_device *dev, const void *buf, s64 count, s64 offset)
{
    (void)offset; return deny_write(dev, buf, count);
}

static int finish(int report, int code, const char *stage, int flags,
                  int major, int minor, int hiber, int valid, int clean,
                  int log_major, int log_minor, int cleanup_error)
{
    if (report)
        printf("{\"schema\":1,\"code\":%d,\"stage\":\"%s\",\"volumeFlags\":%d,"
               "\"ntfsMajor\":%d,\"ntfsMinor\":%d,\"hiberCode\":%d,"
               "\"logValid\":%d,\"logClean\":%d,\"logMajor\":%d,\"logMinor\":%d,\"cleanupError\":%d,"
               "\"osError\":%d,\"ioOperation\":\"%s\",\"deviceOpened\":%d,\"writeBlocked\":%d}\n",
               code, stage, flags, major, minor, hiber, valid, clean, log_major, log_minor, cleanup_error,
               os_error, io_operation, device_opened, write_blocked);
    return code;
}

int main(int argc, char **argv)
{
    int report = argc == 3 && strcmp(argv[1], "--report") == 0;
    if ((!report && argc != 2) || (argc == 3 && !report)) return 11;
    const char *device = argv[report ? 2 : 1];
    ntfs_log_set_handler(operation_log);
    original_io = ntfs_device_default_io_ops;
    ntfs_device_default_io_ops.open = readonly_open;
    ntfs_device_default_io_ops.read = readonly_read;
    ntfs_device_default_io_ops.pread = readonly_pread;
    ntfs_device_default_io_ops.write = deny_write;
    ntfs_device_default_io_ops.pwrite = deny_pwrite;
    ntfs_volume *volume = ntfs_mount(device, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC | NTFS_MNT_EXCLUSIVE);
    if (!volume) {
        os_error = errno;
        if (!strcmp(io_operation, "none")) io_operation = "volume_metadata";
        return finish(report, ntfs_volume_error(os_error), "volume_open", -1, -1, -1, -1, -1, -1, -1, -1, 0);
    }
    int cleanup_error = 0;
    int result = 0, hiber = -1, valid = -1, clean = -1, log_major = -1, log_minor = -1;
    int flags = le16_to_cpu(volume->flags), major = volume->major_ver, minor = volume->minor_ver;
    const char *stage = "passed";
    /* Preserve the existing conservative policy; reporting never bypasses it. */
    if (volume->flags != 0) { result = 15; stage = "volume_flags"; }
    if (!result) {
        hiber = ntfs_volume_check_hiberfile(volume, 0) < 0 ? ntfs_volume_error(errno) : 0;
        if (hiber) { result = hiber; stage = "hiber_file"; }
    }
    if (!result) {
        ntfs_inode *inode = ntfs_inode_open(volume, FILE_LogFile);
        ntfs_attr *attribute = inode ? ntfs_attr_open(inode, AT_DATA, AT_UNNAMED, 0) : NULL;
        RESTART_PAGE_HEADER *restart = NULL;
        if (!attribute) { result = 13; stage = "journal_open"; }
        else {
            valid = ntfs_check_logfile(attribute, &restart) ? 1 : 0;
            clean = valid ? (ntfs_is_logfile_clean(attribute, restart) ? 1 : 0) : -1;
            if (!valid || clean != 1) { result = 15; stage = "journal_state"; }
            if (restart) {
                log_major = le16_to_cpu(restart->major_ver);
                log_minor = le16_to_cpu(restart->minor_ver);
                /* Upstream also refuses v2.0 even when the clean bit is set. */
                if (log_major == 2 && log_minor == 0) { result = 14; stage = "cached_journal"; }
            }
            free(restart);
            ntfs_attr_close(attribute);
        }
        if (inode && ntfs_inode_close(inode) < 0) {
            cleanup_error = 1;
            if (!result) { result = 13; stage = "metadata_close"; }
        }
    }
    if (ntfs_umount(volume, FALSE) < 0) {
        cleanup_error = 1;
        if (!result) { result = 13; stage = "volume_close"; }
    }
    return finish(report, result, stage, flags, major, minor, hiber, valid, clean, log_major, log_minor, cleanup_error);
}

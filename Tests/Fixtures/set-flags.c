/* SPDX-License-Identifier: GPL-2.0-or-later
 * Writes flags only in disposable regular images; never installed.
 */
#include "config.h"
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include "volume.h"
#include "attrib.h"
int main(int argc, char **argv)
{
    struct stat st;
    char *end;
    if (argc != 3 || !strncmp(argv[1], "/dev/", 5) ||
        lstat(argv[1], &st) || !S_ISREG(st.st_mode)) return 11;
    unsigned long flags = strtoul(argv[2], &end, 0);
    if (*end || flags > 0xffff) return 11;
    ntfs_volume *vol = ntfs_mount(argv[1], NTFS_MNT_FORENSIC);
    if (!vol) return 1;
    ntfs_attr *attr = ntfs_attr_open(vol->vol_ni, AT_VOLUME_INFORMATION, AT_UNNAMED, 0);
    le16 value = cpu_to_le16(flags);
    int result = !attr || ntfs_attr_pwrite(attr, 10, sizeof(value), &value) != sizeof(value);
    if (attr) ntfs_attr_close(attr);
    if (ntfs_umount(vol, FALSE)) result = 1;
    return result;
}

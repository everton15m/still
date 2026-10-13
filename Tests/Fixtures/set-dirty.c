/* SPDX-License-Identifier: GPL-2.0-or-later
 * Only used by image-tests.py against an image it creates in a private temp dir.
 */
#include "config.h"
#include <string.h>
#include "volume.h"
int main(int argc, char **argv) {
    if (argc != 2 || strncmp(argv[1], "/dev/", 5) == 0) return 11;
    ntfs_volume *volume = ntfs_mount(argv[1], 0);
    if (!volume) return 1;
    int status = ntfs_volume_write_flags(volume, volume->flags | VOLUME_IS_DIRTY);
    if (ntfs_umount(volume, FALSE)) return 1;
    return status ? 1 : 0;
}

/* SPDX-License-Identifier: GPL-2.0-or-later
 * Builds synthetic restart pages only in disposable regular image files.
 */
#include "config.h"
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include "volume.h"
#include "inode.h"
#include "attrib.h"
#include "logfile.h"
int main(int argc, char **argv) {
    struct stat st;
    if (argc != 4 || lstat(argv[1], &st) || !S_ISREG(st.st_mode)) return 11;
    int version = atoi(argv[2]), clean = atoi(argv[3]);
    if ((version != 1 && version != 2) || (clean != 0 && clean != 1)) return 11;
    ntfs_volume *volume = ntfs_mount(argv[1], 0);
    if (!volume) return 1;
    ntfs_inode *inode = ntfs_inode_open(volume, FILE_LogFile);
    ntfs_attr *attr = inode ? ntfs_attr_open(inode, AT_DATA, AT_UNNAMED, 0) : NULL;
    if (!attr) return 1;
    unsigned char page[4096] = {0};
    RESTART_PAGE_HEADER *rp = (RESTART_PAGE_HEADER *)page;
    rp->magic = magic_RSTR;
    rp->usa_ofs = cpu_to_le16(32);
    rp->usa_count = cpu_to_le16(9);
    rp->system_page_size = cpu_to_le32(sizeof(page));
    rp->log_page_size = cpu_to_le32(sizeof(page));
    rp->restart_area_offset = cpu_to_le16(64);
    rp->major_ver = cpu_to_sle16(version);
    rp->minor_ver = cpu_to_sle16(version == 1 ? 1 : 0);
    RESTART_AREA *ra = (RESTART_AREA *)(page + 64);
    ra->current_lsn = cpu_to_sle64(1);
    ra->log_clients = cpu_to_le16(1);
    ra->client_free_list = LOGFILE_NO_CLIENT;
    ra->client_in_use_list = cpu_to_le16(0);
    ra->flags = clean ? RESTART_VOLUME_IS_CLEAN : 0;
    unsigned long long size = attr->data_size;
    unsigned bits = 0;
    while (size) { ++bits; size >>= 1; }
    ra->seq_number_bits = cpu_to_le32(67 - bits);
    ra->client_array_offset = cpu_to_le16(64);
    ra->restart_area_length = cpu_to_le16(64 + sizeof(LOG_CLIENT_RECORD));
    ra->file_size = cpu_to_sle64(attr->data_size);
    ra->log_record_header_length = cpu_to_le16(48);
    ra->log_page_data_offset = cpu_to_le16(64);
    LOG_CLIENT_RECORD *client = (LOG_CLIENT_RECORD *)(page + 128);
    client->prev_client = LOGFILE_NO_CLIENT;
    client->next_client = LOGFILE_NO_CLIENT;
    int status = 0;
    for (int i = 0; i < 2; i++) {
        if (ntfs_attr_mst_pwrite(attr, i * sizeof(page), 1, sizeof(page), page) != 1) status = 1;
    }
    ntfs_attr_close(attr);
    if (ntfs_inode_close(inode) || ntfs_umount(volume, FALSE)) status = 1;
    return status;
}

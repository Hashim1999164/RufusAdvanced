#ifndef RUFUS_NTFS_H
#define RUFUS_NTFS_H

#include <stdint.h>
#include <stddef.h>

/// NTFS support for RufusAdvanced, built on the embedded ntfs-3g library (GPLv2+).
///
/// Everything works on an already open file descriptor (e.g. one obtained through authopen), on a
/// byte range [base, base+size) of it, so no mount, FUSE or kernel extension is needed. Unaligned
/// accesses are turned into sector aligned read-modify-write cycles, as raw disk devices require.

/// Create an NTFS file system (runs mkntfs in-process).
/// Returns 0 on success, otherwise -1 with a message in `err`.
int rufus_ntfs_format(int fd, uint64_t base, uint64_t size, uint32_t sector_size, uint64_t hidden_sectors,
                      uint32_t cluster_size, const char *label, int quick, char *err, size_t errlen);

typedef struct rufus_ntfs rufus_ntfs;

/// Mount an NTFS volume read/write through libntfs-3g (no kernel mount).
rufus_ntfs *rufus_ntfs_open(int fd, uint64_t base, uint64_t size, uint32_t sector_size, char *err, size_t errlen);

/// Create a directory (and its parents). Existing directories are fine. Paths use '/' and start with '/'.
int rufus_ntfs_mkdir(rufus_ntfs *vol, const char *path, char *err, size_t errlen);

/// Progress callback: return non-zero to cancel.
typedef int (*rufus_ntfs_progress)(void *ctx, uint64_t bytes);

/// Create (or replace) a file with the content of `srcfd` (`size` bytes).
int rufus_ntfs_write_file(rufus_ntfs *vol, const char *path, int srcfd, uint64_t size,
                          rufus_ntfs_progress progress, void *ctx, char *err, size_t errlen);

/// Create (or replace) a file from memory.
int rufus_ntfs_write_data(rufus_ntfs *vol, const char *path, const void *data, uint64_t size, char *err, size_t errlen);

/// 0 = missing, 1 = file, 2 = directory.
int rufus_ntfs_exists(rufus_ntfs *vol, const char *path);

/// Size of a file, or -1.
int64_t rufus_ntfs_file_size(rufus_ntfs *vol, const char *path);

/// Read up to `len` bytes at `offset` of a file. Returns bytes read or -1.
int64_t rufus_ntfs_read(rufus_ntfs *vol, const char *path, uint64_t offset, void *buf, uint64_t len);

/// Delete a file or an empty directory.
int rufus_ntfs_remove(rufus_ntfs *vol, const char *path, char *err, size_t errlen);

/// Set the volume label.
int rufus_ntfs_set_label(rufus_ntfs *vol, const char *label, char *err, size_t errlen);

/// Free / total clusters and the cluster size, for reporting.
void rufus_ntfs_space(rufus_ntfs *vol, uint64_t *free_bytes, uint64_t *total_bytes);

/// Flush and release the volume. Returns 0 on success.
int rufus_ntfs_close(rufus_ntfs *vol, char *err, size_t errlen);

#endif

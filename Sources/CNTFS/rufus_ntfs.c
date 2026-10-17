/*
 * rufus_ntfs.c - NTFS formatting and file copying for RufusAdvanced on top of libntfs-3g.
 *
 * This replaces ntfs-3g's unix_io.c device backend with one that works on an already open
 * descriptor plus a byte range, so a partition can be formatted and filled through the descriptor
 * that authopen hands us for the whole disk or a slice. Raw disk devices only accept sector
 * aligned I/O: unaligned requests are turned into read-modify-write cycles here.
 *
 * Copyright (c) 2026 RufusAdvanced contributors. GPLv3 (ntfs-3g itself is GPLv2+).
 */
#include "config.h"
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "types.h"
#include "device.h"
#include "device_io.h"
#include "volume.h"
#include "inode.h"
#include "dir.h"
#include "attrib.h"
#include "unistr.h"
#include "logging.h"
#include "misc.h"

#include "rufus_ntfs.h"

/* ---------------------------------------------------------------------------------------------
 * Device backend
 *
 * USB flash drives are very slow at small synchronous writes, and libntfs-3g issues thousands of
 * them (MFT records, bitmaps, indexes) plus many small reads. Small I/O therefore goes through a
 * write-back page cache: pages are read once, modified in memory, and written back sorted and
 * coalesced on sync/close (or when too many are dirty). Large I/O (file data) goes straight to the
 * device; cached copies of the pages it covers are kept coherent.
 * ------------------------------------------------------------------------------------------- */

#define RFD_PAGE        4096
#define RFD_LARGE_IO    (128 * 1024)      /* at least this: direct I/O */
#define RFD_READAHEAD   16                /* pages loaded together on a miss (64 KB) */
#define RFD_MAX_PAGES   65536             /* 256 MB of cache, then flush and drop */
#define RFD_MAX_DIRTY   32768             /* 128 MB dirty, then flush */
#define RFD_BUCKETS     65536             /* hash buckets (power of two) */
#define RFD_FLUSH_RUN   256               /* pages per coalesced write (1 MB) */

typedef struct {
    u64 reads, writes, small_writes, read_bytes, write_bytes, cache_hits, flushes;
} rfd_stats_t;

typedef struct rfd_page {
    s64 idx;
    struct rfd_page *next;
    int dirty;
    char *data;
} rfd_page_t;

typedef struct {
    int fd;
    int owned;
    s64 base;
    s64 size;
    s64 pos;
    u32 bs;
    s64 psize;                 /* cache page size: max(RFD_PAGE, bs) */
    rfd_page_t **buckets;
    size_t npages, ndirty;
    rfd_stats_t st;            /* device level I/O */
} rfd_t;

#define RFD(dev) ((rfd_t *)(dev)->d_private)

static s64 full_pread(int fd, void *buf, s64 count, s64 off) {
    s64 done = 0;
    while (done < count) {
        ssize_t r = pread(fd, (char *)buf + done, (size_t)(count - done), (off_t)(off + done));
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        if (r == 0) { memset((char *)buf + done, 0, (size_t)(count - done)); break; }
        done += r;
    }
    return count;
}

static s64 full_pwrite(int fd, const void *buf, s64 count, s64 off) {
    s64 done = 0;
    while (done < count) {
        ssize_t w = pwrite(fd, (const char *)buf + done, (size_t)(count - done), (off_t)(off + done));
        if (w < 0) { if (errno == EINTR) continue; return -1; }
        done += w;
    }
    return count;
}

/* Device I/O at a partition offset; offset and count are multiples of the block size. */
static s64 dev_read(rfd_t *p, s64 offset, void *buf, s64 count) {
    p->st.reads++; p->st.read_bytes += (u64)count;
    return full_pread(p->fd, buf, count, p->base + offset);
}

static s64 dev_write(rfd_t *p, s64 offset, const void *buf, s64 count) {
    p->st.writes++; p->st.write_bytes += (u64)count;
    if (count < 65536) p->st.small_writes++;
    return full_pwrite(p->fd, buf, count, p->base + offset);
}

/* Block aligned direct read of an arbitrary range. */
static s64 direct_read(rfd_t *p, s64 offset, void *buf, s64 count) {
    s64 bs = p->bs;
    if (offset % bs == 0 && count % bs == 0) return dev_read(p, offset, buf, count);
    s64 start = offset - offset % bs;
    s64 end = ((offset + count + bs - 1) / bs) * bs;
    if (end > p->size) end = p->size;
    char *tmp = NULL;
    if (posix_memalign((void **)&tmp, 4096, (size_t)(end - start)) != 0) { errno = ENOMEM; return -1; }
    if (dev_read(p, start, tmp, end - start) < 0) { int e = errno; free(tmp); errno = e; return -1; }
    memcpy(buf, tmp + (offset - start), (size_t)count);
    free(tmp);
    return count;
}

static inline s64 page_len(rfd_t *p, s64 idx) {
    s64 left = p->size - idx * p->psize;
    return left < p->psize ? left : p->psize;
}

static inline size_t page_hash(s64 idx) {
    u64 x = (u64)idx * 0x9E3779B97F4A7C15ULL;
    return (size_t)(x >> 48) & (RFD_BUCKETS - 1);
}

static rfd_page_t *page_find(rfd_t *p, s64 idx) {
    for (rfd_page_t *pg = p->buckets[page_hash(idx)]; pg; pg = pg->next)
        if (pg->idx == idx) return pg;
    return NULL;
}

static rfd_page_t *page_insert(rfd_t *p, s64 idx) {
    rfd_page_t *pg = calloc(1, sizeof(*pg));
    if (!pg) return NULL;
    if (posix_memalign((void **)&pg->data, 4096, (size_t)p->psize) != 0) { free(pg); return NULL; }
    pg->idx = idx;
    size_t h = page_hash(idx);
    pg->next = p->buckets[h];
    p->buckets[h] = pg;
    p->npages++;
    return pg;
}

static int page_cmp(const void *a, const void *b) {
    s64 x = (*(rfd_page_t * const *)a)->idx, y = (*(rfd_page_t * const *)b)->idx;
    return x < y ? -1 : x > y;
}

/* Write every dirty page, sorted and coalesced into runs of consecutive pages. */
static int cache_flush(rfd_t *p) {
    if (!p->buckets || p->ndirty == 0) return 0;
    rfd_page_t **list = malloc(p->ndirty * sizeof(*list));
    if (!list) { errno = ENOMEM; return -1; }
    size_t n = 0;
    for (size_t b = 0; b < RFD_BUCKETS; b++)
        for (rfd_page_t *pg = p->buckets[b]; pg; pg = pg->next)
            if (pg->dirty && n < p->ndirty) list[n++] = pg;
    qsort(list, n, sizeof(*list), page_cmp);
    char *run = NULL;
    if (posix_memalign((void **)&run, 4096, (size_t)(p->psize * RFD_FLUSH_RUN)) != 0) { free(list); errno = ENOMEM; return -1; }
    int rc = 0;
    size_t i = 0;
    while (i < n) {
        size_t j = i;
        s64 len = 0;
        while (j < n && j - i < RFD_FLUSH_RUN && list[j]->idx == list[i]->idx + (s64)(j - i)) {
            s64 l = page_len(p, list[j]->idx);
            memcpy(run + len, list[j]->data, (size_t)l);
            len += l;
            j++;
        }
        if (dev_write(p, list[i]->idx * p->psize, run, len) < 0) { rc = -1; break; }
        for (size_t k = i; k < j; k++) list[k]->dirty = 0;
        p->ndirty -= j - i;
        i = j;
    }
    p->st.flushes++;
    free(run);
    free(list);
    return rc;
}

static void cache_drop(rfd_t *p) {
    if (!p->buckets) return;
    for (size_t b = 0; b < RFD_BUCKETS; b++) {
        rfd_page_t *pg = p->buckets[b];
        while (pg) { rfd_page_t *n = pg->next; free(pg->data); free(pg); pg = n; }
        p->buckets[b] = NULL;
    }
    p->npages = 0;
    p->ndirty = 0;
}

/* The cached page, loaded from the device (with read-ahead) unless `whole` says it will be overwritten. */
static rfd_page_t *page_get(rfd_t *p, s64 idx, int whole) {
    rfd_page_t *pg = page_find(p, idx);
    if (pg) { p->st.cache_hits++; return pg; }
    if (p->npages >= RFD_MAX_PAGES) {
        if (cache_flush(p) < 0) return NULL;
        cache_drop(p);
    }
    if (whole) {
        pg = page_insert(p, idx);
        if (pg) memset(pg->data, 0, (size_t)p->psize);
        return pg;
    }
    /* Read the aligned group of pages around idx in one request; keep cached pages as they are. */
    s64 first = idx - idx % RFD_READAHEAD;
    s64 npg = RFD_READAHEAD;
    s64 maxpg = (p->size + p->psize - 1) / p->psize;
    if (first + npg > maxpg) npg = maxpg - first;
    s64 len = (npg - 1) * p->psize + page_len(p, first + npg - 1);
    char *tmp = NULL;
    if (posix_memalign((void **)&tmp, 4096, (size_t)len) != 0) { errno = ENOMEM; return NULL; }
    if (dev_read(p, first * p->psize, tmp, len) < 0) { int e = errno; free(tmp); errno = e; return NULL; }
    rfd_page_t *want = NULL;
    for (s64 k = 0; k < npg; k++) {
        rfd_page_t *q = page_find(p, first + k);
        if (!q) {
            q = page_insert(p, first + k);
            if (!q) { free(tmp); errno = ENOMEM; return NULL; }
            memcpy(q->data, tmp + k * p->psize, (size_t)page_len(p, first + k));
        }
        if (first + k == idx) want = q;
    }
    free(tmp);
    return want;
}

static s64 rfd_pread(struct ntfs_device *dev, void *buf, s64 count, s64 offset) {
    rfd_t *p = RFD(dev);
    if (offset < 0) { errno = EINVAL; return -1; }
    if (offset >= p->size) return 0;
    if (offset + count > p->size) count = p->size - offset;
    if (count <= 0) return 0;
    s64 first = offset / p->psize, last = (offset + count - 1) / p->psize;
    if (count >= RFD_LARGE_IO) {
        if (direct_read(p, offset, buf, count) < 0) return -1;
        /* Cached pages may be newer than the device. */
        for (s64 idx = first; idx <= last && p->npages; idx++) {
            rfd_page_t *pg = page_find(p, idx);
            if (!pg || !pg->dirty) continue;
            s64 ps = idx * p->psize, a = offset > ps ? offset : ps;
            s64 e = offset + count < ps + page_len(p, idx) ? offset + count : ps + page_len(p, idx);
            memcpy((char *)buf + (a - offset), pg->data + (a - ps), (size_t)(e - a));
        }
        return count;
    }
    for (s64 idx = first; idx <= last; idx++) {
        rfd_page_t *pg = page_get(p, idx, 0);
        if (!pg) return -1;
        s64 ps = idx * p->psize, a = offset > ps ? offset : ps;
        s64 e = offset + count < ps + page_len(p, idx) ? offset + count : ps + page_len(p, idx);
        memcpy((char *)buf + (a - offset), pg->data + (a - ps), (size_t)(e - a));
    }
    return count;
}

/* Copy into a cached page (loading it first unless it is overwritten entirely) and mark it dirty. */
static int cached_write(rfd_t *p, s64 idx, const char *buf, s64 offset, s64 count) {
    s64 ps = idx * p->psize, plen = page_len(p, idx);
    s64 a = offset > ps ? offset : ps;
    s64 e = offset + count < ps + plen ? offset + count : ps + plen;
    rfd_page_t *pg = page_get(p, idx, a == ps && e == ps + plen);
    if (!pg) return -1;
    memcpy(pg->data + (a - ps), buf + (a - offset), (size_t)(e - a));
    if (!pg->dirty) { pg->dirty = 1; p->ndirty++; }
    return 0;
}

static s64 rfd_pwrite(struct ntfs_device *dev, const void *buf, s64 count, s64 offset) {
    rfd_t *p = RFD(dev);
    if (NDevReadOnly(dev)) { errno = EROFS; return -1; }
    if (offset < 0) { errno = EINVAL; return -1; }
    if (offset >= p->size) { errno = ENOSPC; return -1; }
    if (offset + count > p->size) count = p->size - offset;
    if (count <= 0) return 0;
    NDevSetDirty(dev);
    const char *b = buf;
    s64 first = offset / p->psize, last = (offset + count - 1) / p->psize;
    if (count >= RFD_LARGE_IO) {
        /* Whole pages go straight to the device; partial edge pages through the cache. */
        s64 fs = (offset + p->psize - 1) / p->psize;          /* first whole page */
        s64 le = (offset + count) / p->psize;                  /* one past the last whole page */
        if (offset + count == p->size) le = last + 1;          /* short final page counts as whole */
        if (fs > first && cached_write(p, first, b, offset, count) < 0) return -1;
        if (le <= last && le >= fs && cached_write(p, last, b, offset, count) < 0) return -1;
        if (le > fs) {
            s64 ds = fs * p->psize;
            s64 de = le * p->psize < p->size ? le * p->psize : p->size;
            if (dev_write(p, ds, b + (ds - offset), de - ds) < 0) return -1;
            for (s64 idx = fs; idx < le && p->npages; idx++) {
                rfd_page_t *pg = page_find(p, idx);
                if (!pg) continue;
                memcpy(pg->data, b + (idx * p->psize - offset), (size_t)page_len(p, idx));
                if (pg->dirty) { pg->dirty = 0; p->ndirty--; }
            }
        } else if (fs > le) {
            /* No whole page at all (spans two partial pages only). */
            if (last != first && cached_write(p, last, b, offset, count) < 0) return -1;
        }
        return count;
    }
    for (s64 idx = first; idx <= last; idx++)
        if (cached_write(p, idx, b, offset, count) < 0) return -1;
    if (p->ndirty >= RFD_MAX_DIRTY && cache_flush(p) < 0) return -1;
    return count;
}

/* Names are either "rufusfd:<fd>:<base>:<size>:<sector size>" or a plain file path (tests). */
static int rfd_open(struct ntfs_device *dev, int flags) {
    rfd_t *p = calloc(1, sizeof(rfd_t));
    if (!p) { errno = ENOMEM; return -1; }
    if (strncmp(dev->d_name, "rufusfd:", 8) == 0) {
        long long fd = 0, base = 0, size = 0, bs = 512;
        if (sscanf(dev->d_name + 8, "%lld:%lld:%lld:%lld", &fd, &base, &size, &bs) != 4 || fd < 0 || size <= 0 || bs <= 0) {
            free(p);
            errno = EINVAL;
            return -1;
        }
        p->fd = (int)fd; p->owned = 0; p->base = base; p->size = size; p->bs = (u32)bs;
    } else {
        int fd = open(dev->d_name, (flags & O_ACCMODE) | O_CLOEXEC);
        if (fd < 0) { int e = errno; free(p); errno = e; return -1; }
        struct stat st;
        fstat(fd, &st);
        u32 bs = 512;
        u64 count = 0;
        s64 size = st.st_size;
        if (!S_ISREG(st.st_mode) && ioctl(fd, DKIOCGETBLOCKSIZE, &bs) == 0 && ioctl(fd, DKIOCGETBLOCKCOUNT, &count) == 0)
            size = (s64)(count * bs);
        p->fd = fd; p->owned = 1; p->base = 0; p->size = size; p->bs = bs ? bs : 512;
    }
    p->psize = p->bs > RFD_PAGE ? p->bs : RFD_PAGE;
    p->buckets = calloc(RFD_BUCKETS, sizeof(*p->buckets));
    if (!p->buckets) { if (p->owned) close(p->fd); free(p); errno = ENOMEM; return -1; }
    dev->d_private = p;
    NDevSetOpen(dev);
    if ((flags & O_ACCMODE) == O_RDONLY) NDevSetReadOnly(dev); else NDevClearReadOnly(dev);
    return 0;
}

static int rfd_sync(struct ntfs_device *dev) {
    rfd_t *p = RFD(dev);
    if (!NDevReadOnly(dev)) {
        if (cache_flush(p) < 0) return -1;
        struct stat st;
        if (fstat(p->fd, &st) == 0 && S_ISREG(st.st_mode)) fsync(p->fd);
        else ioctl(p->fd, DKIOCSYNCHRONIZECACHE);
        NDevClearDirty(dev);
    }
    return 0;
}

static int rfd_close(struct ntfs_device *dev) {
    rfd_t *p = RFD(dev);
    if (!p) return 0;
    int rc = 0;
    if (NDevDirty(dev) || p->ndirty) rc = rfd_sync(dev);
    if (getenv("RUFUS_NTFS_IOSTATS"))
        fprintf(stderr, "ntfs-io: %llu device reads (%llu MB), %llu device writes (%llu MB), %llu small writes (<64 KB), %llu cache hits, %llu flushes\n",
                (unsigned long long)p->st.reads, (unsigned long long)(p->st.read_bytes >> 20),
                (unsigned long long)p->st.writes, (unsigned long long)(p->st.write_bytes >> 20),
                (unsigned long long)p->st.small_writes, (unsigned long long)p->st.cache_hits,
                (unsigned long long)p->st.flushes);
    cache_drop(p);
    free(p->buckets);
    if (p->owned) close(p->fd);
    free(p);
    dev->d_private = NULL;
    NDevClearOpen(dev);
    return rc;
}

static s64 rfd_seek(struct ntfs_device *dev, s64 offset, int whence) {
    rfd_t *p = RFD(dev);
    switch (whence) {
    case SEEK_SET: p->pos = offset; break;
    case SEEK_CUR: p->pos += offset; break;
    case SEEK_END: p->pos = p->size + offset; break;
    default: errno = EINVAL; return -1;
    }
    return p->pos;
}

static s64 rfd_read(struct ntfs_device *dev, void *buf, s64 count) {
    s64 n = rfd_pread(dev, buf, count, RFD(dev)->pos);
    if (n > 0) RFD(dev)->pos += n;
    return n;
}

static s64 rfd_write(struct ntfs_device *dev, const void *buf, s64 count) {
    s64 n = rfd_pwrite(dev, buf, count, RFD(dev)->pos);
    if (n > 0) RFD(dev)->pos += n;
    return n;
}

static int rfd_stat(struct ntfs_device *dev, struct stat *buf) {
    rfd_t *p = RFD(dev);
    if (fstat(p->fd, buf) != 0) return -1;
    buf->st_size = p->size;
    return 0;
}

static int rfd_ioctl(struct ntfs_device *dev, unsigned long request, void *argp) {
    rfd_t *p = RFD(dev);
    if (request == DKIOCGETBLOCKCOUNT) { *(u64 *)argp = (u64)(p->size / p->bs); return 0; }
    if (request == DKIOCGETBLOCKSIZE) { *(u32 *)argp = p->bs; return 0; }
    errno = EOPNOTSUPP;
    return -1;
}

/* Replaces ntfs-3g's unix_io.c: every libntfs-3g open (including mkntfs) goes through here. */
struct ntfs_device_operations ntfs_device_unix_io_ops = {
    .open = rfd_open,
    .close = rfd_close,
    .seek = rfd_seek,
    .read = rfd_read,
    .write = rfd_write,
    .pread = rfd_pread,
    .pwrite = rfd_pwrite,
    .sync = rfd_sync,
    .stat = rfd_stat,
    .ioctl = rfd_ioctl,
};

/* ---------------------------------------------------------------------------------------------
 * Errors / logging
 * ------------------------------------------------------------------------------------------- */

static void seterr(char *err, size_t errlen, const char *fmt, ...) {
    if (!err || !errlen) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, errlen, fmt, ap);
    va_end(ap);
}

/* Set while an allocation that may legitimately fail (and has a fallback) is attempted. */
static int expect_alloc_failure = 0;

static int quiet_log(const char *function, const char *file, int line, u32 level, void *data, const char *format, va_list args) {
    (void)function; (void)file; (void)line; (void)data;
    if (expect_alloc_failure) return 0;
    /* Harmless: ntfs_delete() invalidating a path that was never cached. */
    if (strncmp(format, "Could not delete inode cache entry", 34) == 0) return 0;
    if (level & (NTFS_LOG_LEVEL_ERROR | NTFS_LOG_LEVEL_CRITICAL | NTFS_LOG_LEVEL_PERROR | NTFS_LOG_LEVEL_WARNING)) {
        fputs("ntfs-3g: ", stderr);
        return vfprintf(stderr, format, args);
    }
    return 0;
}

/* ---------------------------------------------------------------------------------------------
 * Formatting
 * ------------------------------------------------------------------------------------------- */

extern int mkntfs_main(int argc, char *argv[]);
extern int optind, optreset;

int rufus_ntfs_format(int fd, uint64_t base, uint64_t size, uint32_t sector_size, uint64_t hidden_sectors,
                      uint32_t cluster_size, const char *label, int quick, char *err, size_t errlen) {
    char name[160], bs[16], hidden[32], cluster[16], sectors[32];
    if (sector_size == 0) sector_size = 512;
    snprintf(name, sizeof(name), "rufusfd:%d:%llu:%llu:%u", fd, (unsigned long long)base, (unsigned long long)size, sector_size);
    snprintf(bs, sizeof(bs), "%u", sector_size);
    snprintf(hidden, sizeof(hidden), "%llu", (unsigned long long)hidden_sectors);
    snprintf(cluster, sizeof(cluster), "%u", cluster_size);
    snprintf(sectors, sizeof(sectors), "%llu", (unsigned long long)(size / sector_size));
    char *argv[24];
    int argc = 0;
    argv[argc++] = "mkntfs";
    argv[argc++] = "-F";                  /* not a block device: it's ours */
    argv[argc++] = "-q";
    if (quick) argv[argc++] = "-Q";
    argv[argc++] = "-s"; argv[argc++] = bs;
    argv[argc++] = "-p"; argv[argc++] = hidden;
    argv[argc++] = "-H"; argv[argc++] = "255";
    argv[argc++] = "-S"; argv[argc++] = "63";
    if (label && *label) { argv[argc++] = "-L"; argv[argc++] = (char *)label; }
    if (cluster_size) { argv[argc++] = "-c"; argv[argc++] = cluster; }
    argv[argc++] = name;
    argv[argc++] = sectors;
    argv[argc] = NULL;
    optind = 1;
    optreset = 1;
    int rc = mkntfs_main(argc, argv);
    ntfs_log_set_handler(quiet_log);      /* mkntfs installed its own stdout/stderr handler */
    if (rc != 0) {
        seterr(err, errlen, "mkntfs failed (status %d)", rc);
        return -1;
    }
    return 0;
}

/* ---------------------------------------------------------------------------------------------
 * Volume access
 * ------------------------------------------------------------------------------------------- */

struct rufus_ntfs {
    ntfs_volume *vol;
};

rufus_ntfs *rufus_ntfs_open(int fd, uint64_t base, uint64_t size, uint32_t sector_size, char *err, size_t errlen) {
    char name[160];
    ntfs_log_set_handler(quiet_log);
    snprintf(name, sizeof(name), "rufusfd:%d:%llu:%llu:%u", fd, (unsigned long long)base, (unsigned long long)size,
             sector_size ? sector_size : 512);
    struct ntfs_device *dev = ntfs_device_alloc(name, 0, &ntfs_device_unix_io_ops, NULL);
    if (!dev) { seterr(err, errlen, "ntfs_device_alloc: %s", strerror(errno)); return NULL; }
    ntfs_volume *vol = ntfs_device_mount(dev, NTFS_MNT_NONE);
    if (!vol) {
        int e = errno;
        ntfs_device_free(dev);
        seterr(err, errlen, "cannot open the NTFS volume: %s", strerror(e));
        return NULL;
    }
    /* Windows semantics: case-insensitive lookups, new names in the Win32 namespace. */
    ntfs_set_ignore_case(vol);
    rufus_ntfs *r = calloc(1, sizeof(rufus_ntfs));
    r->vol = vol;
    return r;
}

/* Split "/a/b/c" into parent inode ("/a/b") and the UCS-2 name ("c"). */
static ntfs_inode *open_parent(ntfs_volume *vol, const char *path, ntfschar **uname, int *ulen, char *err, size_t errlen) {
    const char *slash = strrchr(path, '/');
    if (!slash || slash[1] == 0) { seterr(err, errlen, "invalid path %s", path); return NULL; }
    char parent[4096];
    size_t plen = (size_t)(slash - path);
    if (plen >= sizeof(parent)) { seterr(err, errlen, "path too long"); return NULL; }
    if (plen == 0) strcpy(parent, "/");
    else { memcpy(parent, path, plen); parent[plen] = 0; }
    ntfs_inode *dir = ntfs_pathname_to_inode(vol, NULL, parent);
    if (!dir) { seterr(err, errlen, "parent directory %s not found", parent); return NULL; }
    *uname = NULL;
    *ulen = ntfs_mbstoucs(slash + 1, uname);
    if (*ulen <= 0) {
        ntfs_inode_close(dir);
        seterr(err, errlen, "invalid file name %s", slash + 1);
        return NULL;
    }
    return dir;
}

int rufus_ntfs_exists(rufus_ntfs *r, const char *path) {
    ntfs_inode *ni = ntfs_pathname_to_inode(r->vol, NULL, path);
    if (!ni) return 0;
    int kind = (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) ? 2 : 1;
    ntfs_inode_close(ni);
    return kind;
}

int rufus_ntfs_mkdir(rufus_ntfs *r, const char *path, char *err, size_t errlen) {
    char buf[4096];
    if (strlen(path) >= sizeof(buf)) { seterr(err, errlen, "path too long"); return -1; }
    strcpy(buf, path);
    /* Create every missing component. */
    for (char *p = buf + 1; ; p++) {
        if (*p == '/' || *p == 0) {
            char saved = *p;
            *p = 0;
            if (rufus_ntfs_exists(r, buf) == 0) {
                ntfschar *uname = NULL;
                int ulen = 0;
                ntfs_inode *dir = open_parent(r->vol, buf, &uname, &ulen, err, errlen);
                if (!dir) return -1;
                ntfs_inode *ni = ntfs_create(dir, const_cpu_to_le32(0), uname, (u8)ulen, S_IFDIR);
                int e = errno;
                free(uname);
                if (!ni) {
                    ntfs_inode_close(dir);
                    seterr(err, errlen, "cannot create directory %s: %s", buf, strerror(e));
                    return -1;
                }
                ntfs_inode_close(ni);
                ntfs_inode_close(dir);
            }
            if (saved == 0) break;
            *p = saved;
        }
    }
    return 0;
}

int rufus_ntfs_remove(rufus_ntfs *r, const char *path, char *err, size_t errlen) {
    ntfs_inode *ni = ntfs_pathname_to_inode(r->vol, NULL, path);
    if (!ni) return 0;
    ntfschar *uname = NULL;
    int ulen = 0;
    ntfs_inode *dir = open_parent(r->vol, path, &uname, &ulen, err, errlen);
    if (!dir) { ntfs_inode_close(ni); return -1; }
    /* ntfs_delete closes both inodes. */
    int rc = ntfs_delete(r->vol, path, ni, dir, uname, (u8)ulen);
    int e = errno;
    free(uname);
    if (rc) { seterr(err, errlen, "cannot delete %s: %s", path, strerror(e)); return -1; }
    return 0;
}

static ntfs_attr *create_file(rufus_ntfs *r, const char *path, ntfs_inode **out_ni, char *err, size_t errlen) {
    if (rufus_ntfs_exists(r, path) == 1 && rufus_ntfs_remove(r, path, err, errlen) != 0) return NULL;
    ntfschar *uname = NULL;
    int ulen = 0;
    ntfs_inode *dir = open_parent(r->vol, path, &uname, &ulen, err, errlen);
    if (!dir) return NULL;
    ntfs_inode *ni = ntfs_create(dir, const_cpu_to_le32(0), uname, (u8)ulen, S_IFREG);
    int e = errno;
    free(uname);
    ntfs_inode_close(dir);
    if (!ni) { seterr(err, errlen, "cannot create %s: %s", path, strerror(e)); return NULL; }
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!na) {
        e = errno;
        ntfs_inode_close(ni);
        seterr(err, errlen, "cannot open the data of %s: %s", path, strerror(e));
        return NULL;
    }
    *out_ni = ni;
    return na;
}

static int finish_file(ntfs_inode *ni, ntfs_attr *na, const char *path, char *err, size_t errlen) {
    ntfs_attr_close(na);
    ntfs_inode_update_times(ni, NTFS_UPDATE_MCTIME);
    if (ntfs_inode_close(ni)) {
        seterr(err, errlen, "cannot close %s: %s", path, strerror(errno));
        return -1;
    }
    return 0;
}

int rufus_ntfs_write_file(rufus_ntfs *r, const char *path, int srcfd, uint64_t size,
                          rufus_ntfs_progress progress, void *ctx, char *err, size_t errlen) {
    ntfs_inode *ni = NULL;
    ntfs_attr *na = create_file(r, path, &ni, err, errlen);
    if (!na) return -1;
    /* Allocate the whole file up front (not sparse): contiguous, and no cluster allocation per chunk.
     * If there is no single room for it outside the MFT zone, allocate as the data arrives instead
     * (a failed attempt leaves the attribute unchanged). */
    int solid = 0;
    if (size > 0) {
        expect_alloc_failure = 1;
        solid = ntfs_attr_truncate_solid(na, (s64)size) == 0;
        expect_alloc_failure = 0;
    }
    if (size > 0 && !solid && ntfs_attr_truncate(na, (s64)size)) {
        int e = errno;
        finish_file(ni, na, path, NULL, 0);
        seterr(err, errlen, "cannot allocate %llu bytes for %s: %s", (unsigned long long)size, path, strerror(e));
        return -1;
    }
    const size_t chunk = 8 * 1024 * 1024;
    char *buf = malloc(chunk);
    if (!buf) { finish_file(ni, na, path, NULL, 0); seterr(err, errlen, "out of memory"); return -1; }
    uint64_t done = 0;
    int rc = 0;
    while (done < size) {
        size_t want = (size - done) < chunk ? (size_t)(size - done) : chunk;
        ssize_t got = pread(srcfd, buf, want, (off_t)done);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) { seterr(err, errlen, "read error on the source of %s: %s", path, got < 0 ? strerror(errno) : "unexpected end of file"); rc = -1; break; }
        s64 w = ntfs_attr_pwrite(na, (s64)done, (s64)got, buf);
        if (w != got) { seterr(err, errlen, "write error on %s: %s", path, strerror(errno)); rc = -1; break; }
        done += (uint64_t)got;
        if (progress && progress(ctx, (uint64_t)got)) { seterr(err, errlen, "cancelled"); rc = -2; break; }
    }
    free(buf);
    if (finish_file(ni, na, path, rc ? NULL : err, errlen) && rc == 0) rc = -1;
    return rc;
}

int rufus_ntfs_write_data(rufus_ntfs *r, const char *path, const void *data, uint64_t size, char *err, size_t errlen) {
    ntfs_inode *ni = NULL;
    ntfs_attr *na = create_file(r, path, &ni, err, errlen);
    if (!na) return -1;
    int rc = 0;
    if (size > 0 && ntfs_attr_pwrite(na, 0, (s64)size, data) != (s64)size) {
        seterr(err, errlen, "write error on %s: %s", path, strerror(errno));
        rc = -1;
    }
    if (finish_file(ni, na, path, rc ? NULL : err, errlen) && rc == 0) rc = -1;
    return rc;
}

int64_t rufus_ntfs_file_size(rufus_ntfs *r, const char *path) {
    ntfs_inode *ni = ntfs_pathname_to_inode(r->vol, NULL, path);
    if (!ni) return -1;
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    int64_t size = na ? na->data_size : -1;
    if (na) ntfs_attr_close(na);
    ntfs_inode_close(ni);
    return size;
}

int64_t rufus_ntfs_read(rufus_ntfs *r, const char *path, uint64_t offset, void *buf, uint64_t len) {
    ntfs_inode *ni = ntfs_pathname_to_inode(r->vol, NULL, path);
    if (!ni) return -1;
    ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!na) { ntfs_inode_close(ni); return -1; }
    s64 got = ntfs_attr_pread(na, (s64)offset, (s64)len, buf);
    ntfs_attr_close(na);
    ntfs_inode_close(ni);
    return got;
}

int rufus_ntfs_set_label(rufus_ntfs *r, const char *label, char *err, size_t errlen) {
    ntfschar *ulabel = NULL;
    int ulen = ntfs_mbstoucs(label, &ulabel);
    if (ulen < 0) { seterr(err, errlen, "invalid label"); return -1; }
    int rc = ntfs_volume_rename(r->vol, ulabel, ulen);
    free(ulabel);
    if (rc) { seterr(err, errlen, "cannot set the label: %s", strerror(errno)); return -1; }
    return 0;
}

void rufus_ntfs_space(rufus_ntfs *r, uint64_t *free_bytes, uint64_t *total_bytes) {
    ntfs_volume *vol = r->vol;
    if (ntfs_volume_get_free_space(vol) == 0 && free_bytes)
        *free_bytes = (uint64_t)vol->free_clusters * vol->cluster_size;
    if (total_bytes) *total_bytes = (uint64_t)vol->nr_clusters * vol->cluster_size;
}

int rufus_ntfs_close(rufus_ntfs *r, char *err, size_t errlen) {
    if (!r) return 0;
    int rc = ntfs_umount(r->vol, FALSE);
    int e = errno;
    free(r);
    if (rc) { seterr(err, errlen, "cannot close the NTFS volume cleanly: %s", strerror(e)); return -1; }
    return 0;
}

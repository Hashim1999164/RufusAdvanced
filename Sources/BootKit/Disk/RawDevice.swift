import Foundation

// ioctl request codes from <sys/disk.h> (Swift cannot import the function-like macros).
let DKIOCGETBLOCKSIZE: UInt = 0x4004_6418       // _IOR('d', 24, uint32_t)
let DKIOCGETBLOCKCOUNT: UInt = 0x4008_6419      // _IOR('d', 25, uint64_t)
let DKIOCSYNCHRONIZECACHE: UInt = 0x2000_6416   // _IO('d', 22)
let DKIOCGETPHYSICALBLOCKSIZE: UInt = 0x4004_644D // _IOR('d', 77, uint32_t)

/// Sector-aligned access to a raw disk (`/dev/rdiskN`) or to a plain image file.
public final class RawDevice {
    public let path: String
    public private(set) var fd: Int32 = -1
    public let blockSize: UInt32
    public let size: UInt64
    public let isFile: Bool

    public init(path: String, writable: Bool) throws {
        self.path = path
        let flags = writable ? O_RDWR : O_RDONLY
        fd = open(path, flags | O_CLOEXEC)
        if fd < 0 {
            let e = errno
            logDebug("open(\(path), \(writable ? "O_RDWR" : "O_RDONLY")) failed: errno \(e) (\(String(cString: strerror(e))))")
            // macOS privacy protection (EPERM even as root) or no root (EACCES): go through authopen.
            if (e == EPERM || e == EACCES) && path.hasPrefix("/dev/") {
                logDebug("Retrying \(path) through authopen")
                fd = try DiskAuthorization.shared.open(path, flags: flags)
                _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            } else if e == EPERM || e == EACCES {
                throw BootKitError.permissionDenied(path: path, errno: e, detail: "open() failed")
            } else {
                throw BootKitError.openFailed(path, e)
            }
        } else {
            let opened = fd
            logDebug("open(\(path), \(writable ? "O_RDWR" : "O_RDONLY")) → fd \(opened)")
        }

        var st = stat()
        fstat(fd, &st)
        isFile = (st.st_mode & S_IFMT) == S_IFREG
        if isFile {
            blockSize = 512
            size = UInt64(st.st_size)
        } else {
            var bs: UInt32 = 0
            var count: UInt64 = 0
            if ioctl(fd, DKIOCGETBLOCKSIZE, &bs) != 0 { let e = errno; Darwin.close(fd); throw BootKitError.ioctlFailed("block size", e) }
            if ioctl(fd, DKIOCGETBLOCKCOUNT, &count) != 0 { let e = errno; Darwin.close(fd); throw BootKitError.ioctlFailed("block count", e) }
            blockSize = bs == 0 ? 512 : bs
            size = count * UInt64(blockSize)
            let sizeText = "\(count) sectors × \(bs == 0 ? 512 : bs) bytes = \(Units.human(count * UInt64(bs == 0 ? 512 : bs)))"
            logDebug("\(path): \(sizeText)")
        }
        // Bypass the unified buffer cache for plain files too (no effect on raw devices).
        _ = fcntl(fd, F_NOCACHE, 1)
    }

    deinit { close() }

    public func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    public var sectorCount: UInt64 { size / UInt64(blockSize) }

    /// Allocate a page-aligned buffer suitable for raw I/O.
    public static func alignedBuffer(_ size: Int) -> UnsafeMutableRawPointer {
        var p: UnsafeMutableRawPointer?
        posix_memalign(&p, 16384, max(size, 16384))
        memset(p!, 0, max(size, 16384))
        return p!
    }

    /// Read `count` bytes at `offset`. Offset and count must be block aligned.
    public func read(at offset: UInt64, into buf: UnsafeMutableRawPointer, count: Int) throws {
        precondition(offset % UInt64(blockSize) == 0 && count % Int(blockSize) == 0, "unaligned read")
        var done = 0
        while done < count {
            let r = pread(fd, buf + done, count - done, off_t(offset) + off_t(done))
            if r < 0 {
                if errno == EINTR { continue }
                throw BootKitError.readFailed(path, errno)
            }
            if r == 0 { // EOF: zero fill (image files shorter than a sector)
                memset(buf + done, 0, count - done)
                return
            }
            done += r
        }
    }

    /// Write `count` bytes at `offset` with retries. Offset and count must be block aligned.
    public func write(at offset: UInt64, from buf: UnsafeRawPointer, count: Int, retries: Int = 4) throws {
        precondition(offset % UInt64(blockSize) == 0 && count % Int(blockSize) == 0, "unaligned write")
        var done = 0
        var attempts = 0
        while done < count {
            let r = pwrite(fd, buf + done, count - done, off_t(offset) + off_t(done))
            if r < 0 {
                let e = errno
                if e == EINTR { continue }
                attempts += 1
                if attempts > retries {
                    if e == EPERM || e == EACCES { throw BootKitError.permissionDenied(path: path, errno: e, detail: "write at offset \(offset + UInt64(done)) failed") }
                    throw BootKitError.writeFailed(path, e)
                }
                logWarning("Write error at offset \(offset + UInt64(done)) (\(String(cString: strerror(e)))), retrying…")
                usleep(useconds_t(500_000 * attempts))
                continue
            }
            done += r
        }
    }

    /// Read arbitrary (unaligned) bytes.
    public func readBytes(at offset: UInt64, count: Int) throws -> [UInt8] {
        let bs = UInt64(blockSize)
        let start = Units.alignDown(offset, bs)
        let end = Units.alignUp(offset + UInt64(count), bs)
        let len = Int(end - start)
        let buf = RawDevice.alignedBuffer(len)
        defer { free(buf) }
        try read(at: start, into: buf, count: len)
        let p = buf.assumingMemoryBound(to: UInt8.self) + Int(offset - start)
        return Array(UnsafeBufferPointer(start: p, count: count))
    }

    /// Write arbitrary (unaligned) bytes through read-modify-write of the touched sectors.
    public func writeBytes(at offset: UInt64, _ bytes: [UInt8]) throws {
        guard !bytes.isEmpty else { return }
        let bs = UInt64(blockSize)
        let start = Units.alignDown(offset, bs)
        let end = Units.alignUp(offset + UInt64(bytes.count), bs)
        let len = Int(end - start)
        let buf = RawDevice.alignedBuffer(len)
        defer { free(buf) }
        if start != offset || end != offset + UInt64(bytes.count) {
            try read(at: start, into: buf, count: len)
        }
        let p = buf.assumingMemoryBound(to: UInt8.self) + Int(offset - start)
        bytes.withUnsafeBufferPointer { src in
            p.update(from: src.baseAddress!, count: bytes.count)
        }
        try write(at: start, from: buf, count: len)
    }

    /// Fill a byte range with zeros (aligned to sectors), e.g. to wipe old structures.
    public func zero(at offset: UInt64, count: UInt64) throws {
        let bs = UInt64(blockSize)
        var start = Units.alignDown(offset, bs)
        let end = min(Units.alignUp(offset + count, bs), size)
        let chunk = 1024 * 1024
        let buf = RawDevice.alignedBuffer(chunk)
        defer { free(buf) }
        while start < end {
            let n = Int(min(UInt64(chunk), end - start))
            try write(at: start, from: buf, count: n)
            start += UInt64(n)
        }
    }

    public func sync() {
        if isFile {
            fsync(fd)
        } else {
            _ = ioctl(fd, DKIOCSYNCHRONIZECACHE)
        }
    }
}

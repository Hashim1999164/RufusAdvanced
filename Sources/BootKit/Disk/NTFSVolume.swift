import Foundation
import CNTFS

/// NTFS formatting and file access through the embedded ntfs-3g library (no macFUSE, no mount).
/// Works on a byte range of an open `RawDevice`, so it also works on authopen descriptors.
public final class NTFSVolume {
    private var handle: OpaquePointer?
    public let path: String

    /// Create an NTFS file system on [offset, offset+size) of `dev`.
    public static func format(_ dev: RawDevice, offset: UInt64, size: UInt64, hiddenSectors: UInt64,
                              clusterSize: UInt32, label: String, quick: Bool) throws {
        var err = [CChar](repeating: 0, count: 512)
        logInfo("Creating NTFS file system (embedded mkntfs, \(quick ? "quick" : "full"), \(Units.human(size)))")
        let rc = rufus_ntfs_format(dev.fd, offset, size, dev.blockSize, hiddenSectors, clusterSize, label, quick ? 1 : 0, &err, err.count)
        if rc != 0 { throw BootKitError.generic("NTFS formatting failed: \(String(cString: err))") }
    }

    /// Open the NTFS volume stored at [offset, offset+size) of `dev` for reading and writing.
    public init(device dev: RawDevice, offset: UInt64 = 0, size: UInt64? = nil) throws {
        path = dev.path
        var err = [CChar](repeating: 0, count: 512)
        guard let h = rufus_ntfs_open(dev.fd, offset, size ?? (dev.size - offset), dev.blockSize, &err, err.count) else {
            throw BootKitError.generic("Could not open the NTFS volume on \(dev.path): \(String(cString: err))")
        }
        handle = h
    }

    deinit { try? close() }

    public func close() throws {
        guard let h = handle else { return }
        handle = nil
        var err = [CChar](repeating: 0, count: 512)
        if rufus_ntfs_close(h, &err, err.count) != 0 {
            throw BootKitError.generic("NTFS: \(String(cString: err))")
        }
    }

    final class FlushBox {
        let callback: (Int, UInt64, UInt64) -> Void
        init(_ c: @escaping (Int, UInt64, UInt64) -> Void) { callback = c }
    }

    /// Close, reporting progress while cached metadata is written back (stage 0, done/total bytes)
    /// and while the drive flushes its own write cache (stage 1). Can take a while on USB drives.
    public func close(progress: @escaping (_ stage: Int, _ done: UInt64, _ total: UInt64) -> Void) throws {
        guard let h = handle else { return }
        let box = FlushBox(progress)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<FlushBox>.fromOpaque(ctx).release() }
        rufus_ntfs_set_flush_progress(h, { ctx, stage, done, total in
            guard let ctx else { return }
            Unmanaged<FlushBox>.fromOpaque(ctx).takeUnretainedValue().callback(Int(stage), done, total)
        }, ctx)
        try close()
    }

    /// 0 = missing, 1 = file, 2 = directory.
    public func kind(_ path: String) -> Int { Int(rufus_ntfs_exists(handle, Self.normalize(path))) }

    public func mkdir(_ path: String) throws {
        var err = [CChar](repeating: 0, count: 512)
        if rufus_ntfs_mkdir(handle, Self.normalize(path), &err, err.count) != 0 {
            throw BootKitError.generic("NTFS: \(String(cString: err))")
        }
    }

    final class ProgressBox {
        let cancel: CancellationToken?
        let progress: (UInt64) -> Void
        init(cancel: CancellationToken?, progress: @escaping (UInt64) -> Void) { self.cancel = cancel; self.progress = progress }
    }

    /// Copy a local file into the volume (replacing an existing file).
    public func writeFile(_ path: String, from local: String, cancel: CancellationToken? = nil, progress: @escaping (UInt64) -> Void = { _ in }) throws {
        let fd = open(local, O_RDONLY | O_CLOEXEC)
        if fd < 0 { throw BootKitError.fileAccess(local, errno, target: false) }
        defer { Darwin.close(fd) }
        _ = fcntl(fd, F_RDAHEAD, 1)
        var st = stat()
        fstat(fd, &st)
        let box = ProgressBox(cancel: cancel, progress: progress)
        let ctx = Unmanaged.passUnretained(box).toOpaque()
        var err = [CChar](repeating: 0, count: 512)
        let rc = rufus_ntfs_write_file(handle, Self.normalize(path), fd, UInt64(st.st_size), { ctx, bytes in
            guard let ctx else { return 0 }
            let b = Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue()
            b.progress(bytes)
            return (b.cancel?.isCancelled ?? false) ? 1 : 0
        }, ctx, &err, err.count)
        withExtendedLifetime(box) {}
        if rc == -2 { throw BootKitError.cancelled }
        if rc != 0 { throw BootKitError.generic("NTFS: \(String(cString: err))") }
    }

    public func writeData(_ path: String, _ data: Data) throws {
        var err = [CChar](repeating: 0, count: 512)
        let rc = data.withUnsafeBytes { raw in
            rufus_ntfs_write_data(handle, Self.normalize(path), raw.baseAddress, UInt64(raw.count), &err, err.count)
        }
        if rc != 0 { throw BootKitError.generic("NTFS: \(String(cString: err))") }
    }

    public func size(_ path: String) -> Int64 { rufus_ntfs_file_size(handle, Self.normalize(path)) }

    public func read(_ path: String) -> Data? {
        let n = size(path)
        guard n >= 0 else { return nil }
        var d = Data(count: Int(n))
        let got = d.withUnsafeMutableBytes { rufus_ntfs_read(handle, Self.normalize(path), 0, $0.baseAddress, UInt64(n)) }
        return got == n ? d : nil
    }

    /// Read up to `count` bytes at `offset` (for streaming large files).
    public func read(_ path: String, offset: UInt64, count: Int) -> Data? {
        var d = Data(count: count)
        let got = d.withUnsafeMutableBytes { rufus_ntfs_read(handle, Self.normalize(path), offset, $0.baseAddress, UInt64(count)) }
        guard got >= 0 else { return nil }
        d.count = Int(got)
        return d
    }

    public func remove(_ path: String) throws {
        var err = [CChar](repeating: 0, count: 512)
        if rufus_ntfs_remove(handle, Self.normalize(path), &err, err.count) != 0 {
            throw BootKitError.generic("NTFS: \(String(cString: err))")
        }
    }

    public func setLabel(_ label: String) throws {
        var err = [CChar](repeating: 0, count: 512)
        if rufus_ntfs_set_label(handle, label, &err, err.count) != 0 {
            throw BootKitError.generic("NTFS: \(String(cString: err))")
        }
    }

    public var space: (free: UInt64, total: UInt64) {
        var f: UInt64 = 0, t: UInt64 = 0
        rufus_ntfs_space(handle, &f, &t)
        return (f, t)
    }

    static func normalize(_ p: String) -> String {
        var s = p.replacingOccurrences(of: "\\", with: "/")
        if !s.hasPrefix("/") { s = "/" + s }
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

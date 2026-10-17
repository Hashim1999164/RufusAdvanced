import Foundation
import CryptoKit

/// Copies a directory tree (an ISO's contents) to the target volume with byte level progress.
/// Writes plain data only (no extended attributes), so no "._" AppleDouble files are created.
public final class FileCopier {
    public struct Options {
        public var skip: Set<String> = []          // lowercased relative paths ("/sources/install.wim")
        public var sanitizeForFAT = true
        public var computeMD5 = false
        public var maxFileSize: UInt64 = .max
        public init() {}
    }

    public private(set) var md5: [String: String] = [:]     // relative path -> md5
    public private(set) var bytesCopied: UInt64 = 0
    public private(set) var renamed: [String: String] = [:]
    let options: Options
    let cancel: CancellationToken
    let progress: (UInt64, String) -> Void

    public init(options: Options, cancel: CancellationToken, progress: @escaping (UInt64, String) -> Void) {
        self.options = options
        self.cancel = cancel
        self.progress = progress
    }

    static let fatInvalid = CharacterSet(charactersIn: "\"*:<>?\\|").union(.controlCharacters)

    func sanitize(_ name: String) -> String {
        guard options.sanitizeForFAT else { return name }
        var out = String(String.UnicodeScalarView(name.unicodeScalars.map { Self.fatInvalid.contains($0) ? "_" : $0 }))
        while out.hasSuffix(".") || out.hasSuffix(" ") { out.removeLast() }
        return out.isEmpty ? "_" : out
    }

    /// Total bytes that `copyTree` will copy.
    public static func totalSize(of root: String, skip: Set<String>) -> UInt64 {
        guard let e = FileManager.default.enumerator(atPath: root) else { return 0 }
        var total: UInt64 = 0
        while let rel = e.nextObject() as? String {
            if skip.contains("/" + rel.lowercased()) { continue }
            let a = e.fileAttributes ?? [:]
            if (a[.type] as? FileAttributeType) == .typeRegular { total += (a[.size] as? NSNumber)?.uint64Value ?? 0 }
        }
        return total
    }

    public func copyTree(from src: String, to dst: String) throws {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: src) else { throw BootKitError.generic("Cannot enumerate \(src)") }
        while let relRaw = e.nextObject() as? String {
            try cancel.check()
            let relOriginal = "/" + relRaw
            let relLower = relOriginal.lowercased()
            let attrs = e.fileAttributes ?? [:]
            let type = attrs[.type] as? FileAttributeType
            if options.skip.contains(relLower) {
                if type == .typeDirectory { e.skipDescendants() }
                continue
            }
            let relDest = relRaw.split(separator: "/").map { sanitize(String($0)) }.joined(separator: "/")
            if relDest != relRaw { renamed[relOriginal] = relDest }
            let target = (dst as NSString).appendingPathComponent(relDest)
            let sourcePath = (src as NSString).appendingPathComponent(relRaw)

            if type == .typeSymbolicLink {
                // FAT cannot store links: copy the file it points to (directories are skipped to avoid loops).
                let resolved = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath().path
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: resolved, isDirectory: &isDir), !isDir.boolValue {
                    try copyFile(resolved, to: target, rel: relLower)
                } else {
                    logWarning("Skipped symbolic link \(relOriginal)")
                }
                continue
            }
            if type == .typeDirectory {
                try fm.createDirectory(atPath: target, withIntermediateDirectories: true)
                continue
            }
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            if size > options.maxFileSize {
                throw BootKitError.unsupported("'\(relOriginal)' is \(Units.human(size)), larger than the target file system allows (4 GB on FAT32).")
            }
            try copyFile(sourcePath, to: target, rel: relLower)
            if let date = attrs[.modificationDate] as? Date {
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: target)
            }
        }
    }

    func copyFile(_ from: String, to: String, rel: String) throws {
        let inFD = open(from, O_RDONLY | O_CLOEXEC)
        if inFD < 0 { throw BootKitError.openFailed(from, errno) }
        defer { close(inFD) }
        try? FileManager.default.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let outFD = open(to, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        if outFD < 0 { throw BootKitError.openFailed(to, errno) }
        defer { close(outFD) }
        _ = fcntl(outFD, F_NOCACHE, 1)
        _ = fcntl(inFD, F_RDAHEAD, 1)

        let bufSize = 8 * 1024 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16384)
        defer { buf.deallocate() }
        var hasher = options.computeMD5 ? Insecure.MD5() : nil
        let name = (rel as NSString).lastPathComponent
        while true {
            try cancel.check()
            let n = read(inFD, buf, bufSize)
            if n < 0 { if errno == EINTR { continue }; throw BootKitError.readFailed(from, errno) }
            if n == 0 { break }
            hasher?.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
            var written = 0
            while written < n {
                let w = write(outFD, buf + written, n - written)
                if w < 0 {
                    if errno == EINTR { continue }
                    let e = errno
                    if e == ENOSPC { throw BootKitError.generic("The target drive is full.") }
                    if e == EFBIG { throw BootKitError.unsupported("'\(rel)' is too large for the target file system.") }
                    throw BootKitError.writeFailed(to, e)
                }
                written += w
            }
            bytesCopied += UInt64(n)
            progress(bytesCopied, name)
        }
        if let hasher { md5[rel] = hasher.finalize().hex }
    }
}

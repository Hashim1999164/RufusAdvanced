import Foundation

/// A readable stream of raw disk bytes from an image file (decompressing as needed).
public protocol ImageSource: AnyObject {
    /// Uncompressed size if known.
    var rawSize: UInt64? { get }
    /// Denominator for progress (compressed size for compressed inputs).
    var progressTotal: UInt64 { get }
    /// Current position in `progressTotal` units.
    var progressPosition: UInt64 { get }
    /// Read up to `count` bytes. Returns 0 at end of stream.
    func read(into buf: UnsafeMutableRawPointer, count: Int) throws -> Int
    func close()
}

/// Plain file (optionally limited to `limit` bytes, e.g. a fixed VHD minus its footer).
public final class FileImageSource: ImageSource {
    private let fd: Int32
    private var pos: UInt64 = 0
    private let limit: UInt64
    public let rawSize: UInt64?
    public var progressTotal: UInt64 { limit }
    public var progressPosition: UInt64 { pos }

    public init(path: String, limit: UInt64? = nil) throws {
        fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 { throw BootKitError.openFailed(path, errno) }
        var st = stat()
        fstat(fd, &st)
        self.limit = limit ?? UInt64(st.st_size)
        rawSize = self.limit
        _ = fcntl(fd, F_RDAHEAD, 1)
    }

    public func read(into buf: UnsafeMutableRawPointer, count: Int) throws -> Int {
        let want = Int(min(UInt64(count), limit - pos))
        guard want > 0 else { return 0 }
        var got = 0
        while got < want {
            let r = pread(fd, buf + got, want - got, off_t(pos) + off_t(got))
            if r < 0 { if errno == EINTR { continue }; throw BootKitError.readFailed("image", errno) }
            if r == 0 { break }
            got += r
        }
        pos += UInt64(got)
        return got
    }

    public func close() { Darwin.close(fd) }
}

/// Decompression through an external tool. Compressed input is fed by us (so we know the
/// progress), decompressed output is read from the tool's stdout.
public final class ProcessImageSource: ImageSource {
    private let process = Process()
    private let outHandle: FileHandle
    private var fed: UInt64 = 0
    private let fedLock = NSLock()
    private let compressedSize: UInt64
    private var produced: UInt64 = 0
    private let feedsStdin: Bool
    private var errorText = ""
    public let rawSize: UInt64?
    public var progressTotal: UInt64 { feedsStdin ? compressedSize : (rawSize ?? compressedSize) }
    public var progressPosition: UInt64 {
        if feedsStdin { fedLock.lock(); defer { fedLock.unlock() }; return fed }
        return produced
    }

    /// - Parameters:
    ///   - stdinFile: if set, this file is streamed into the tool's stdin.
    public init(tool: String, arguments: [String], stdinFile: String?, rawSize: UInt64?) throws {
        self.rawSize = rawSize
        feedsStdin = stdinFile != nil
        compressedSize = stdinFile.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? UInt64) ?? nil } ?? (rawSize ?? 0)
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.environment = Shell.environment
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        outHandle = outPipe.fileHandleForReading
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { self?.errorText += String(decoding: d, as: UTF8.self) }
        }
        var inPipe: Pipe?
        if stdinFile != nil {
            inPipe = Pipe()
            process.standardInput = inPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        try process.run()
        if let stdinFile, let inPipe {
            let writer = inPipe.fileHandleForWriting
            Thread.detachNewThread { [weak self] in
                guard let src = FileHandle(forReadingAtPath: stdinFile) else { try? writer.close(); return }
                while true {
                    guard let chunk = try? src.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty else { break }
                    do { try writer.write(contentsOf: chunk) } catch { break }
                    if let self { self.fedLock.lock(); self.fed += UInt64(chunk.count); self.fedLock.unlock() }
                }
                try? src.close()
                try? writer.close()
            }
        }
        signal(SIGPIPE, SIG_IGN)
    }

    public func read(into buf: UnsafeMutableRawPointer, count: Int) throws -> Int {
        var got = 0
        let fd = outHandle.fileDescriptor
        while got < count {
            let r = Darwin.read(fd, buf + got, count - got)
            if r < 0 { if errno == EINTR { continue }; throw BootKitError.readFailed("decompressor", errno) }
            if r == 0 { break }
            got += r
        }
        produced += UInt64(got)
        if got == 0 {
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                throw BootKitError.commandFailed((process.executableURL?.lastPathComponent ?? "decompressor"), process.terminationStatus, errorText)
            }
        }
        return got
    }

    public func close() {
        if process.isRunning { process.terminate() }
        try? outHandle.close()
    }
}

public enum ImageSourceFactory {
    /// Open a stream of raw disk bytes for a DD write. `scratch` is used for formats that
    /// must be converted first (DMG, VHDX, ...).
    public static func open(_ report: ImageReport, scratch: String, reporter: JobReporter?, cancel: CancellationToken?) throws -> ImageSource {
        let path = report.path
        switch report.kind {
        case .compressedDisk:
            switch report.compression {
            case .gzip, .xz:
                return try ProcessImageSource(tool: "/usr/bin/gzip", arguments: ["-dc"], stdinFile: path, rawSize: nil)
            case .bzip2:
                return try ProcessImageSource(tool: "/usr/bin/bzip2", arguments: ["-dc"], stdinFile: path, rawSize: nil)
            case .zstd:
                guard let z = ExternalTool.zstd.path else { throw BootKitError.toolMissing(tool: "zstd", hint: "Install it with: brew install zstd") }
                return try ProcessImageSource(tool: z, arguments: ["-dc"], stdinFile: path, rawSize: nil)
            case .lzma:
                guard let x = ExternalTool.xz.path else { throw BootKitError.toolMissing(tool: "xz", hint: "Install it with: brew install xz") }
                return try ProcessImageSource(tool: x, arguments: ["--format=lzma", "-dc"], stdinFile: path, rawSize: nil)
            case .zip:
                let (entry, size) = try largestZipEntry(path)
                logInfo("Using '\(entry)' from the zip archive (\(Units.human(size)))")
                return try ProcessImageSource(tool: "/usr/bin/unzip", arguments: ["-p", path, entry], stdinFile: nil, rawSize: size)
            case .sevenZip:
                guard let z = ExternalTool.sevenZip.path else { throw BootKitError.toolMissing(tool: "7z", hint: "Install it with: brew install sevenzip") }
                return try ProcessImageSource(tool: z, arguments: ["e", "-so", path], stdinFile: nil, rawSize: nil)
            case .none:
                return try FileImageSource(path: path)
            }
        case .vhd:
            return try FileImageSource(path: path, limit: report.size - 512)
        case .virtualDisk:
            guard let q = ExternalTool.qemuImg.path else {
                throw BootKitError.toolMissing(tool: "qemu-img", hint: "Install it with: brew install qemu")
            }
            let out = scratch + "/converted-\(UUID().uuidString).img"
            reporter?.begin("Converting virtual disk to raw")
            try Shell.check(q, ["convert", "-p", "-O", "raw", path, out], cancel: cancel) { line in
                if let pct = Double(line.trimmingCharacters(in: .whitespaces).components(separatedBy: "/").first?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "() %")) ?? "") {
                    reporter?.update(fraction: pct / 100)
                }
            }
            return try TempFileImageSource(path: out)
        case .appleDiskImage:
            let out = scratch + "/converted-\(UUID().uuidString)"
            reporter?.begin("Converting Apple disk image to raw")
            try Shell.check("/usr/bin/hdiutil", ["convert", path, "-format", "UDTO", "-o", out, "-puppetstrings"], cancel: cancel) { line in
                if line.hasPrefix("PERCENT:"), let v = Double(line.dropFirst(8)), v >= 0 { reporter?.update(fraction: v / 100) }
            }
            return try TempFileImageSource(path: out + ".cdr")
        default:
            return try FileImageSource(path: path)
        }
    }

    static func largestZipEntry(_ zip: String) throws -> (String, UInt64) {
        let r = try Shell.check("/usr/bin/unzip", ["-Z", "-l", zip])
        var best: (String, UInt64)?
        for line in r.stdout.split(separator: "\n") {
            // -rw-r--r--  3.0 unx 1234567 b- 456 defN 23-Jan-01 00:00 name
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 10, let size = UInt64(cols[3]), !line.hasPrefix("d") else { continue }
            let name = cols[9...].joined(separator: " ")
            let preferred = [".img", ".iso", ".raw", ".bin", ".dd"].contains { name.lowercased().hasSuffix($0) }
            if best == nil || (preferred && size > best!.1) || (!preferred && best!.1 == 0) { best = (name, size) }
        }
        guard let best else { throw BootKitError.unsupportedImage("The zip archive does not contain a disk image.") }
        return best
    }
}

/// File source that deletes its (temporary converted) file on close.
final class TempFileImageSource: ImageSource {
    private let inner: FileImageSource
    private let path: String
    init(path: String) throws { self.path = path; inner = try FileImageSource(path: path) }
    var rawSize: UInt64? { inner.rawSize }
    var progressTotal: UInt64 { inner.progressTotal }
    var progressPosition: UInt64 { inner.progressPosition }
    func read(into buf: UnsafeMutableRawPointer, count: Int) throws -> Int { try inner.read(into: buf, count: count) }
    func close() { inner.close(); try? FileManager.default.removeItem(atPath: path) }
}

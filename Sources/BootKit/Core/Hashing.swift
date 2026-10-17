import Foundation
import CryptoKit

public enum HashAlgorithm: String, CaseIterable, Codable, Sendable, Identifiable {
    case md5 = "MD5"
    case sha1 = "SHA-1"
    case sha256 = "SHA-256"
    case sha512 = "SHA-512"
    public var id: String { rawValue }
}

/// Streaming multi-hash computation (one pass over the file for every algorithm).
public struct MultiHasher {
    private var md5 = Insecure.MD5()
    private var sha1 = Insecure.SHA1()
    private var sha256 = SHA256()
    private var sha512 = SHA512()
    private let algorithms: Set<HashAlgorithm>

    public init(_ algorithms: Set<HashAlgorithm> = Set(HashAlgorithm.allCases)) {
        self.algorithms = algorithms
    }

    public mutating func update(_ buf: UnsafeRawBufferPointer) {
        if algorithms.contains(.md5) { md5.update(bufferPointer: buf) }
        if algorithms.contains(.sha1) { sha1.update(bufferPointer: buf) }
        if algorithms.contains(.sha256) { sha256.update(bufferPointer: buf) }
        if algorithms.contains(.sha512) { sha512.update(bufferPointer: buf) }
    }

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    public func finalize() -> [HashAlgorithm: String] {
        var r: [HashAlgorithm: String] = [:]
        if algorithms.contains(.md5) { r[.md5] = md5.finalize().hex }
        if algorithms.contains(.sha1) { r[.sha1] = sha1.finalize().hex }
        if algorithms.contains(.sha256) { r[.sha256] = sha256.finalize().hex }
        if algorithms.contains(.sha512) { r[.sha512] = sha512.finalize().hex }
        return r
    }

    /// Hash a whole file with progress (0...1).
    public static func hashFile(at path: String,
                                algorithms: Set<HashAlgorithm> = Set(HashAlgorithm.allCases),
                                cancel: CancellationToken? = nil,
                                progress: ((Double) -> Void)? = nil) throws -> [HashAlgorithm: String] {
        guard let fh = FileHandle(forReadingAtPath: path) else {
            throw BootKitError.openFailed(path, errno)
        }
        defer { try? fh.close() }
        let total = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        var hasher = MultiHasher(algorithms)
        var done: UInt64 = 0
        var lastReport = Date.distantPast
        while true {
            try cancel?.check()
            let chunk = try fh.read(upToCount: 8 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(chunk)
            done += UInt64(chunk.count)
            if total > 0, Date().timeIntervalSince(lastReport) > 0.1 {
                lastReport = Date()
                progress?(Double(done) / Double(total))
            }
        }
        progress?(1)
        return hasher.finalize()
    }
}

public extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

public extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

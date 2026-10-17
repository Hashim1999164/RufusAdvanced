import Foundation
import CryptoKit
import zlib

/// Verifies Apple installer packages (.pkg = xar archives) against the software update catalog.
///
/// The catalog's `Digest` is **not** a hash of the whole file: it is the SHA-1 of the package's
/// compressed xar table of contents (TOC). The TOC in turn lists a checksum for every file stored
/// in the archive, so a full check is: TOC hash == Digest, then every stored file == its TOC checksum.
public enum ApplePackageVerifier {

    public struct Header {
        public var size: Int
        public var tocCompressed: Int
        public var tocUncompressed: Int
        public var checksumAlgorithm: UInt32     // 0 none, 1 SHA-1, 2 MD5, 3 named
    }

    public struct Entry {
        public var name: String
        public var offset: UInt64                // relative to the heap
        public var length: UInt64
        public var algorithm: String             // "sha1", "md5", "sha256", …
        public var checksum: String
    }

    static func readHeader(_ fh: FileHandle) throws -> Header {
        try fh.seek(toOffset: 0)
        guard let d = try fh.read(upToCount: 28), d.count == 28 else { throw BootKitError.verificationFailed("not a package (file too short)") }
        let b = [UInt8](d)
        guard b[0] == 0x78, b[1] == 0x61, b[2] == 0x72, b[3] == 0x21 else {
            throw BootKitError.verificationFailed("not an installer package (no xar header)")
        }
        func be(_ o: Int, _ n: Int) -> UInt64 { (0..<n).reduce(0) { $0 << 8 | UInt64(b[o + $1]) } }
        return Header(size: Int(be(4, 2)), tocCompressed: Int(be(8, 8)), tocUncompressed: Int(be(16, 8)),
                      checksumAlgorithm: UInt32(be(24, 4)))
    }

    /// SHA-1 of the compressed TOC: the value Apple publishes as the package `Digest`.
    public static func catalogDigest(of path: String) throws -> String {
        guard let fh = FileHandle(forReadingAtPath: path) else { throw BootKitError.fileAccess(path, errno, target: false) }
        defer { try? fh.close() }
        let h = try readHeader(fh)
        try fh.seek(toOffset: UInt64(h.size))
        guard let toc = try fh.read(upToCount: h.tocCompressed), toc.count == h.tocCompressed else {
            throw BootKitError.verificationFailed("truncated package table of contents")
        }
        return Insecure.SHA1.hash(data: toc).map { String(format: "%02x", $0) }.joined()
    }

    /// The files stored in the package with their archived checksums.
    public static func entries(of path: String) throws -> (heapStart: UInt64, entries: [Entry]) {
        guard let fh = FileHandle(forReadingAtPath: path) else { throw BootKitError.fileAccess(path, errno, target: false) }
        defer { try? fh.close() }
        let h = try readHeader(fh)
        try fh.seek(toOffset: UInt64(h.size))
        guard let toc = try fh.read(upToCount: h.tocCompressed), toc.count == h.tocCompressed else {
            throw BootKitError.verificationFailed("truncated package table of contents")
        }
        let xml = try inflate(toc, expected: h.tocUncompressed)
        let doc = try XMLDocument(data: xml)
        var out: [Entry] = []
        for node in try doc.nodes(forXPath: "//file") {
            guard let file = node as? XMLElement,
                  let data = file.elements(forName: "data").first,
                  let offset = data.elements(forName: "offset").first?.stringValue.flatMap({ UInt64($0) }),
                  let length = data.elements(forName: "length").first?.stringValue.flatMap({ UInt64($0) }),
                  let sum = data.elements(forName: "archived-checksum").first,
                  let value = sum.stringValue else { continue }
            let style = sum.attribute(forName: "style")?.stringValue?.lowercased() ?? "sha1"
            let name = file.elements(forName: "name").first?.stringValue ?? "?"
            out.append(Entry(name: name, offset: offset, length: length, algorithm: style,
                             checksum: value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()))
        }
        return (UInt64(h.size + h.tocCompressed), out)
    }

    static func inflate(_ data: Data, expected: Int) throws -> Data {
        var out = Data(count: max(expected, 1))
        var destLen = uLongf(out.count)
        let rc = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                uncompress(o.bindMemory(to: Bytef.self).baseAddress, &destLen,
                           i.bindMemory(to: Bytef.self).baseAddress, uLong(data.count))
            }
        }
        guard rc == Z_OK else { throw BootKitError.verificationFailed("cannot read the package table of contents (zlib \(rc))") }
        out.count = Int(destLen)
        return out
    }

    public enum Outcome: Equatable, Sendable {
        case verified(files: Int, bytes: UInt64)
        case mismatch(String)
    }

    /// Full check: TOC hash against the catalog digest, then every stored file against its TOC checksum.
    public static func verify(_ path: String, catalogDigest: String?, cancel: CancellationToken? = nil,
                              progress: (Double) -> Void = { _ in }) throws -> Outcome {
        if let expected = catalogDigest?.lowercased(), !expected.isEmpty {
            let actual = try Self.catalogDigest(of: path)
            if actual != expected {
                return .mismatch("The package doesn't match Apple's catalog (digest \(actual), expected \(expected)).")
            }
        }
        let (heap, entries) = try entries(of: path)
        guard let fh = FileHandle(forReadingAtPath: path) else { throw BootKitError.fileAccess(path, errno, target: false) }
        defer { try? fh.close() }
        let total = entries.reduce(UInt64(0)) { $0 + $1.length }
        var done: UInt64 = 0
        let chunk = 8 * 1024 * 1024
        for e in entries {
            try cancel?.check()
            try fh.seek(toOffset: heap + e.offset)
            var remaining = e.length
            var sha1 = Insecure.SHA1(), md5 = Insecure.MD5(), sha256 = SHA256()
            while remaining > 0 {
                try cancel?.check()
                let n = Int(min(UInt64(chunk), remaining))
                guard let d = try fh.read(upToCount: n), d.count == n else {
                    return .mismatch("The package is truncated (\(e.name) is incomplete).")
                }
                switch e.algorithm {
                case "md5": md5.update(data: d)
                case "sha256": sha256.update(data: d)
                default: sha1.update(data: d)
                }
                remaining -= UInt64(n)
                done += UInt64(n)
                if total > 0 { progress(Double(done) / Double(total)) }
            }
            let got: String
            switch e.algorithm {
            case "md5": got = md5.finalize().map { String(format: "%02x", $0) }.joined()
            case "sha256": got = sha256.finalize().map { String(format: "%02x", $0) }.joined()
            default: got = sha1.finalize().map { String(format: "%02x", $0) }.joined()
            }
            if got != e.checksum {
                return .mismatch("\(e.name) inside the package is damaged (checksum \(got), expected \(e.checksum)).")
            }
        }
        return .verified(files: entries.count, bytes: total)
    }
}

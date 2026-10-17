import Foundation

/// Sidecar JSON stored next to every downloaded file ("<file>.rufusadv.json"), so the app can
/// recognise, verify and re-use previous downloads.
public struct DownloadMetadata: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case apple, appleLegacy, microsoft, linux, uefiShell, custom
    }

    public var source: Source
    public var title: String
    public var url: String
    public var fileName: String
    public var size: UInt64?
    public var checksum: String?
    public var checksumAlgorithm: HashAlgorithm?
    public var verified: Bool
    public var downloadedAt: Date
    public var macInstaller: MacInstallerInfo?
    public var productID: String?
    public var notes: String?

    public init(source: Source, title: String, url: String, fileName: String, size: UInt64? = nil,
                checksum: String? = nil, checksumAlgorithm: HashAlgorithm? = nil, verified: Bool = false,
                downloadedAt: Date = Date(), macInstaller: MacInstallerInfo? = nil, productID: String? = nil, notes: String? = nil) {
        self.source = source
        self.title = title
        self.url = url
        self.fileName = fileName
        self.size = size
        self.checksum = checksum
        self.checksumAlgorithm = checksumAlgorithm
        self.verified = verified
        self.downloadedAt = downloadedAt
        self.macInstaller = macInstaller
        self.productID = productID
        self.notes = notes
    }

    public static func sidecarPath(for file: String) -> String { file + ".rufusadv.json" }

    public static func load(for file: String) -> DownloadMetadata? {
        guard let d = FileManager.default.contents(atPath: sidecarPath(for: file)) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(DownloadMetadata.self, from: d)
    }

    public func save(for file: String) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(self) {
            try? d.write(to: URL(fileURLWithPath: DownloadMetadata.sidecarPath(for: file)))
        }
    }

    /// All completed downloads found in a folder (recursively, one level of product folders).
    public static func scan(folder: String) -> [(path: String, meta: DownloadMetadata)] {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: folder) else { return [] }
        var out: [(String, DownloadMetadata)] = []
        for case let rel as String in e where rel.hasSuffix(".rufusadv.json") {
            let file = (folder as NSString).appendingPathComponent(String(rel.dropLast(".rufusadv.json".count)))
            if fm.fileExists(atPath: file), let m = load(for: file) { out.append((file, m)) }
        }
        return out.sorted { $0.1.downloadedAt > $1.1.downloadedAt }
    }
}

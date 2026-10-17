import Foundation

/// Reads the XML metadata of a Windows Imaging (WIM / ESD / SWM) file without wimlib.
public struct WIMInfo: Codable, Sendable, Equatable {
    public struct Image: Codable, Sendable, Equatable, Identifiable, Hashable {
        public var index: Int
        public var name: String
        public var displayName: String?
        public var editionID: String?
        public var arch: String?        // x86, x64, arm64
        public var major: Int?
        public var minor: Int?
        public var build: Int?
        public var spBuild: Int?
        public var languages: [String]
        public var totalBytes: UInt64?
        public var id: Int { index }

        public var title: String { displayName ?? name }
    }

    public var images: [Image]
    public var partNumber: Int
    public var totalParts: Int
    public var bootIndex: Int

    public var build: Int? { images.compactMap(\.build).max() }
    public var arch: String? { images.compactMap(\.arch).first }

    /// Human readable Windows version, e.g. "Windows 11 24H2 (26100.1742)".
    public var versionName: String? {
        guard let img = images.first, let major = img.major, let build = img.build else { return nil }
        let name: String
        if major == 10 && build >= 22000 { name = "Windows 11" }
        else if major == 10 { name = "Windows 10" }
        else if major == 6 && img.minor == 3 { name = "Windows 8.1" }
        else if major == 6 && img.minor == 2 { name = "Windows 8" }
        else if major == 6 && img.minor == 1 { name = "Windows 7" }
        else if major == 6 && img.minor == 0 { name = "Windows Vista" }
        else { name = "Windows \(major).\(img.minor ?? 0)" }
        let releases: [Int: String] = [
            10240: "1507", 10586: "1511", 14393: "1607", 15063: "1703", 16299: "1709", 17134: "1803",
            17763: "1809", 18362: "1903", 18363: "1909", 19041: "20H1–22H2", 19042: "20H2", 19043: "21H1",
            19044: "21H2", 19045: "22H2", 22000: "21H2", 22621: "22H2", 22631: "23H2", 26100: "24H2",
            26200: "25H2", 26300: "26H2",
        ]
        let rel = releases[build].map { " \($0)" } ?? ""
        let sp = img.spBuild.map { ".\($0)" } ?? ""
        return "\(name)\(rel) (build \(build)\(sp))"
    }

    public static func read(path: String) throws -> WIMInfo {
        guard let fh = FileHandle(forReadingAtPath: path) else { throw BootKitError.openFailed(path, errno) }
        defer { try? fh.close() }
        let header = [UInt8](try fh.read(upToCount: 208) ?? Data())
        guard header.count >= 208, Array(header[0..<8]) == Array("MSWIM\0\0\0".utf8) else {
            throw BootKitError.unsupportedImage("\((path as NSString).lastPathComponent) is not a WIM/ESD file")
        }
        let partNumber = Int(LE.get16(header, 0x28))
        let totalParts = Int(LE.get16(header, 0x2A))
        let xmlSize = LE.get64(header, 0x48) & 0x00FF_FFFF_FFFF_FFFF
        let xmlOffset = LE.get64(header, 0x48 + 8)
        let bootIndex = Int(LE.get32(header, 0x78))
        guard xmlSize > 0, xmlSize < 64 * Units.MB else {
            return WIMInfo(images: [], partNumber: partNumber, totalParts: totalParts, bootIndex: bootIndex)
        }
        try fh.seek(toOffset: xmlOffset)
        let xmlData = try fh.read(upToCount: Int(xmlSize)) ?? Data()
        var xml = String(data: xmlData, encoding: .utf16LittleEndian) ?? ""
        if xml.hasPrefix("\u{FEFF}") { xml.removeFirst() }
        return WIMInfo(images: parseImages(xml), partNumber: partNumber, totalParts: totalParts, bootIndex: bootIndex)
    }

    static func parseImages(_ xml: String) -> [Image] {
        var result: [Image] = []
        let imageRegex = try! NSRegularExpression(pattern: "<IMAGE\\s+INDEX=\"(\\d+)\"[^>]*>(.*?)</IMAGE>", options: [.dotMatchesLineSeparators])
        let ns = xml as NSString
        for m in imageRegex.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let index = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let body = ns.substring(with: m.range(at: 2))
            func tag(_ name: String, in s: String) -> String? {
                guard let r = s.range(of: "<\(name)>"), let e = s.range(of: "</\(name)>", range: r.upperBound..<s.endIndex) else { return nil }
                return String(s[r.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let windows = tag("WINDOWS", in: body) ?? ""
            let version = tag("VERSION", in: windows) ?? ""
            let archCode = tag("ARCH", in: windows).flatMap(Int.init)
            let arch: String?
            switch archCode {
            case 0: arch = "x86"
            case 5: arch = "arm"
            case 9: arch = "x64"
            case 12: arch = "arm64"
            default: arch = nil
            }
            var langs: [String] = []
            if let l = tag("LANGUAGES", in: windows) {
                let lr = try! NSRegularExpression(pattern: "<LANGUAGE>([^<]+)</LANGUAGE>")
                let lns = l as NSString
                langs = lr.matches(in: l, range: NSRange(location: 0, length: lns.length)).map { lns.substring(with: $0.range(at: 1)) }
            }
            result.append(Image(
                index: index,
                name: tag("NAME", in: body) ?? "Image \(index)",
                displayName: tag("DISPLAYNAME", in: body),
                editionID: tag("EDITIONID", in: windows) ?? tag("FLAGS", in: body),
                arch: arch,
                major: tag("MAJOR", in: version).flatMap(Int.init),
                minor: tag("MINOR", in: version).flatMap(Int.init),
                build: tag("BUILD", in: version).flatMap(Int.init),
                spBuild: tag("SPBUILD", in: version).flatMap(Int.init),
                languages: langs,
                totalBytes: tag("TOTALBYTES", in: body).flatMap(UInt64.init)))
        }
        return result.sorted { $0.index < $1.index }
    }
}

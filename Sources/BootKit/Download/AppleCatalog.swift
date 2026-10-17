import Foundation

/// A downloadable macOS release, straight from Apple's servers.
public struct MacOSRelease: Identifiable, Codable, Hashable, Sendable {
    public enum Payload: Codable, Hashable, Sendable {
        /// macOS 11+: a single InstallAssistant.pkg (contains the full installer app).
        case installAssistant(url: String, size: UInt64, sha1: String?)
        /// macOS 10.13 - 10.15: several packages assembled by `installer` from the .dist file.
        case distribution(distURL: String, packages: [PackageRef])
        /// OS X 10.7 - 10.12: Apple's InstallMacOSX.dmg / InstallOS.dmg direct downloads.
        case legacyDMG(url: String, size: UInt64)
    }

    public struct PackageRef: Codable, Hashable, Sendable {
        public var url: String
        public var size: UInt64
        public var sha1: String?
    }

    public var id: String
    public var name: String            // macOS Sonoma
    public var version: String         // 14.6.1
    public var build: String
    public var postDate: Date?
    public var payload: Payload
    public var isBeta: Bool

    public var totalSize: UInt64 {
        switch payload {
        case .installAssistant(_, let s, _): return s
        case .distribution(_, let p): return p.reduce(0) { $0 + $1.size }
        case .legacyDMG(_, let s): return s
        }
    }

    public var title: String { "\(name) \(version)" + (build.isEmpty ? "" : " (\(build))") }

    /// Suggested file name inside the download folder.
    public var fileName: String {
        let safe = "\(name) \(version) \(build)".trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        switch payload {
        case .installAssistant: return "\(safe)/InstallAssistant.pkg"
        case .distribution: return "\(safe)/"
        case .legacyDMG(let url, _): return "\(safe)/\((url as NSString).lastPathComponent)"
        }
    }

    public var installerInfo: MacInstallerInfo {
        let major = MacInstallerInspector.majorVersion(fromName: name) ?? version
        return MacInstallerInfo(
            appPath: nil, name: name, version: version, build: build.isEmpty ? nil : build,
            hasCreateInstallMedia: !MacInstallerInspector.versionLess(major, "10.9"),
            needsApplicationPath: MacInstallerInspector.versionLess(major, "10.14"),
            isLegacyRestore: MacInstallerInspector.versionLess(major, "10.9"),
            requiresRosetta: false,
            minimumUSBSize: MacInstallerInspector.versionLess(major, "11") ? 7_500_000_000 : 14_000_000_000)
    }
}

/// Apple software update catalog client (the same source as `softwareupdate --fetch-full-installer`).
public enum AppleCatalog {
    static let suffix = "-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-mountainlion-lion-snowleopard-leopard.merged-1.sucatalog"
    public static let publicCatalog = "https://swscan.apple.com/content/catalogs/others/index" + suffix
    public static let betaCatalog = "https://swscan.apple.com/content/catalogs/others/index-26seed" + suffix

    /// Apple's official direct links for releases that predate the catalog's full installers.
    /// Source: Apple support article "How to download and install macOS" (HT211683).
    public static let legacyReleases: [MacOSRelease] = [
        MacOSRelease(id: "legacy-10.12", name: "macOS Sierra", version: "10.12.6", build: "16G29", postDate: nil,
                     payload: .legacyDMG(url: "https://updates.cdn-apple.com/2019/cert/061-39476-20191023-48f365f4-0015-4c41-9f44-39d3d2aca067/InstallOS.dmg", size: 5_007_882_126), isBeta: false),
        MacOSRelease(id: "legacy-10.11", name: "OS X El Capitan", version: "10.11.6", build: "15G31", postDate: nil,
                     payload: .legacyDMG(url: "https://updates.cdn-apple.com/2019/cert/061-41424-20191024-218af9ec-cf50-4516-9011-228c78eda3d2/InstallMacOSX.dmg", size: 6_204_629_298), isBeta: false),
        MacOSRelease(id: "legacy-10.10", name: "OS X Yosemite", version: "10.10.5", build: "14F27", postDate: nil,
                     payload: .legacyDMG(url: "https://updates.cdn-apple.com/2019/cert/061-41343-20191023-02465f92-3ab5-4c92-bfe2-b725447a070d/InstallMacOSX.dmg", size: 5_718_074_248), isBeta: false),
        MacOSRelease(id: "legacy-10.8", name: "OS X Mountain Lion", version: "10.8.5", build: "12F45", postDate: nil,
                     payload: .legacyDMG(url: "https://updates.cdn-apple.com/2021/macos/031-0627-20210614-90D11F33-1A65-42DD-BBEA-E1D9F43A6B3F/InstallMacOSX.dmg", size: 4_449_317_520), isBeta: false),
        MacOSRelease(id: "legacy-10.7", name: "Mac OS X Lion", version: "10.7.5", build: "11G63", postDate: nil,
                     payload: .legacyDMG(url: "https://updates.cdn-apple.com/2021/macos/041-7683-20210614-E610947E-C7CE-46EB-8860-D26D71F0D3EA/InstallMacOSX.dmg", size: 4_720_237_409), isBeta: false),
    ]

    /// Fetch every full installer from the catalog (newest first), plus the legacy direct links.
    public static func fetchReleases(includeBetas: Bool = false) async throws -> [MacOSRelease] {
        var releases = try await fetch(catalog: publicCatalog, beta: false)
        if includeBetas, let betas = try? await fetch(catalog: betaCatalog, beta: true) {
            let known = Set(releases.map(\.id))
            releases += betas.filter { !known.contains($0.id) }
        }
        releases.sort {
            if $0.version != $1.version { return MacInstallerInspector.versionLess($1.version, $0.version) }
            return ($0.postDate ?? .distantPast) > ($1.postDate ?? .distantPast)
        }
        return releases + legacyReleases
    }

    static func fetch(catalog: String, beta: Bool) async throws -> [MacOSRelease] {
        let (data, resp) = try await HTTP.get(catalog, timeout: 60)
        guard resp.statusCode == 200,
              let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let products = plist["Products"] as? [String: [String: Any]] else {
            throw BootKitError.network("Apple's software catalog is unavailable (HTTP \(resp.statusCode)).")
        }
        struct Candidate { var id: String; var date: Date?; var dist: String; var payload: MacOSRelease.Payload }
        var candidates: [Candidate] = []
        for (pid, p) in products {
            guard let em = p["ExtendedMetaInfo"] as? [String: Any], em["InstallAssistantPackageIdentifiers"] != nil,
                  let pkgs = p["Packages"] as? [[String: Any]],
                  let dists = p["Distributions"] as? [String: String],
                  let dist = dists["English"] ?? dists["en"] ?? dists.values.first else { continue }
            func ref(_ d: [String: Any]) -> MacOSRelease.PackageRef? {
                guard let u = d["URL"] as? String else { return nil }
                return MacOSRelease.PackageRef(url: u, size: (d["Size"] as? NSNumber)?.uint64Value ?? 0, sha1: d["Digest"] as? String)
            }
            if let ia = pkgs.first(where: { ($0["URL"] as? String)?.hasSuffix("/InstallAssistant.pkg") == true }), let r = ref(ia) {
                candidates.append(Candidate(id: pid, date: p["PostDate"] as? Date, dist: dist,
                                            payload: .installAssistant(url: r.url, size: r.size, sha1: r.sha1)))
            } else if pkgs.contains(where: { ($0["URL"] as? String)?.hasSuffix("InstallAssistantAuto.pkg") == true }) {
                candidates.append(Candidate(id: pid, date: p["PostDate"] as? Date, dist: dist,
                                            payload: .distribution(distURL: dist, packages: pkgs.compactMap(ref))))
            }
        }
        // Resolve names / versions from the .dist files in parallel.
        return await withTaskGroup(of: MacOSRelease?.self) { group in
            for c in candidates {
                group.addTask {
                    guard let text = try? await HTTP.getString(c.dist) else { return nil }
                    let (name, version, build) = parseDist(text)
                    guard let name else { return nil }
                    return MacOSRelease(id: c.id, name: name, version: version ?? "", build: build ?? "",
                                        postDate: c.date, payload: c.payload, isBeta: beta)
                }
            }
            var out: [MacOSRelease] = []
            for await r in group { if let r { out.append(r) } }
            return out
        }
    }

    /// Extract (title, version, build) from a product .dist file.
    public static func parseDist(_ text: String) -> (String?, String?, String?) {
        func firstMatch(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
            let ns = text as NSString
            guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
            return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var title = firstMatch("\"SU_TITLE\"\\s*=\\s*\"([^\"]+)\"") ?? firstMatch("<title>([^<]+)</title>")
        if let t = title, t.hasPrefix("SU_") { title = nil }
        let version = firstMatch("<key>VERSION</key>\\s*<string>([^<]+)</string>")
        let build = firstMatch("<key>BUILD</key>\\s*<string>([^<]+)</string>")
        if title == nil, let v = version {
            let major = v.hasPrefix("10.") ? v.split(separator: ".").prefix(2).joined(separator: ".") : String(v.split(separator: ".").first ?? "")
            title = MacInstallerInspector.releaseNames.first { $0.1 == major }.map { "macOS \($0.0)" }
        }
        return (title, version, build)
    }
}

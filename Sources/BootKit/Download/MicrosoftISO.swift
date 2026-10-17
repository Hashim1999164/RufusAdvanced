import Foundation

/// Official Windows ISO downloads from Microsoft (Swift port of Rufus' Fido script).
public final class MicrosoftISO: @unchecked Sendable {

    public struct Edition: Hashable, Sendable, Identifiable {
        public var name: String
        public var productEditionIDs: [Int]   // x64 and ARM64 may have separate IDs
        public var id: String { name }
    }

    public struct Release: Hashable, Sendable, Identifiable {
        public var name: String               // "26H2 (Build 26300.9457 - 2026.09)"
        public var editions: [Edition]
        public var id: String { name }
    }

    public struct Product: Hashable, Sendable, Identifiable {
        public var name: String               // "Windows 11"
        public var pageID: String             // "windows11"
        public var releases: [Release]
        public var isUEFIShell: Bool
        public var id: String { name }
    }

    public struct Language: Hashable, Sendable, Identifiable {
        public var name: String               // "English"
        public var displayName: String        // "English (United States)"
        public var skus: [Sku]
        public var id: String { name }
        public struct Sku: Hashable, Sendable { public var sessionIndex: Int; public var skuID: String }
    }

    public struct Link: Hashable, Sendable, Identifiable {
        public var arch: String
        public var url: String
        public var fileName: String
        public var id: String { arch }
    }

    static let orgID = "y6jn8c31"
    static let profileID = "606624d44113"
    static let instanceID = "560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175"
    static let fidoURL = "https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1"

    /// Built-in catalog (kept in sync with Fido). `refreshCatalog()` can update it from upstream.
    public private(set) var products: [Product] = [
        Product(name: "Windows 11", pageID: "windows11", releases: [
            Release(name: "26H2 (Build 26300.9457 - 2026.09)", editions: [
                Edition(name: "Windows 11 Home/Pro/Edu", productEditionIDs: [3813, 3816]),
                Edition(name: "Windows 11 Home China", productEditionIDs: [3814, 3817]),
                Edition(name: "Windows 11 Pro China", productEditionIDs: [3815, 3818]),
            ]),
        ], isUEFIShell: false),
        Product(name: "Windows 10", pageID: "Windows10ISO", releases: [
            Release(name: "22H2 v1 (Build 19045.2965 - 2023.05)", editions: [
                Edition(name: "Windows 10 Home/Pro/Edu", productEditionIDs: [2618]),
                Edition(name: "Windows 10 Home China", productEditionIDs: [2378]),
            ]),
        ], isUEFIShell: false),
        Product(name: "UEFI Shell 2.2", pageID: "UEFI_SHELL 2.2", releases: [
            "26H2", "26H1", "25H2", "25H1", "24H2", "24H1", "23H2", "23H1", "22H2", "22H1", "21H2", "21H1", "20H2",
        ].map { Release(name: $0, editions: [Edition(name: "Release", productEditionIDs: [0]), Edition(name: "Debug", productEditionIDs: [1])]) },
        isUEFIShell: true),
    ]

    private var sessionIDs: [String] = []
    public var locale = "en-US"

    public init() {}

    /// Try to refresh the release table from the upstream Fido script (best effort).
    public func refreshCatalog() async {
        guard let text = try? await HTTP.getString(Self.fidoURL),
              let parsed = Self.parseFido(text), !parsed.isEmpty else { return }
        // Keep our UEFI Shell entry if the parser missed it.
        products = parsed + products.filter { p in p.isUEFIShell && !parsed.contains { $0.isUEFIShell } }
        logDebug("Windows release table refreshed from Fido (\(parsed.count) products)")
    }

    /// Parse the `$WindowsVersions = @( ... )` table of Fido.ps1.
    static func parseFido(_ text: String) -> [Product]? {
        guard let start = text.range(of: "$WindowsVersions = @("),
              let end = text.range(of: "#endregion", range: start.upperBound..<text.endIndex) else { return nil }
        let body = text[start.upperBound..<end.lowerBound]
        let productRe = try! NSRegularExpression(pattern: #"@\("([^"]+)",\s*"([^"]+)"\)"#)
        let releaseRe = try! NSRegularExpression(pattern: #"^\s*"([^"]+)",\s*$"#, options: [.anchorsMatchLines])
        let editionRe = try! NSRegularExpression(pattern: #"@\("([^"]+)",\s*(?:@\(([\d,\s]+)\)|(\d+))\)"#)
        var products: [Product] = []
        for line in body.split(separator: "\n").map(String.init) {
            let ns = line as NSString
            let r = NSRange(location: 0, length: ns.length)
            if let m = productRe.firstMatch(in: line, range: r), line.contains("\", \""), !line.contains("@(\(Character("\"")))") {
                let name = ns.substring(with: m.range(at: 1)), page = ns.substring(with: m.range(at: 2))
                if page.hasPrefix("windows") || page.hasPrefix("Windows") || page.hasPrefix("UEFI_SHELL") {
                    products.append(Product(name: name, pageID: page, releases: [], isUEFIShell: page.hasPrefix("UEFI_SHELL")))
                    continue
                }
            }
            if let m = releaseRe.firstMatch(in: line, range: r), !products.isEmpty {
                products[products.count - 1].releases.append(Release(name: ns.substring(with: m.range(at: 1)), editions: []))
                continue
            }
            if let m = editionRe.firstMatch(in: line, range: r), !products.isEmpty, !products[products.count - 1].releases.isEmpty {
                let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let idsText = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : ns.substring(with: m.range(at: 3))
                let ids = idsText.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                let pi = products.count - 1, ri = products[pi].releases.count - 1
                products[pi].releases[ri].editions.append(Edition(name: name, productEditionIDs: ids))
            }
        }
        let valid = products.filter { !$0.releases.isEmpty && $0.releases.allSatisfy { !$0.editions.isEmpty } }
        return valid.isEmpty ? nil : valid
    }

    // MARK: Microsoft API

    /// Retrieve available languages for an edition (each language may map to one SKU per architecture).
    public func languages(product: Product, edition: Edition) async throws -> [Language] {
        if product.isUEFIShell {
            return [Language(name: "en-us", displayName: "English (US)", skus: [])]
        }
        sessionIDs = []
        var ordered: [String] = []
        var map: [String: Language] = [:]
        for (sessionIndex, editionID) in edition.productEditionIDs.enumerated() {
            let sid = UUID().uuidString.lowercased()
            sessionIDs.append(sid)
            try await whitelist(session: sid)
            let url = "https://www.microsoft.com/software-download-connector/api/getskuinformationbyproductedition?profile=\(Self.profileID)&productEditionId=\(editionID)&SKU=undefined&friendlyFileName=undefined&Locale=\(locale)&sessionID=\(sid)"
            var lastError: Error?
            for attempt in 0..<3 {
                if attempt > 0 { try await Task.sleep(nanoseconds: 2_000_000_000) }
                do {
                    guard let json = try await HTTP.getJSON(url) as? [String: Any] else { continue }
                    if let errs = json["Errors"] as? [[String: Any]], let first = errs.first {
                        lastError = BootKitError.network(first["Value"] as? String ?? "Microsoft returned an error")
                        continue
                    }
                    let skus = json["Skus"] as? [[String: Any]] ?? []
                    for s in skus {
                        guard let lang = s["Language"] as? String, let id = s["Id"] as? String else { continue }
                        if map[lang] == nil {
                            ordered.append(lang)
                            map[lang] = Language(name: lang, displayName: s["LocalizedLanguage"] as? String ?? lang, skus: [])
                        }
                        map[lang]!.skus.append(Language.Sku(sessionIndex: sessionIndex, skuID: id))
                    }
                    lastError = nil
                    break
                } catch { lastError = error }
            }
            if let lastError { throw lastError }
        }
        guard !ordered.isEmpty else { throw BootKitError.network("Microsoft did not return any language for this edition.") }
        return ordered.compactMap { map[$0] }
    }

    /// Retrieve the (time limited, 24h) ISO download links for a language.
    public func links(product: Product, release: Release, edition: Edition, language: Language) async throws -> [Link] {
        if product.isUEFIShell {
            let tag = release.name.split(separator: " ").first.map(String.init) ?? release.name
            let shellVersion = product.pageID.split(separator: " ").last.map(String.init) ?? "2.2"
            let kind = edition.productEditionIDs.first == 1 ? "DEBUG" : "RELEASE"
            let file = "UEFI-Shell-\(shellVersion)-\(tag)-\(kind).iso"
            return [Link(arch: "x64, ia32, aa64, riscv64, loongarch64", url: "https://github.com/pbatard/UEFI-Shell/releases/download/\(tag)/\(file)", fileName: file)]
        }
        var links: [Link] = []
        for sku in language.skus {
            guard sku.sessionIndex < sessionIDs.count else { continue }
            let url = "https://www.microsoft.com/software-download-connector/api/GetProductDownloadLinksBySku?profile=\(Self.profileID)&productEditionId=undefined&SKU=\(sku.skuID)&friendlyFileName=undefined&Locale=\(locale)&sessionID=\(sessionIDs[sku.sessionIndex])"
            guard let json = try await HTTP.getJSON(url, headers: ["Referer": "https://www.microsoft.com/software-download/windows11"]) as? [String: Any] else {
                throw BootKitError.network("Could not retrieve download links from Microsoft.")
            }
            if let errs = json["Errors"] as? [[String: Any]], let first = errs.first {
                if (first["Type"] as? Int) == 9 {
                    throw BootKitError.network("Microsoft blocked this download request (error 715-123130). This usually happens when using a VPN or after too many requests. Wait a while, or use 'Download with browser'.")
                }
                throw BootKitError.network(first["Value"] as? String ?? "Microsoft returned an error")
            }
            for opt in json["ProductDownloadOptions"] as? [[String: Any]] ?? [] {
                guard let uri = opt["Uri"] as? String else { continue }
                let arch: String
                switch opt["DownloadType"] as? Int {
                case 0: arch = "x86"
                case 1: arch = "x64"
                case 2: arch = "ARM64"
                default: arch = "Unknown"
                }
                let file = URL(string: uri)?.lastPathComponent ?? "Windows.iso"
                links.append(Link(arch: arch, url: uri, fileName: file))
            }
        }
        guard !links.isEmpty else { throw BootKitError.network("Microsoft did not return any download link.") }
        return links
    }

    /// Microsoft's anti-bot "protection" requires whitelisting each session ID first.
    private func whitelist(session sid: String) async throws {
        _ = try await HTTP.get("https://vlscppe.microsoft.com/tags?org_id=\(Self.orgID)&session_id=\(sid)")
        let js = try await HTTP.getString("https://ov-df.microsoft.com/mdt.js?instanceId=\(Self.instanceID)&PageId=si&session_id=\(sid)")
        func capture(_ pattern: String) -> String? {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            let ns = js as NSString
            guard let m = re.firstMatch(in: js, range: NSRange(location: 0, length: ns.length)) else { return nil }
            return ns.substring(with: m.range(at: 1))
        }
        guard let w = capture("[?&]w=([A-F0-9]+)"), let rticks = capture("rticks=\"\\+?(\\d+)") else {
            throw BootKitError.network("Could not complete Microsoft's download session handshake.")
        }
        let mdt = Int(Date().timeIntervalSince1970 * 1000)
        _ = try await HTTP.get("https://ov-df.microsoft.com/?session_id=\(sid)&CustomerId=\(Self.instanceID)&PageId=si&w=\(w)&mdt=\(mdt)&rticks=\(rticks)")
    }

    /// Browser fallback page.
    public static func browserURL(for product: Product) -> URL {
        URL(string: product.pageID == "Windows10ISO" ? "https://www.microsoft.com/software-download/windows10ISO" : "https://www.microsoft.com/software-download/windows11")!
    }
}

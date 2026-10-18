import Foundation
import AppKit
import CryptoKit
import BootKit

/// Operating system logos: detected from the selected image, fetched once from Wikimedia Commons
/// (the official logo files referenced by each product's Wikidata entry) and cached on disk.
/// macOS installers use the icon shipped inside the installer app when it is available.
@MainActor
final class LogoProvider: ObservableObject {
    static let shared = LogoProvider()

    /// key → Wikimedia Commons file (Wikidata "small logo or icon" / "icon" / "logo image").
    static let commonsFiles: [String: String] = [
        "ubuntu": "Logo-ubuntu no(r)-black orange-hex.svg",
        "kubuntu": "Kubuntu 2024 Logo.svg",
        "xubuntu": "Xubuntu logo and wordmark.svg",
        "lubuntu": "Lubuntu logo only.svg",
        "ubuntumate": "Ubuntu MATE logo.svg",
        "mint": "Linux Mint logo without wordmark.svg",
        "debian": "Openlogo-debianV2.svg",
        "fedora": "Fedora-logo.svg",
        "arch": "Arch Linux \"Crystal\" icon.svg",
        "kali": "Kali Linux 2.0 wordmark.svg",
        "popos": "Pop! OS Icon.svg",
        "rocky": "Rocky Linux wordmark.svg",
        "alma": "AlmaLinux Icon Logo.png",
        "opensuse": "OpenSUSE Logo.svg",
        "tails": "Tails-logo-flat.svg",
        "alpine": "Alpine Linux.svg",
        "proxmox": "Logo Proxmox.svg",
        "manjaro": "Logo manjaro rounded 2022.svg",
        "centos": "Centos-logo-2022.svg",
        "elementary": "Elementary OS logo.svg",
        "zorin": "Zorin Logomark.svg",
        "endeavouros": "EndeavourOS Logo.svg",
        "nixos": "Nix snowflake.svg",
        "linux": "Tux.svg",
        "freebsd": "FreeBSD textlogo.svg",
        "freedos": "FreeDOS logo4 2010.svg",
        "windows11": "Windows 11 logo.svg",
        "windows10": "Windows 10 Logo.svg",
        "windows": "Windows logo - 2012.svg",
        "tahoe": "MacOS Tahoe Logo 2025.svg",
        "sequoia": "MacOS Sequoia Logo 2024.svg",
        "sonoma": "MacOS Sonoma - logo.svg",
        "ventura": "MacOS Ventura wordmark.svg",
        "monterey": "MacOS Monterey wordmark.svg",
        "bigsur": "MacOS Big Sur wordmark 2.svg",
        "catalina": "MacOS Catalina wordmark.svg",
        "mojave": "MacOS Mojave wordmark.svg",
        "highsierra": "MacOS High Sierra wordmark.svg",
        "sierra": "MacOS Sierra wordmark.svg",
        "elcapitan": "OS X El Capitan logo.svg",
        "macos": "MacOS wordmark.svg",
    ]

    @Published private(set) var images: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    /// Keys that could not be loaded, and when to try again (network errors, HTTP 429).
    private var retryAfter: [String: Date] = [:]
    /// Logos are fetched one at a time (Wikimedia rate-limits bursts).
    private var queue: [String] = []
    private var fetching = false

    private let cacheDir: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RufusAdvanced/logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    /// The logo for `key` if it is available now; starts loading it otherwise (views update when it arrives).
    func image(_ key: String) -> NSImage? {
        if let i = images[key] { return i }
        load(key)
        return nil
    }

    private func load(_ key: String) {
        guard !inFlight.contains(key) else { return }
        if let t = retryAfter[key], t > Date() { return }
        let file = cacheDir.appendingPathComponent(key + ".png")
        if let img = NSImage(contentsOf: file) { images[key] = img; return }
        if key.hasPrefix("/") {
            // An installer app: its own icon.
            if let img = Self.installerIcon(appPath: key) { images[key] = img } else { retryAfter[key] = .distantFuture }
            return
        }
        guard Self.commonsFiles[key] != nil else { retryAfter[key] = .distantFuture; return }
        inFlight.insert(key)
        queue.append(key)
        pump()
    }

    private func pump() {
        guard !fetching, !queue.isEmpty else { return }
        fetching = true
        let key = queue.removeFirst()
        let name = Self.commonsFiles[key]!
        let file = cacheDir.appendingPathComponent(key + ".png")
        Task.detached(priority: .utility) {
            let data = await Self.fetch(commonsFile: name)
            await MainActor.run {
                self.inFlight.remove(key)
                if let data, let img = NSImage(data: data) {
                    try? data.write(to: file)
                    self.images[key] = img
                } else {
                    self.retryAfter[key] = Date().addingTimeInterval(300)   // keep the fallback tile for now
                }
                self.fetching = false
                self.pump()
            }
        }
    }

    /// 250 px PNG rendering of a Commons file (falls back to the original for bitmap files).
    nonisolated static func fetch(commonsFile: String) async -> Data? {
        for url in thumbnailURLs(commonsFile) {
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.setValue("RufusAdvanced/\(BootKit.version) (https://github.com/Hashim1999164/RufusAdvanced)", forHTTPHeaderField: "User-Agent")
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty {
                return data
            }
        }
        return nil
    }

    nonisolated static func thumbnailURLs(_ commonsFile: String) -> [URL] {
        let name = commonsFile.replacingOccurrences(of: " ", with: "_")
        let md5 = Insecure.MD5.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "\"?#%")
        let enc = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        let dir = "\(md5.prefix(1))/\(md5.prefix(2))"
        let base = "https://upload.wikimedia.org/wikipedia/commons"
        let thumbName = name.lowercased().hasSuffix(".svg") ? "250px-\(enc).png" : "250px-\(enc)"
        var urls = [URL(string: "\(base)/thumb/\(dir)/\(enc)/\(thumbName)")]
        if !name.lowercased().hasSuffix(".svg") { urls.append(URL(string: "\(base)/\(dir)/\(enc)")) }
        return urls.compactMap { $0 }
    }

    /// The icon shipped inside an "Install macOS …" app.
    nonisolated static func installerIcon(appPath: String) -> NSImage? {
        for f in ["ProductPageIcon.icns", "InstallAssistant.icns", "Install Mac OS X.icns"] {
            if let img = NSImage(contentsOfFile: appPath + "/Contents/Resources/" + f) { return img }
        }
        guard FileManager.default.fileExists(atPath: appPath) else { return nil }
        return NSWorkspace.shared.icon(forFile: appPath)
    }

    // MARK: Detection

    /// Logo key for an image (an app path for macOS installer apps).
    nonisolated static func key(for image: ImageReport) -> String? {
        switch image.family {
        case .macOS:
            if image.kind == .macInstallerApp { return image.path }
            return macOSKey(image.mac?.name ?? image.displayName)
        case .windows:
            let n = (image.displayName + " " + image.fileName).lowercased()
            if n.contains("11") || n.contains("win11") { return "windows11" }
            if n.contains("10") || n.contains("win10") { return "windows10" }
            return "windows"
        case .freeDOS:
            return "freedos"
        default:
            let text = [image.label, image.fileName, image.displayName].joined(separator: " ").lowercased()
            if let k = linuxKey(text) { return k }
            return image.family == .linux ? "linux" : nil
        }
    }

    nonisolated static func macOSKey(_ name: String) -> String {
        let n = name.lowercased().replacingOccurrences(of: " ", with: "")
        // The real icon when the matching "Install macOS …" app is on this Mac.
        for app in MacInstallerLibrary.installerApps() {
            let a = (app as NSString).lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "install", with: "").replacingOccurrences(of: ".app", with: "")
                .replacingOccurrences(of: "macos", with: "").replacingOccurrences(of: "osx", with: "")
            if !a.isEmpty && n.contains(a) { return app }
        }
        for k in ["tahoe", "sequoia", "sonoma", "ventura", "monterey", "bigsur", "catalina", "mojave", "highsierra", "elcapitan"] where n.contains(k) {
            return k
        }
        if n.contains("sierra") { return "sierra" }
        return "macos"
    }

    /// Linux distribution from an ISO label / file name / display name.
    nonisolated static func linuxKey(_ text: String) -> String? {
        let t = text.replacingOccurrences(of: "_", with: "-")
        let rules: [(String, [String])] = [
            ("kubuntu", ["kubuntu"]), ("xubuntu", ["xubuntu"]), ("lubuntu", ["lubuntu"]),
            ("ubuntumate", ["ubuntu-mate", "ubuntu mate"]), ("popos", ["pop-os", "pop!", "popos"]),
            ("mint", ["linuxmint", "linux mint", "mint-"]), ("ubuntu", ["ubuntu"]), ("kali", ["kali"]),
            ("debian", ["debian"]), ("fedora", ["fedora"]), ("manjaro", ["manjaro"]), ("endeavouros", ["endeavour"]),
            ("arch", ["archlinux", "arch-", "arch linux"]), ("rocky", ["rocky"]), ("alma", ["almalinux", "alma-"]),
            ("centos", ["centos"]), ("opensuse", ["opensuse", "suse"]), ("tails", ["tails"]), ("alpine", ["alpine"]),
            ("proxmox", ["proxmox"]), ("elementary", ["elementary"]), ("zorin", ["zorin"]), ("nixos", ["nixos"]),
            ("freebsd", ["freebsd"]), ("freedos", ["freedos", "fd13", "fd14"]),
        ]
        for (key, needles) in rules where needles.contains(where: { t.contains($0) }) { return key }
        return nil
    }
}

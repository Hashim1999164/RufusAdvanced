import Foundation

/// A concrete, verified downloadable Linux image.
public struct LinuxImage: Identifiable, Hashable, Sendable, Codable {
    public var title: String          // "Ubuntu 26.04.1 Desktop"
    public var version: String
    public var arch: String           // amd64 / arm64
    public var url: String
    public var sha256: String?
    public var size: UInt64?
    public var id: String { url }
    public var fileName: String { URL(string: url)?.lastPathComponent ?? "linux.iso" }
}

/// A distribution flavour that resolves its latest images at runtime.
public struct LinuxEdition: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var arch: String
    public static func == (a: LinuxEdition, b: LinuxEdition) -> Bool { a.id == b.id }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

public struct LinuxDistro: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var homepage: String
    public var editions: [LinuxEdition]
    public var supportsPersistence: Bool
}

/// Catalog of popular distributions. Every image is resolved from the project's official
/// checksum list or release API, so URLs are always current and downloads are SHA-256 verified.
public enum LinuxCatalog {

    public static let distros: [LinuxDistro] = [
        LinuxDistro(id: "ubuntu", name: "Ubuntu", summary: "The most popular desktop Linux. Supports persistence.", homepage: "https://ubuntu.com",
                    editions: [.init(id: "ubuntu-desktop-amd64", name: "Desktop", arch: "amd64"),
                               .init(id: "ubuntu-server-amd64", name: "Server", arch: "amd64"),
                               .init(id: "ubuntu-desktop-arm64", name: "Desktop", arch: "arm64"),
                               .init(id: "ubuntu-server-arm64", name: "Server", arch: "arm64")], supportsPersistence: true),
        LinuxDistro(id: "kubuntu", name: "Kubuntu", summary: "Ubuntu with KDE Plasma.", homepage: "https://kubuntu.org",
                    editions: [.init(id: "flavor-kubuntu-desktop", name: "Desktop", arch: "amd64")], supportsPersistence: true),
        LinuxDistro(id: "xubuntu", name: "Xubuntu", summary: "Ubuntu with the light Xfce desktop.", homepage: "https://xubuntu.org",
                    editions: [.init(id: "flavor-xubuntu-desktop", name: "Desktop", arch: "amd64"),
                               .init(id: "flavor-xubuntu-minimal", name: "Minimal", arch: "amd64")], supportsPersistence: true),
        LinuxDistro(id: "lubuntu", name: "Lubuntu", summary: "Lightweight Ubuntu with LXQt.", homepage: "https://lubuntu.me",
                    editions: [.init(id: "flavor-lubuntu-desktop", name: "Desktop", arch: "amd64")], supportsPersistence: true),
        LinuxDistro(id: "ubuntu-mate", name: "Ubuntu MATE", summary: "Ubuntu with the MATE desktop.", homepage: "https://ubuntu-mate.org",
                    editions: [.init(id: "flavor-ubuntu-mate-desktop", name: "Desktop", arch: "amd64")], supportsPersistence: true),
        LinuxDistro(id: "mint", name: "Linux Mint", summary: "Friendly, Ubuntu based desktop. Supports persistence.", homepage: "https://linuxmint.com",
                    editions: [.init(id: "mint-cinnamon", name: "Cinnamon", arch: "amd64"),
                               .init(id: "mint-mate", name: "MATE", arch: "amd64"),
                               .init(id: "mint-xfce", name: "Xfce", arch: "amd64")], supportsPersistence: true),
        LinuxDistro(id: "debian", name: "Debian", summary: "The universal operating system. Live images support persistence.", homepage: "https://debian.org",
                    editions: [.init(id: "debian-netinst-amd64", name: "Net installer", arch: "amd64"),
                               .init(id: "debian-netinst-arm64", name: "Net installer", arch: "arm64"),
                               .init(id: "debian-live-gnome", name: "Live GNOME", arch: "amd64"),
                               .init(id: "debian-live-kde", name: "Live KDE", arch: "amd64"),
                               .init(id: "debian-live-xfce", name: "Live Xfce", arch: "amd64"),
                               .init(id: "debian-live-cinnamon", name: "Live Cinnamon", arch: "amd64"),
                               .init(id: "debian-live-standard", name: "Live (no desktop)", arch: "amd64")], supportsPersistence: true),
        LinuxDistro(id: "fedora", name: "Fedora", summary: "Cutting edge, by the Fedora Project.", homepage: "https://fedoraproject.org",
                    editions: [.init(id: "fedora-Workstation-x86_64", name: "Workstation", arch: "x86_64"),
                               .init(id: "fedora-KDE-x86_64", name: "KDE Plasma", arch: "x86_64"),
                               .init(id: "fedora-Server-x86_64", name: "Server", arch: "x86_64"),
                               .init(id: "fedora-Everything-x86_64", name: "Everything (netinst)", arch: "x86_64"),
                               .init(id: "fedora-Workstation-aarch64", name: "Workstation", arch: "aarch64")], supportsPersistence: false),
        LinuxDistro(id: "arch", name: "Arch Linux", summary: "Lightweight, rolling release.", homepage: "https://archlinux.org",
                    editions: [.init(id: "arch-x86_64", name: "Installer", arch: "x86_64")], supportsPersistence: false),
        LinuxDistro(id: "kali", name: "Kali Linux", summary: "Penetration testing distribution.", homepage: "https://kali.org",
                    editions: [.init(id: "kali-installer-amd64", name: "Installer", arch: "amd64"),
                               .init(id: "kali-live-amd64", name: "Live", arch: "amd64"),
                               .init(id: "kali-installer-arm64", name: "Installer", arch: "arm64")], supportsPersistence: true),
        LinuxDistro(id: "popos", name: "Pop!_OS", summary: "System76's desktop with COSMIC.", homepage: "https://system76.com/pop",
                    editions: [.init(id: "popos-intel", name: "Intel/AMD", arch: "amd64"),
                               .init(id: "popos-nvidia", name: "NVIDIA", arch: "amd64")], supportsPersistence: false),
        LinuxDistro(id: "rocky", name: "Rocky Linux", summary: "Enterprise Linux, RHEL compatible.", homepage: "https://rockylinux.org",
                    editions: [.init(id: "rocky-10-dvd", name: "10 DVD", arch: "x86_64"),
                               .init(id: "rocky-10-minimal", name: "10 Minimal", arch: "x86_64"),
                               .init(id: "rocky-9-dvd", name: "9 DVD", arch: "x86_64"),
                               .init(id: "rocky-9-minimal", name: "9 Minimal", arch: "x86_64")], supportsPersistence: false),
        LinuxDistro(id: "alma", name: "AlmaLinux", summary: "Enterprise Linux, RHEL compatible.", homepage: "https://almalinux.org",
                    editions: [.init(id: "alma-10-dvd", name: "10 DVD", arch: "x86_64"),
                               .init(id: "alma-10-minimal", name: "10 Minimal", arch: "x86_64"),
                               .init(id: "alma-9-dvd", name: "9 DVD", arch: "x86_64"),
                               .init(id: "alma-9-minimal", name: "9 Minimal", arch: "x86_64")], supportsPersistence: false),
        LinuxDistro(id: "opensuse", name: "openSUSE Tumbleweed", summary: "Rolling release by SUSE.", homepage: "https://opensuse.org",
                    editions: [.init(id: "tumbleweed-dvd", name: "DVD", arch: "x86_64"),
                               .init(id: "tumbleweed-netinstall", name: "Network installer", arch: "x86_64")], supportsPersistence: false),
        LinuxDistro(id: "tails", name: "Tails", summary: "Amnesic, privacy focused live system (USB image).", homepage: "https://tails.net",
                    editions: [.init(id: "tails-img", name: "USB image", arch: "amd64")], supportsPersistence: false),
        LinuxDistro(id: "alpine", name: "Alpine Linux", summary: "Small, security oriented.", homepage: "https://alpinelinux.org",
                    editions: [.init(id: "alpine-standard-x86_64", name: "Standard", arch: "x86_64"),
                               .init(id: "alpine-extended-x86_64", name: "Extended", arch: "x86_64"),
                               .init(id: "alpine-virt-x86_64", name: "Virtual", arch: "x86_64"),
                               .init(id: "alpine-standard-aarch64", name: "Standard", arch: "aarch64")], supportsPersistence: false),
        LinuxDistro(id: "proxmox", name: "Proxmox VE", summary: "Virtualization platform installer.", homepage: "https://proxmox.com",
                    editions: [.init(id: "proxmox-ve", name: "VE installer", arch: "amd64")], supportsPersistence: false),
    ]

    /// Resolve the downloadable images for an edition (newest first).
    public static func resolve(_ edition: LinuxEdition) async throws -> [LinuxImage] {
        let id = edition.id
        switch true {
        case id.hasPrefix("ubuntu-"): return try await ubuntu(edition)
        case id.hasPrefix("flavor-"): return try await ubuntuFlavor(edition)
        case id.hasPrefix("mint-"): return try await mint(edition)
        case id.hasPrefix("debian-"): return try await debian(edition)
        case id.hasPrefix("fedora-"): return try await fedora(edition)
        case id == "arch-x86_64": return try await arch()
        case id.hasPrefix("kali-"): return try await kali(edition)
        case id.hasPrefix("popos-"): return try await popOS(edition)
        case id.hasPrefix("rocky-"), id.hasPrefix("alma-"): return try await enterprise(edition)
        case id.hasPrefix("tumbleweed-"): return try await tumbleweed(edition)
        case id == "tails-img": return try await tails()
        case id.hasPrefix("alpine-"): return try await alpine(edition)
        case id == "proxmox-ve": return try await proxmox()
        default: throw BootKitError.unsupported("Unknown edition \(id)")
        }
    }

    // MARK: Helpers

    /// Parse "<hash> [*]<file>" and "SHA256 (<file>) = <hash>" checksum lists.
    public static func parseChecksums(_ text: String) -> [(file: String, hash: String)] {
        var out: [(String, String)] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("SHA256 ("), let close = line.range(of: ") = ") {
                let file = String(line[line.index(line.startIndex, offsetBy: 8)..<close.lowerBound])
                out.append((file, String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)))
                continue
            }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2, parts[0].count == 64, parts[0].allSatisfy(\.isHexDigit) else { continue }
            var file = parts[1].trimmingCharacters(in: .whitespaces)
            if file.hasPrefix("*") { file.removeFirst() }
            out.append((file, String(parts[0]).lowercased()))
        }
        return out
    }

    static func versionSort(_ a: String, _ b: String) -> Bool { a.compare(b, options: .numeric) == .orderedDescending }

    // MARK: Resolvers

    static func supportedUbuntuVersions() async throws -> [String] {
        let text = try await HTTP.getString("https://changelogs.ubuntu.com/meta-release")
        var versions: [String] = []
        var current: String?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("Version: ") { current = String(line.dropFirst(9)).replacingOccurrences(of: " LTS", with: "") }
            if line.hasPrefix("Supported: 1"), let v = current {
                // "26.04.1" → release directory "26.04"
                versions.append(v.split(separator: ".").prefix(2).joined(separator: "."))
            }
        }
        return Array(Set(versions)).sorted(by: versionSort)
    }

    static func ubuntu(_ e: LinuxEdition) async throws -> [LinuxImage] {
        let kind = e.id.contains("server") ? "live-server" : "desktop"
        var images: [LinuxImage] = []
        for v in try await supportedUbuntuVersions().prefix(3) {
            let base = e.arch == "amd64" ? "https://releases.ubuntu.com/\(v)/" : "https://cdimage.ubuntu.com/releases/\(v)/release/"
            guard let sums = try? await HTTP.getString(base + "SHA256SUMS") else { continue }
            let files = parseChecksums(sums).filter { $0.file.hasPrefix("ubuntu-") && $0.file.hasSuffix("-\(kind)-\(e.arch).iso") }
            guard let best = files.sorted(by: { versionSort($0.file, $1.file) }).first else { continue }
            let ver = best.file.replacingOccurrences(of: "ubuntu-", with: "").replacingOccurrences(of: "-\(kind)-\(e.arch).iso", with: "")
            images.append(LinuxImage(title: "Ubuntu \(ver) \(e.name)", version: ver, arch: e.arch, url: base + best.file, sha256: best.hash))
        }
        guard !images.isEmpty else { throw BootKitError.network("No Ubuntu \(e.name) image found.") }
        return images
    }

    static func ubuntuFlavor(_ e: LinuxEdition) async throws -> [LinuxImage] {
        // flavor-<name>-<kind>
        let parts = e.id.dropFirst("flavor-".count).split(separator: "-")
        let kind = String(parts.last!)
        let flavor = parts.dropLast().joined(separator: "-")
        var images: [LinuxImage] = []
        for v in try await supportedUbuntuVersions().prefix(2) {
            let base = "https://cdimage.ubuntu.com/\(flavor)/releases/\(v)/release/"
            guard let sums = try? await HTTP.getString(base + "SHA256SUMS") else { continue }
            let files = parseChecksums(sums).filter { $0.file.hasSuffix("-\(kind)-amd64.iso") }
            guard let best = files.sorted(by: { versionSort($0.file, $1.file) }).first else { continue }
            let ver = best.file.replacingOccurrences(of: "\(flavor)-", with: "").replacingOccurrences(of: "-\(kind)-amd64.iso", with: "")
            images.append(LinuxImage(title: "\(flavor.capitalized) \(ver)", version: ver, arch: "amd64", url: base + best.file, sha256: best.hash))
        }
        guard !images.isEmpty else { throw BootKitError.network("No \(flavor) image found.") }
        return images
    }

    static func mint(_ e: LinuxEdition) async throws -> [LinuxImage] {
        let mirror = "https://mirrors.kernel.org/linuxmint/stable/"
        let index = try await HTTP.getString(mirror)
        let re = try NSRegularExpression(pattern: "href=\"([0-9]+(?:\\.[0-9]+)*)/\"")
        let ns = index as NSString
        let versions = re.matches(in: index, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        let desk = e.id.replacingOccurrences(of: "mint-", with: "")
        var images: [LinuxImage] = []
        for v in Array(Set(versions)).sorted(by: versionSort).prefix(2) {
            guard let sums = try? await HTTP.getString(mirror + v + "/sha256sum.txt") else { continue }
            if let f = parseChecksums(sums).first(where: { $0.file == "linuxmint-\(v)-\(desk)-64bit.iso" }) {
                images.append(LinuxImage(title: "Linux Mint \(v) \(e.name)", version: v, arch: "amd64", url: mirror + v + "/" + f.file, sha256: f.hash))
            }
        }
        guard !images.isEmpty else { throw BootKitError.network("No Linux Mint image found.") }
        return images
    }

    static func debian(_ e: LinuxEdition) async throws -> [LinuxImage] {
        let base: String
        let match: (String) -> Bool
        if e.id.hasPrefix("debian-netinst") {
            base = "https://cdimage.debian.org/debian-cd/current/\(e.arch)/iso-cd/"
            match = { $0.hasPrefix("debian-") && !$0.hasPrefix("debian-edu") && !$0.hasPrefix("debian-mac") && $0.hasSuffix("-\(e.arch)-netinst.iso") }
        } else {
            let desk = e.id.replacingOccurrences(of: "debian-live-", with: "")
            base = "https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/"
            match = { $0.hasPrefix("debian-live-") && $0.hasSuffix("-amd64-\(desk).iso") }
        }
        let sums = try await HTTP.getString(base + "SHA256SUMS")
        guard let f = parseChecksums(sums).first(where: { match($0.file) }) else { throw BootKitError.network("No Debian image found.") }
        let ver = f.file.split(separator: "-").first(where: { $0.first?.isNumber == true }).map(String.init) ?? ""
        return [LinuxImage(title: "Debian \(ver) \(e.name)", version: ver, arch: e.arch, url: base + f.file, sha256: f.hash)]
    }

    static func fedora(_ e: LinuxEdition) async throws -> [LinuxImage] {
        let parts = e.id.split(separator: "-")
        let variant = String(parts[1]), arch = String(parts[2])
        guard let list = try await HTTP.getJSON("https://fedoraproject.org/releases.json") as? [[String: Any]] else {
            throw BootKitError.network("Fedora release list unavailable.")
        }
        let isos = list.filter {
            ($0["variant"] as? String) == variant && ($0["arch"] as? String) == arch &&
            ($0["link"] as? String)?.hasSuffix(".iso") == true &&
            !(($0["link"] as? String) ?? "").contains("netinst") == (variant != "Everything")
        }
        var images: [LinuxImage] = []
        for x in isos {
            let ver = x["version"] as? String ?? ""
            images.append(LinuxImage(title: "Fedora \(ver) \(e.name)", version: ver, arch: arch, url: x["link"] as! String,
                                     sha256: x["sha256"] as? String, size: (x["size"] as? String).flatMap(UInt64.init)))
        }
        images.sort { a, b in
            let ab = a.version.contains("Beta"), bb = b.version.contains("Beta")
            if ab != bb { return !ab }
            return versionSort(a.version, b.version)
        }
        guard !images.isEmpty else { throw BootKitError.network("No Fedora \(variant) image found.") }
        return Array(images.prefix(3))
    }

    static func arch() async throws -> [LinuxImage] {
        guard let json = try await HTTP.getJSON("https://archlinux.org/releng/releases/json/") as? [String: Any],
              let releases = json["releases"] as? [[String: Any]],
              let r = releases.first(where: { ($0["available"] as? Bool) == true }),
              let ver = r["version"] as? String else { throw BootKitError.network("Arch release list unavailable.") }
        return [LinuxImage(title: "Arch Linux \(ver)", version: ver, arch: "x86_64",
                           url: "https://geo.mirror.pkgbuild.com/iso/\(ver)/archlinux-\(ver)-x86_64.iso",
                           sha256: r["sha256_sum"] as? String)]
    }

    static func kali(_ e: LinuxEdition) async throws -> [LinuxImage] {
        let base = "https://cdimage.kali.org/current/"
        let kind = e.id.contains("live") ? "live" : "installer"
        let sums = try await HTTP.getString(base + "SHA256SUMS")
        guard let f = parseChecksums(sums).first(where: { $0.file.hasSuffix("-\(kind)-\(e.arch).iso") }) else { throw BootKitError.network("No Kali image found.") }
        let ver = f.file.replacingOccurrences(of: "kali-linux-", with: "").replacingOccurrences(of: "-\(kind)-\(e.arch).iso", with: "")
        return [LinuxImage(title: "Kali Linux \(ver) \(e.name)", version: ver, arch: e.arch, url: base + f.file, sha256: f.hash)]
    }

    static func popOS(_ e: LinuxEdition) async throws -> [LinuxImage] {
        let channel = e.id.contains("nvidia") ? "nvidia" : "intel"
        for ver in ["26.04", "24.04", "22.04"] {
            guard let json = try? await HTTP.getJSON("https://api.pop-os.org/builds/\(ver)/\(channel)?arch=amd64") as? [String: Any],
                  let url = json["url"] as? String else { continue }
            return [LinuxImage(title: "Pop!_OS \(ver) \(e.name)", version: ver, arch: "amd64", url: url,
                               sha256: json["sha_sum"] as? String, size: (json["size"] as? NSNumber)?.uint64Value)]
        }
        throw BootKitError.network("Pop!_OS build API unavailable.")
    }

    static func enterprise(_ e: LinuxEdition) async throws -> [LinuxImage] {
        let parts = e.id.split(separator: "-")
        let distro = String(parts[0]), major = String(parts[1]), kind = String(parts[2])
        let base = distro == "rocky" ? "https://download.rockylinux.org/pub/rocky/\(major)/isos/x86_64/"
                                     : "https://repo.almalinux.org/almalinux/\(major)/isos/x86_64/"
        let sums = try await HTTP.getString(base + "CHECKSUM")
        // Rocky 10 names its DVD "dvd1.iso"; prefer versioned names over "-latest-" aliases.
        let files = parseChecksums(sums).filter {
            ($0.file.hasSuffix("-x86_64-\(kind).iso") || $0.file.hasSuffix("-x86_64-\(kind)1.iso")) && !$0.file.contains("latest")
        }
        guard let f = files.sorted(by: { versionSort($0.file, $1.file) }).first else { throw BootKitError.network("No \(distro) image found.") }
        let name = distro == "rocky" ? "Rocky Linux" : "AlmaLinux"
        let ver = f.file.split(separator: "-").dropFirst().first.map(String.init) ?? major
        return [LinuxImage(title: "\(name) \(ver) \(kind.capitalized)", version: ver, arch: "x86_64", url: base + f.file, sha256: f.hash)]
    }

    static func tumbleweed(_ e: LinuxEdition) async throws -> [LinuxImage] {
        let kind = e.id.contains("dvd") ? "DVD" : "NET"
        let url = "https://download.opensuse.org/tumbleweed/iso/openSUSE-Tumbleweed-\(kind)-x86_64-Current.iso"
        let sum = try? await HTTP.getString(url + ".sha256")
        let hash = sum.flatMap { parseChecksums($0).first?.hash }
        let snapshot = sum.flatMap { parseChecksums($0).first?.file }.flatMap { f -> String? in
            f.range(of: "Snapshot").map { String(f[$0.upperBound...].prefix(8)) }
        } ?? "Current"
        return [LinuxImage(title: "openSUSE Tumbleweed \(e.name) (\(snapshot))", version: snapshot, arch: "x86_64", url: url, sha256: hash)]
    }

    static func tails() async throws -> [LinuxImage] {
        guard let json = try await HTTP.getJSON("https://tails.net/install/v2/Tails/amd64/stable/latest.json") as? [String: Any],
              let inst = (json["installations"] as? [[String: Any]])?.first,
              let paths = inst["installation-paths"] as? [[String: Any]] else { throw BootKitError.network("Tails release info unavailable.") }
        let version = inst["version"] as? String ?? ""
        for p in paths where (p["type"] as? String) == "img" {
            if let f = (p["target-files"] as? [[String: Any]])?.first, let url = f["url"] as? String {
                return [LinuxImage(title: "Tails \(version)", version: version, arch: "amd64", url: url,
                                   sha256: f["sha256"] as? String, size: (f["size"] as? NSNumber)?.uint64Value)]
            }
        }
        throw BootKitError.network("Tails USB image not found.")
    }

    static func alpine(_ e: LinuxEdition) async throws -> [LinuxImage] {
        let parts = e.id.split(separator: "-")
        let flavor = "alpine-" + parts[1], arch = String(parts[2])
        let base = "https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/\(arch)/"
        let yaml = try await HTTP.getString(base + "latest-releases.yaml")
        var entry: [String: String] = [:]
        var entries: [[String: String]] = []
        for raw in yaml.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "-" { if !entry.isEmpty { entries.append(entry) }; entry = [:]; continue }
            if let c = line.firstIndex(of: ":") {
                entry[String(line[..<c])] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            }
        }
        if !entry.isEmpty { entries.append(entry) }
        guard let x = entries.first(where: { $0["flavor"] == flavor && ($0["iso"] ?? "").hasSuffix(".iso") }), let iso = x["iso"] else {
            throw BootKitError.network("Alpine \(flavor) not found.")
        }
        return [LinuxImage(title: "Alpine Linux \(x["version"] ?? "") \(e.name)", version: x["version"] ?? "", arch: arch,
                           url: base + iso, sha256: x["sha256"], size: x["size"].flatMap(UInt64.init))]
    }

    static func proxmox() async throws -> [LinuxImage] {
        let base = "https://enterprise.proxmox.com/iso/"
        let sums = try await HTTP.getString(base + "SHA256SUMS")
        let files = parseChecksums(sums).filter { $0.file.hasPrefix("proxmox-ve_") && !$0.file.contains("arm64") }
        guard let f = files.sorted(by: { versionSort($0.file, $1.file) }).first else { throw BootKitError.network("No Proxmox VE image found.") }
        let ver = f.file.replacingOccurrences(of: "proxmox-ve_", with: "").replacingOccurrences(of: ".iso", with: "")
        return [LinuxImage(title: "Proxmox VE \(ver)", version: ver, arch: "amd64", url: base + f.file, sha256: f.hash)]
    }
}

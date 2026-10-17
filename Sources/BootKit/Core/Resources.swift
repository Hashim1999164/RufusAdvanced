import Foundation

/// Locates the embedded payloads (boot records, UEFI:NTFS, FreeDOS, Syslinux, ...).
///
/// Search order:
///  1. `$RUFUSADV_RESOURCES`
///  2. `<App>.app/Contents/Resources/BootKit` (for both the app and the helper inside it)
///  3. `<executable dir>/../Resources/BootKit` and `<executable dir>/BootKit`
///  4. The source tree (development builds via `swift run`).
public enum BootResources {
    public static let root: URL = {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["RUFUSADV_RESOURCES"] {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("BootKit")) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        candidates.append(exe.appendingPathComponent("../Resources/BootKit").standardized)
        candidates.append(exe.appendingPathComponent("BootKit"))
        // Development: <repo>/Sources/BootKit/Core/Resources.swift -> <repo>/Resources/BootKit
        let src = URL(fileURLWithPath: #filePath)
        candidates.append(src.deletingLastPathComponent().appendingPathComponent("../../../Resources/BootKit").standardized)
        for c in candidates where fm.fileExists(atPath: c.appendingPathComponent("bootrecords").path) {
            return c
        }
        return candidates.last!
    }()

    public static func url(_ relative: String) -> URL {
        root.appendingPathComponent(relative)
    }

    public static func data(_ relative: String) throws -> Data {
        let u = url(relative)
        guard let d = FileManager.default.contents(atPath: u.path) else {
            throw BootKitError.generic("Missing embedded resource '\(relative)' (looked in \(root.path)).")
        }
        return d
    }

    public static func bootRecord(_ name: String) throws -> [UInt8] {
        [UInt8](try data("bootrecords/\(name).bin"))
    }
}

/// External command line tools that unlock optional features.
public enum ExternalTool: String, CaseIterable, Codable, Sendable {
    case wimlib = "wimlib-imagex"
    case mke2fs = "mke2fs"
    case zstd = "zstd"
    case xz = "xz"
    case sevenZip = "7z"
    case qemuImg = "qemu-img"

    public var path: String? {
        switch self {
        case .sevenZip:
            return Shell.which("7z") ?? Shell.which("7zz")
        default:
            return Shell.which(rawValue)
        }
    }

    public var isAvailable: Bool { path != nil }

    public var brewFormula: String {
        switch self {
        case .wimlib: return "wimlib"
        case .mke2fs: return "e2fsprogs"
        case .zstd: return "zstd"
        case .xz: return "xz"
        case .sevenZip: return "sevenzip"
        case .qemuImg: return "qemu"
        }
    }

    public var purpose: String {
        switch self {
        case .wimlib: return "Split Windows install.wim > 4 GB for FAT32, inject customizations into boot.wim, 'Windows CA 2023' bootloaders"
        case .mke2fs: return "ext4 file systems (ext2/ext3 are built in)"
        case .zstd: return "Write .zst compressed images"
        case .xz: return "Faster .xz decompression (built-in fallback exists)"
        case .sevenZip: return "Extract .7z / .rar archived images"
        case .qemuImg: return "Write dynamic VHD / VHDX / QCOW2 / VMDK images"
        }
    }
}

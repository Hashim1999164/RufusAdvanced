import Foundation

/// Read-only attachment of an ISO / DMG through hdiutil (no root needed).
///
/// ISOs are attached without auto-mounting and their whole device is mounted explicitly as UDF
/// (Windows) or ISO9660 (Linux): hybrid ISOs carry an MBR/GPT that otherwise hides the optical
/// file system from DiskArbitration.
public final class DiskImageMount {
    public let imagePath: String
    public private(set) var devices: [String] = []
    public private(set) var mountPoints: [String] = []
    public private(set) var primaryMountPoint: String?
    private var ownMount: String?
    private var detached = false

    public init(imagePath: String, mountRoot: String? = nil, optical: Bool? = nil) throws {
        self.imagePath = imagePath
        let root = mountRoot ?? NSTemporaryDirectory() + "rufusadv-mnt"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let isOptical = optical ?? DiskImageMount.looksOptical(imagePath)

        if isOptical {
            let r = try Shell.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nomount", "-noverify", "-noautoopen", "-plist", imagePath])
            parseAttach(r)
            guard let dev = wholeDevice else {
                throw BootKitError.mountFailed("\((imagePath as NSString).lastPathComponent): \(r.combined.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            let mp = root + "/iso-\(UUID().uuidString.prefix(8))"
            try FileManager.default.createDirectory(atPath: mp, withIntermediateDirectories: true)
            var mounted = false
            // Only try UDF when the image really has a UDF volume: a failed mount_udf leaves
            // the device busy until reboot (macOS kernel bug).
            var tools: [(String, String)] = []
            if DiskImageMount.hasUDF(imagePath) { tools.append(("/sbin/mount_udf", "rdonly,nobrowse")) }
            tools.append(("/sbin/mount_cd9660", "rdonly,nobrowse"))
            for (tool, opts) in tools {
                if let m = try? Shell.run(tool, ["-o", opts, dev, mp], logCommand: false), m.ok,
                   let items = try? FileManager.default.contentsOfDirectory(atPath: mp), !items.isEmpty {
                    // A UDF bridge disc with only a README in ISO9660 is fine; but a UDF mount
                    // that shows nothing useful falls through to ISO9660.
                    mounted = true
                    break
                }
                _ = try? Shell.run("/sbin/umount", [mp], logCommand: false)
            }
            guard mounted else {
                detach()
                throw BootKitError.mountFailed("\((imagePath as NSString).lastPathComponent): no UDF or ISO9660 file system")
            }
            ownMount = mp
            mountPoints = [mp]
            primaryMountPoint = mp
            logDebug("Mounted \(imagePath) (\(dev)) at \(mp)")
            return
        }

        let r = try Shell.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-noverify", "-noautoopen",
                                                    "-mountrandom", root, "-plist", imagePath])
        guard r.ok else {
            throw BootKitError.mountFailed("\((imagePath as NSString).lastPathComponent): \(r.combined.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        parseAttach(r)
        logDebug("Attached \(imagePath) → \(devices.joined(separator: ", ")) mounted at \(mountPoints.joined(separator: ", "))")
    }

    private func parseAttach(_ r: ShellResult) {
        guard let data = r.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return }
        var best: (String, Int)?
        for e in entities {
            if let dev = e["dev-entry"] as? String { devices.append(dev) }
            if let mp = e["mount-point"] as? String {
                mountPoints.append(mp)
                let n = (try? FileManager.default.contentsOfDirectory(atPath: mp).count) ?? 0
                let hint = (e["content-hint"] as? String ?? "").lowercased()
                let score = n + (hint.contains("efi") ? -1000 : 0)
                if best == nil || score > best!.1 { best = (mp, score) }
            }
        }
        primaryMountPoint = best?.0
    }

    /// UDF volume recognition sequence (NSR02/NSR03) present?
    static func hasUDF(_ path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        guard (try? fh.seek(toOffset: 0x8000)) != nil, let d = try? fh.read(upToCount: 16 * 2048) else { return false }
        let b = [UInt8](d)
        for i in 0..<16 where b.count >= i * 2048 + 6 {
            let id = String(decoding: b[(i * 2048 + 1)..<(i * 2048 + 6)], as: UTF8.self)
            if id == "NSR02" || id == "NSR03" { return true }
        }
        return false
    }

    /// ISO9660 / UDF signature check.
    static func looksOptical(_ path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? fh.close() }
        guard (try? fh.seek(toOffset: 0x8000)) != nil, let d = try? fh.read(upToCount: 8 * 2048) else { return false }
        let b = [UInt8](d)
        for i in 0..<8 where b.count >= i * 2048 + 6 {
            let id = String(decoding: b[(i * 2048 + 1)..<(i * 2048 + 6)], as: UTF8.self)
            if ["CD001", "BEA01", "NSR02", "NSR03"].contains(id) { return true }
        }
        return false
    }

    /// The whole-disk device created by hdiutil (e.g. /dev/disk7).
    public var wholeDevice: String? {
        devices.min { $0.count < $1.count }
    }

    public func detach() {
        guard !detached else { return }
        detached = true
        if let m = ownMount {
            _ = try? Shell.run("/sbin/umount", [m], logCommand: false)
            try? FileManager.default.removeItem(atPath: m)
        }
        if let dev = wholeDevice {
            var r = try? Shell.run("/usr/bin/hdiutil", ["detach", dev], logCommand: false)
            if r?.ok != true {
                usleep(500_000)
                r = try? Shell.run("/usr/bin/hdiutil", ["detach", "-force", dev], logCommand: false)
            }
        }
    }

    deinit { detach() }
}

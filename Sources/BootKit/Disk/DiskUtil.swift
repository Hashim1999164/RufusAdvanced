import Foundation

/// Wrappers around `diskutil` for mounting / unmounting / ejecting.
public enum DiskUtil {
    static let diskutil = "/usr/sbin/diskutil"

    /// Unmount every volume of a disk (forcefully if needed).
    public static func unmountDisk(_ disk: String, force: Bool = true) throws {
        var r = try Shell.run(diskutil, ["unmountDisk", disk])
        if !r.ok && force {
            logWarning("Normal unmount of \(disk) failed, forcing…")
            r = try Shell.run(diskutil, ["unmountDisk", "force", disk])
        }
        if !r.ok {
            throw BootKitError.generic("Could not unmount \(disk). Close any app using the drive and try again.\n\(r.combined)")
        }
    }

    public static func unmount(_ slice: String, force: Bool = false) {
        _ = try? Shell.run(diskutil, force ? ["unmount", "force", slice] : ["unmount", slice])
    }

    /// Mount a slice at a private mount point, hidden from Finder.
    @discardableResult
    public static func mount(_ slice: String, at mountPoint: String? = nil, readOnly: Bool = false) throws -> String {
        var args = ["mount"]
        if readOnly { args.append("readOnly") }
        args.append("nobrowse")
        if let mountPoint {
            try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
            args += ["-mountPoint", mountPoint]
        }
        args.append(slice)
        var r = try Shell.run(diskutil, args)
        if !r.ok {
            // Some diskutil versions reject "nobrowse" for certain file systems.
            args.removeAll { $0 == "nobrowse" }
            r = try Shell.run(diskutil, args)
        }
        guard r.ok else { throw BootKitError.mountFailed("\(slice): \(r.combined)") }
        if let mountPoint { return mountPoint }
        guard let mp = mountPointOf(slice) else { throw BootKitError.mountFailed(slice) }
        return mp
    }

    public static func mountPointOf(_ slice: String) -> String? {
        guard let r = try? Shell.run(diskutil, ["info", "-plist", slice], logCommand: false), r.ok,
              let d = DiskEnumerator.parsePlist(r.stdout) else { return nil }
        let mp = d["MountPoint"] as? String
        return (mp?.isEmpty ?? true) ? nil : mp
    }

    public static func eject(_ disk: String) {
        _ = try? Shell.run(diskutil, ["eject", disk])
    }

    /// Wait until the given slices (e.g. disk4s1, disk4s2) exist as device nodes.
    public static func waitForSlices(_ slices: [String], timeout: TimeInterval = 20, cancel: CancellationToken? = nil) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try cancel?.check()
            if slices.allSatisfy({ FileManager.default.fileExists(atPath: "/dev/\($0)") }) {
                // Give DiskArbitration a moment to finish probing.
                usleep(500_000)
                return
            }
            usleep(250_000)
        }
        throw BootKitError.partitionNotFound(slices.joined(separator: ", "))
    }

    /// Ask the kernel to re-read the partition table. Closing a raw whole-disk node opened
    /// for writing normally triggers a re-probe; as a fallback we nudge DiskArbitration.
    public static func rescan(_ disk: String, expecting slices: [String], cancel: CancellationToken? = nil) throws {
        do {
            try waitForSlices(slices, timeout: 6, cancel: cancel)
            return
        } catch BootKitError.cancelled {
            throw BootKitError.cancelled
        } catch {
            logDebug("Partitions not visible yet, requesting a re-probe of \(disk)")
        }
        // Opening and closing the whole disk read/write triggers a re-probe on macOS.
        if let dev = try? RawDevice(path: "/dev/\(disk)", writable: true) {
            dev.close()
        }
        _ = try? Shell.run(diskutil, ["unmountDisk", disk])
        try waitForSlices(slices, timeout: 20, cancel: cancel)
    }

    /// Remove macOS litter (Spotlight, fseventsd, Trashes, AppleDouble "._" files) from a volume.
    /// macOS tags every file a process creates with a `com.apple.provenance` xattr, which FAT and
    /// exFAT can only store as "._name" AppleDouble files. Foundation hides those files from its
    /// enumerators, so they are removed with find(1).
    public static func cleanMacMetadata(at root: String) {
        let fm = FileManager.default
        for name in [".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", ".DS_Store", ".VolumeIcon.icns"] {
            let p = (root as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: p) || (try? fm.attributesOfItem(atPath: p)) != nil { try? fm.removeItem(atPath: p) }
        }
        _ = try? Shell.run("/usr/bin/find", [root, "-xdev", "-name", "._*", "-type", "f", "-delete"], logCommand: false)
    }

    /// Ask Spotlight / fseventsd to leave the volume alone while we copy.
    public static func preventMacMetadata(at root: String) {
        let fm = FileManager.default
        fm.createFile(atPath: (root as NSString).appendingPathComponent(".metadata_never_index"), contents: Data())
        try? fm.createDirectory(atPath: (root as NSString).appendingPathComponent(".fseventsd"), withIntermediateDirectories: true)
        fm.createFile(atPath: (root as NSString).appendingPathComponent(".fseventsd/no_log"), contents: Data())
        _ = try? Shell.run("/usr/bin/mdutil", ["-i", "off", root], logCommand: false)
    }

    /// Remove the helper files created by `preventMacMetadata`.
    public static func finalizeVolume(at root: String) {
        cleanMacMetadata(at: root)
        try? FileManager.default.removeItem(atPath: (root as NSString).appendingPathComponent(".metadata_never_index"))
        sync()
    }
}

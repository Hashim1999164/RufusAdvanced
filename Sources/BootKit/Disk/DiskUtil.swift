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
        if !r.ok, mountPoint != nil {
            // Without root, some macOS versions refuse custom mount points: let DiskArbitration
            // choose one under /Volumes (still hidden from Finder with nobrowse).
            logDebug("diskutil refused the private mount point for \(slice); retrying with the default mount point")
            r = try Shell.run(diskutil, readOnly ? ["mount", "readOnly", "nobrowse", slice] : ["mount", "nobrowse", slice])
            if !r.ok { r = try Shell.run(diskutil, readOnly ? ["mount", "readOnly", slice] : ["mount", slice]) }
            guard r.ok else { throw BootKitError.mountFailed("\(slice): \(r.combined)") }
            guard let mp = mountPointOf(slice) else { throw BootKitError.mountFailed(slice) }
            logDebug("Mounted \(slice) at \(mp)")
            return mp
        }
        guard r.ok else { throw BootKitError.mountFailed("\(slice): \(r.combined)") }
        if let mountPoint { logDebug("Mounted \(slice) at \(mountPoint)"); return mountPoint }
        guard let mp = mountPointOf(slice) else { throw BootKitError.mountFailed(slice) }
        return mp
    }

    public static func mountPointOf(_ slice: String) -> String? {
        guard let r = try? Shell.run(diskutil, ["info", "-plist", slice], logCommand: false), r.ok,
              let d = DiskEnumerator.parsePlist(r.stdout) else { return nil }
        let mp = d["MountPoint"] as? String
        return (mp?.isEmpty ?? true) ? nil : mp
    }

    @discardableResult
    public static func eject(_ disk: String) -> Bool {
        (try? Shell.run(diskutil, ["eject", disk]))?.ok ?? false
    }

    /// Partition slices of a whole disk that currently exist as device nodes, plus the disk itself
    /// (a DD-written image may carry a file system without a partition table).
    public static func slices(of disk: String) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        let pattern = "^\(NSRegularExpression.escapedPattern(for: disk))s[0-9]+$"
        let parts = names.filter { $0.range(of: pattern, options: .regularExpression) != nil }
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        return parts + [disk]
    }

    /// True if the volume at `path` is mounted with MNT_DONTBROWSE (hidden from Finder).
    public static func isHiddenFromFinder(_ path: String) -> Bool {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return false }
        return (UInt32(s.f_flags) & UInt32(MNT_DONTBROWSE)) != 0
    }

    /// Mounted volumes of `disk` that Finder shows (under /Volumes and not "nobrowse").
    public static func finderMountPoints(of disk: String) -> [String] {
        slices(of: disk).compactMap { mountPointOf($0) }
            .filter { $0.hasPrefix("/Volumes/") && !isHiddenFromFinder($0) }
    }

    /// After a job: mount the drive's volumes normally so they appear in Finder and on the Desktop.
    /// Retries for up to `timeout` seconds (DiskArbitration may still be probing the new file
    /// systems). Returns the Finder-visible mount points; never throws — failures are logged.
    public static func mountForFinder(_ disk: String, timeout: TimeInterval = 20, cancel: CancellationToken? = nil) -> [String] {
        // Our private mounts were "nobrowse": release any that are still around first.
        for slice in slices(of: disk) {
            if let mp = mountPointOf(slice), !mp.hasPrefix("/Volumes/") || isHiddenFromFinder(mp) {
                logDebug("\(slice) is still mounted privately at \(mp); unmounting it before remounting for Finder")
                unmount(slice)
                if mountPointOf(slice) != nil { unmount(slice, force: true) }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        while true {
            attempt += 1
            if cancel?.isCancelled == true { return finderMountPoints(of: disk) }
            do {
                let r = try Shell.run(diskutil, ["mountDisk", disk])
                if !r.ok {
                    logDebug("diskutil mountDisk \(disk) (attempt \(attempt)) exited with status \(r.status): \(r.combined.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            } catch {
                logDebug("diskutil mountDisk \(disk) (attempt \(attempt)) could not run: \(error.userMessage)")
            }
            let visible = finderMountPoints(of: disk)
            if !visible.isEmpty { return visible }
            logDebug("No Finder-visible volume on \(disk) yet (attempt \(attempt))")
            if Date() >= deadline { return [] }
            usleep(1_000_000)
        }
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

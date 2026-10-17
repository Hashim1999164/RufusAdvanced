import Foundation

/// Top level job dispatcher, used both by the privileged helper and in-process (tests, disk images).
public enum JobRunner {

    /// Run a job to completion. Never throws: the outcome is reported through `.finished`.
    @discardableResult
    public static func run(_ spec: JobSpec, reporter: JobReporter, cancel: CancellationToken) -> Bool {
        let started = Date()
        let sinkID = Log.shared.addSink { reporter.emit(.log($0)) }
        defer { Log.shared.removeSink(sinkID) }
        var success = false
        var errorText: String?
        do {
            logInfo("RufusAdvanced \(BootKit.version) — job started (\(spec.operation.rawValue))")
            logDebug("Helper pid \(getpid()), uid \(getuid()), euid \(geteuid()), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            logDebug("Executable: \(CommandLine.arguments.first ?? "?")")
            if let w = AppLocation.warning { logWarning(w) }
            if spec.operation == .installMacPackage {
                guard let pkg = spec.imagePath else { throw BootKitError.invalidOption("No package selected") }
                try MacInstallerLibrary.install(package: pkg, reporter: reporter, cancel: cancel, ownerUID: spec.ownerUID, ownerGID: spec.ownerGID)
                let elapsed = Units.duration(Date().timeIntervalSince(started))
                logInfo("Operation completed successfully in \(elapsed).")
                reporter.emit(.finished(success: true, error: nil, notices: reporter.notices))
                return true
            }
            logDebug("Job: disk \(spec.disk) (\(Units.human(spec.diskSize)), \(spec.diskMediaName)), boot \(spec.bootSelection.rawValue), mode \(spec.writeMode.rawValue), scheme \(spec.partitionScheme.rawValue), target \(spec.targetSystem.rawValue), fs \(spec.fileSystem.rawValue), cluster \(spec.clusterSize == 0 ? "default" : String(spec.clusterSize)), quick format \(spec.quickFormat), label '\(spec.label)'")
            if let img = spec.imagePath { logDebug("Image: \(img)") }
            let ctx = try JobContext(spec: spec, reporter: reporter, cancel: cancel)
            logInfo("Target: \(ctx.disk.displayName) — \(ctx.disk.subtitle)")
            try runChecked(ctx)
            if spec.operation != .saveImage {
                if spec.ejectWhenDone {
                    reporter.update(fraction: 1, detail: "Ejecting", force: true)
                    if DiskUtil.eject(spec.disk) {
                        reporter.notice("The drive was ejected and is safe to remove.")
                        reporter.emit(.driveState(ejected: true, mountPoints: []))
                    } else {
                        logWarning("Could not eject \(spec.disk). Eject it from Finder before unplugging it.")
                        reporter.emit(.driveState(ejected: false, mountPoints: []))
                    }
                } else if spec.mountWhenDone && spec.operation == .write {
                    reporter.update(fraction: 1, detail: "Mounting the drive in Finder", force: true)
                    let mps = DiskUtil.mountForFinder(spec.disk, cancel: cancel)
                    if mps.isEmpty {
                        logWarning("The drive is ready, but macOS did not mount it in Finder. Unplug and reconnect it to see it.")
                    } else {
                        for mp in mps { logInfo("Mounted \(spec.disk) at \(mp)") }
                        reporter.notice("Ready: mounted at \(mps.joined(separator: ", ")).")
                    }
                    reporter.emit(.driveState(ejected: false, mountPoints: mps))
                }
            }
            success = true
        } catch BootKitError.cancelled {
            errorText = "Operation cancelled by the user."
            logWarning(errorText!)
        } catch {
            errorText = error.userMessage
            logError(errorText!)
        }
        let elapsed = Units.duration(Date().timeIntervalSince(started))
        if success { logInfo("Operation completed successfully in \(elapsed).") }
        reporter.emit(.finished(success: success, error: errorText, notices: reporter.notices))
        return success
    }

    static func runChecked(_ ctx: JobContext) throws {
        let spec = ctx.spec
        // Optional bad block check comes first (it destroys all data anyway).
        if let bb = spec.badBlocks, spec.operation != .saveImage {
            let report = try BadBlocks.run(disk: spec.disk, options: bb, reporter: ctx.reporter, cancel: ctx.cancel)
            if report.total > 0 { throw BootKitError.badBlocks(report.total) }
            ctx.reporter.notice("Bad blocks check: no bad blocks found.")
            if spec.operation == .badBlocksOnly { return }
        }
        switch spec.operation {
        case .badBlocksOnly, .installMacPackage:
            return
        case .saveImage:
            try SaveImageJob.run(ctx)
        case .write:
            switch spec.bootSelection {
            case .image, .macInstaller:
                guard let image = spec.image else { throw BootKitError.invalidOption("No image selected") }
                switch spec.writeMode {
                case .dd:
                    try DDWriter.write(ctx)
                case .iso:
                    guard image.kind == .iso else { throw BootKitError.invalidOption("ISO mode requires an ISO image") }
                    try ISOWriter.write(ctx)
                case .createInstallMedia, .asrRestore:
                    try MacInstallerWriter.write(ctx)
                }
            default:
                try FormatWriter.write(ctx)
            }
        }
    }
}

/// "Save drive to image": raw copy of the whole device into .img / .vhd / .dmg.
public enum SaveImageJob {
    public static func run(_ ctx: JobContext) throws {
        guard let out = ctx.spec.saveImagePath else { throw BootKitError.invalidOption("No output file chosen") }
        let r = ctx.reporter
        r.plan([("Reading drive", 95), ("Finalizing", 5)])
        try? DiskUtil.unmountDisk(ctx.spec.disk, force: false)
        let dev = try RawDevice(path: "/dev/r\(ctx.spec.disk)", writable: false)
        defer { dev.close() }
        let rawPath = ctx.spec.saveFormat == .dmg ? ctx.scratch + "/drive.img" : out
        FileManager.default.createFile(atPath: rawPath, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: rawPath) else { throw BootKitError.openFailed(rawPath, errno) }
        r.begin("Reading drive", detail: "\(ctx.disk.displayName) → \((out as NSString).lastPathComponent)", total: dev.size)
        let chunk = 4 * Int(Units.MB)
        let buf = RawDevice.alignedBuffer(chunk)
        defer { free(buf) }
        var pos: UInt64 = 0
        while pos < dev.size {
            try ctx.cancel.check()
            let n = Int(min(UInt64(chunk), dev.size - pos))
            try dev.read(at: pos, into: buf, count: n)
            try fh.write(contentsOf: Data(bytesNoCopy: buf, count: n, deallocator: .none))
            pos += UInt64(n)
            r.bytes(pos, of: dev.size)
        }
        if ctx.spec.saveFormat == .vhd {
            try fh.write(contentsOf: Data(VHD.fixedFooter(diskSize: dev.size)))
        }
        try fh.close()
        r.begin("Finalizing")
        if ctx.spec.saveFormat == .dmg {
            try? FileManager.default.removeItem(atPath: out)
            try Shell.check("/usr/bin/hdiutil", ["convert", rawPath, "-format", "UDZO", "-o", out], cancel: ctx.cancel)
            try? FileManager.default.removeItem(atPath: rawPath)
        }
        ctx.chownToUser(out)
        r.notice("Saved \(Units.human(dev.size)) image to \(out)")
    }
}

/// Fixed VHD footer (Microsoft Virtual Hard Disk Image Format Specification).
public enum VHD {
    public static func fixedFooter(diskSize: UInt64) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: 512)
        func be32(_ off: Int, _ v: UInt32) { for i in 0..<4 { f[off + i] = UInt8((v >> (24 - 8 * UInt32(i))) & 0xff) } }
        func be64(_ off: Int, _ v: UInt64) { for i in 0..<8 { f[off + i] = UInt8((v >> (56 - 8 * UInt64(i))) & 0xff) } }
        f.replaceSubrange(0..<8, with: Array("conectix".utf8))
        be32(8, 2)                                 // features: reserved
        be32(12, 0x0001_0000)                      // file format version
        be64(16, 0xFFFF_FFFF_FFFF_FFFF)            // data offset (fixed disk)
        be32(24, UInt32(Date().timeIntervalSince(Date(timeIntervalSince1970: 946_684_800))))
        f.replaceSubrange(28..<32, with: Array("rfad".utf8))   // creator application
        be32(32, 0x0001_0000)
        f.replaceSubrange(36..<40, with: Array("Mac ".utf8))   // creator host OS
        be64(40, diskSize)
        be64(48, diskSize)
        // CHS geometry (spec algorithm)
        var totalSectors = diskSize / 512
        if totalSectors > 65535 * 16 * 255 { totalSectors = 65535 * 16 * 255 }
        var spt: UInt64, heads: UInt64, cth: UInt64
        if totalSectors >= 65535 * 16 * 63 {
            spt = 255; heads = 16; cth = totalSectors / spt
        } else {
            spt = 17; cth = totalSectors / spt
            heads = (cth + 1023) / 1024
            if heads < 4 { heads = 4 }
            if cth >= heads * 1024 || heads > 16 { spt = 31; heads = 16; cth = totalSectors / spt }
            if cth >= heads * 1024 { spt = 63; heads = 16; cth = totalSectors / spt }
        }
        let cyl = cth / heads
        f[56] = UInt8((cyl >> 8) & 0xff); f[57] = UInt8(cyl & 0xff); f[58] = UInt8(heads); f[59] = UInt8(spt)
        be32(60, 2)                                // disk type: fixed
        let u = UUID().uuid
        f.replaceSubrange(68..<84, with: [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15])
        var sum: UInt32 = 0
        for b in f { sum = sum &+ UInt32(b) }
        be32(64, ~sum)
        return f
    }
}

public enum BootKit {
    public static let version = "1.1.1"
}

import Foundation

/// Shared state of a running job.
public final class JobContext {
    public let spec: JobSpec
    public let reporter: JobReporter
    public let cancel: CancellationToken
    public let scratch: String
    public private(set) var disk: DiskInfo

    public init(spec: JobSpec, reporter: JobReporter, cancel: CancellationToken) throws {
        self.spec = spec
        self.reporter = reporter
        self.cancel = cancel
        scratch = (spec.macTempDirectory ?? NSTemporaryDirectory()) + "/rufusadv-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        disk = try JobContext.validateDevice(spec)
    }

    deinit {
        try? FileManager.default.removeItem(atPath: scratch)
    }

    /// Make sure the device is the one the user picked and that it is safe to erase.
    static func validateDevice(_ spec: JobSpec) throws -> DiskInfo {
        guard spec.disk.range(of: "^disk[0-9]+$", options: .regularExpression) != nil else {
            throw BootKitError.invalidOption("'\(spec.disk)' is not a whole disk identifier")
        }
        guard let info = DiskEnumerator.info(spec.disk) else { throw BootKitError.deviceNotFound(spec.disk) }
        if info.size != spec.diskSize { throw BootKitError.deviceChanged(spec.disk) }
        if (info.isInternal && info.kind != .sdCard) || info.isSystemDisk { throw BootKitError.deviceIsInternal(spec.disk) }
        if info.kind == .diskImage && !spec.allowVirtualDisks {
            throw BootKitError.invalidOption("\(spec.disk) is a disk image; enable 'Show disk images' to use it as a target.")
        }
        if !info.isWritable { throw BootKitError.generic("\(spec.disk) is write protected. Check the lock switch on the drive/card.") }
        // Never erase the drive that holds the source image (Rufus: "saw the branch you are sitting on").
        if let image = spec.imagePath, let src = deviceOf(path: image), src == spec.disk {
            throw BootKitError.invalidOption("The selected image is stored on the target drive, which is about to be erased. Copy it elsewhere first.")
        }
        return info
    }

    /// Whole disk identifier (disk4) holding a path.
    static func deviceOf(path: String) -> String? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        let from = withUnsafeBytes(of: s.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        guard from.hasPrefix("/dev/disk") else { return nil }
        let id = from.dropFirst(5)  // disk4s1
        guard let range = id.range(of: "^disk[0-9]+", options: .regularExpression) else { return nil }
        // APFS volumes live on synthesized disks; map back to the physical store when possible.
        let whole = String(id[range])
        if let r = try? Shell.run("/usr/sbin/diskutil", ["info", "-plist", whole], logCommand: false),
           let d = DiskEnumerator.parsePlist(r.stdout),
           let stores = d["APFSPhysicalStores"] as? [[String: Any]],
           let store = stores.first?["APFSPhysicalStore"] as? String,
           let sr = store.range(of: "^disk[0-9]+", options: .regularExpression) {
            return String(store[sr])
        }
        return whole
    }

    public func refreshDisk() {
        if let d = DiskEnumerator.info(spec.disk) { disk = d }
    }

    /// Hand ownership of a file we created as root back to the user.
    public func chownToUser(_ path: String) {
        if getuid() == 0 { _ = Darwin.chown(path, spec.ownerUID, spec.ownerGID) }
    }
}

import Foundation

/// A partition / volume on a disk as reported by diskutil.
public struct PartitionInfo: Codable, Hashable, Sendable {
    public var identifier: String       // disk4s1
    public var size: UInt64
    public var content: String          // e.g. "Microsoft Basic Data", "EFI", "Apple_HFS"
    public var volumeName: String?
    public var mountPoint: String?
}

/// A whole physical (or virtual) disk that may be used as a target.
public struct DiskInfo: Codable, Hashable, Sendable, Identifiable {
    public var identifier: String       // disk4
    public var mediaName: String
    public var size: UInt64
    public var blockSize: UInt32
    public var busProtocol: String      // USB, Disk Image, SD, SATA, ...
    public var isInternal: Bool
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isVirtual: Bool
    public var isWritable: Bool
    public var partitionScheme: String?
    public var partitions: [PartitionInfo]
    public var isSystemDisk: Bool

    public var id: String { identifier }
    public var devicePath: String { "/dev/\(identifier)" }
    public var rawDevicePath: String { "/dev/r\(identifier)" }

    public enum Kind: String, Codable, Sendable {
        case usbFlash, usbHardDrive, sdCard, diskImage, otherExternal, internalDisk
    }

    public var kind: Kind {
        let bus = busProtocol.lowercased()
        // Built-in SDXC readers report "Internal" but their media is removable.
        if (bus.contains("secure digital") || bus == "sd" || mediaName.lowercased().contains("sdxc")) && isRemovable {
            return .sdCard
        }
        if isInternal { return .internalDisk }
        if busProtocol == "Disk Image" || isVirtual && busProtocol.isEmpty { return .diskImage }
        if bus.contains("sd") || mediaName.lowercased().contains("sd card") {
            return .sdCard
        }
        if bus == "usb" { return isRemovable ? .usbFlash : .usbHardDrive }
        return .otherExternal
    }

    /// The label shown in the UI, Rufus style: "SANDISK (disk4) [32 GB]".
    public var displayName: String {
        let vol = partitions.compactMap { $0.volumeName }.first { !$0.isEmpty }
        let name = vol ?? mediaName
        let multi = partitions.filter { $0.content != "EFI" }.count > 1 ? " — Multiple Partitions" : ""
        return "\(name) (\(identifier)) [\(Units.driveSizeLabel(size))]\(multi)"
    }

    public var subtitle: String {
        let kindText: String
        switch kind {
        case .usbFlash: kindText = "USB flash drive"
        case .usbHardDrive: kindText = "USB hard drive"
        case .sdCard: kindText = "SD / memory card"
        case .diskImage: kindText = "Disk image"
        case .otherExternal: kindText = "\(busProtocol) external disk"
        case .internalDisk: kindText = "Internal disk"
        }
        return "\(mediaName) · \(kindText) · \(Units.human(size))"
    }

    /// Whether this disk may ever be written to by the engine.
    public var isSafeTarget: Bool {
        (!isInternal || kind == .sdCard) && !isSystemDisk && isWritable && size > 0
    }
}

/// Enumerates disks through `diskutil`.
public enum DiskEnumerator {
    public struct Options: Sendable {
        public var includeUSBHardDrives: Bool
        public var includeDiskImages: Bool
        public var includeOtherExternal: Bool
        public init(includeUSBHardDrives: Bool = false, includeDiskImages: Bool = false, includeOtherExternal: Bool = true) {
            self.includeUSBHardDrives = includeUSBHardDrives
            self.includeDiskImages = includeDiskImages
            self.includeOtherExternal = includeOtherExternal
        }
    }

    public static func list(_ options: Options = Options()) -> [DiskInfo] {
        // List everything and filter ourselves: built-in SD card readers are "internal".
        guard let r = try? Shell.run("/usr/sbin/diskutil", ["list", "-plist"], logCommand: false), r.ok,
              let plist = parsePlist(r.stdout),
              let whole = plist["WholeDisks"] as? [String] else { return [] }
        let all = (plist["AllDisksAndPartitions"] as? [[String: Any]]) ?? []
        var disks: [DiskInfo] = []
        for id in whole {
            guard let entry = all.first(where: { ($0["DeviceIdentifier"] as? String) == id }) else { continue }
            // Skip APFS containers / synthesized disks early (cheap check on the list entry).
            if (entry["Content"] as? String) == "Apple_APFS_Container" || entry["APFSVolumes"] != nil && entry["Partitions"] == nil { continue }
            guard let disk = info(id, listEntry: entry), disk.isWritable else { continue }
            if disk.kind != .diskImage && !disk.isSafeTarget { continue }
            // Disk images hosting an APFS container are system/runtime images (e.g. Xcode simulators).
            if disk.kind == .diskImage && disk.partitions.contains(where: { $0.content == "Apple_APFS" }) { continue }
            // Skip synthesized APFS containers: they are not real media.
            if disk.busProtocol.isEmpty && disk.isVirtual && disk.mediaName.contains("AppleAPFSMedia") { continue }
            switch disk.kind {
            case .internalDisk: continue
            case .usbHardDrive: if !options.includeUSBHardDrives { continue }
            case .diskImage: if !options.includeDiskImages { continue }
            case .otherExternal: if !options.includeOtherExternal { continue }
            case .usbFlash, .sdCard: break
            }
            if disk.isVirtual && disk.kind != .diskImage { continue }
            disks.append(disk)
        }
        return disks.sorted { $0.identifier.localizedStandardCompare($1.identifier) == .orderedAscending }
    }

    /// Full information on one whole disk.
    public static func info(_ identifier: String, listEntry: [String: Any]? = nil) -> DiskInfo? {
        guard let r = try? Shell.run("/usr/sbin/diskutil", ["info", "-plist", identifier], logCommand: false), r.ok,
              let d = parsePlist(r.stdout) else { return nil }
        guard (d["WholeDisk"] as? Bool) ?? false else { return nil }

        var partitions: [PartitionInfo] = []
        let entry = listEntry ?? {
            guard let lr = try? Shell.run("/usr/sbin/diskutil", ["list", "-plist", identifier], logCommand: false),
                  let lp = parsePlist(lr.stdout),
                  let all = lp["AllDisksAndPartitions"] as? [[String: Any]] else { return nil }
            return all.first
        }()
        if let parts = entry?["Partitions"] as? [[String: Any]] {
            for p in parts {
                partitions.append(PartitionInfo(
                    identifier: p["DeviceIdentifier"] as? String ?? "?",
                    size: (p["Size"] as? NSNumber)?.uint64Value ?? 0,
                    content: p["Content"] as? String ?? "",
                    volumeName: p["VolumeName"] as? String,
                    mountPoint: p["MountPoint"] as? String))
            }
        } else if let entry, let mp = entry["MountPoint"] as? String {
            // Superfloppy (no partition table) volume.
            partitions.append(PartitionInfo(identifier: identifier,
                                            size: (entry["Size"] as? NSNumber)?.uint64Value ?? 0,
                                            content: entry["Content"] as? String ?? "",
                                            volumeName: entry["VolumeName"] as? String, mountPoint: mp))
        }

        let isInternal = (d["Internal"] as? Bool) ?? true
        let bus = d["BusProtocol"] as? String ?? ""
        let virtual = (d["VirtualOrPhysical"] as? String) == "Virtual"
        let mediaName = (d["MediaName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (d["IORegistryEntryName"] as? String) ?? "Unknown Device"
        let systemDisk = partitions.contains { $0.mountPoint == "/" || ($0.mountPoint ?? "").hasPrefix("/System/Volumes") }

        return DiskInfo(
            identifier: identifier,
            mediaName: mediaName.replacingOccurrences(of: " Media", with: ""),
            size: (d["TotalSize"] as? NSNumber)?.uint64Value ?? (d["Size"] as? NSNumber)?.uint64Value ?? 0,
            blockSize: UInt32((d["DeviceBlockSize"] as? NSNumber)?.intValue ?? 512),
            busProtocol: bus,
            isInternal: isInternal,
            isRemovable: (d["Removable"] as? Bool) ?? (d["RemovableMedia"] as? Bool) ?? false,
            isEjectable: (d["Ejectable"] as? Bool) ?? false,
            isVirtual: virtual,
            isWritable: (d["WritableMedia"] as? Bool) ?? true,
            partitionScheme: d["Content"] as? String,
            partitions: partitions,
            isSystemDisk: systemDisk)
    }

    static func parsePlist(_ s: String) -> [String: Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}

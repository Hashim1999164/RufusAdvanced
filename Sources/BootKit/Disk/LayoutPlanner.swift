import Foundation

/// Computes a Rufus-style partition layout.
public enum LayoutPlanner {
    public struct Request: Sendable {
        public var diskSize: UInt64
        public var sectorSize: UInt32
        public var scheme: PartitionScheme
        public var fileSystem: FileSystemType
        public var bootable: Bool
        public var targetSystem: TargetSystem
        public var oldBIOSFixes: Bool = false
        public var clusterSize: UInt32 = 0
        public var persistenceSize: UInt64 = 0
        public var uefiNTFSSize: UInt64 = 0
        public var addESPAndMSR: Bool = false
        public var mainSizeCap: UInt64? = nil
        public var mainName: String = "Main Data Partition"

        public init(diskSize: UInt64, sectorSize: UInt32, scheme: PartitionScheme, fileSystem: FileSystemType,
                    bootable: Bool, targetSystem: TargetSystem) {
            self.diskSize = diskSize
            self.sectorSize = sectorSize
            self.scheme = scheme
            self.fileSystem = fileSystem
            self.bootable = bootable
            self.targetSystem = targetSystem
        }
    }

    /// 'U' 'E' 'F' 'I' as a little endian longword, used by Rufus as MBR signature for MBR+UEFI media.
    public static let mbrUEFIMarker: UInt32 = 0x4946_4555

    public static func plan(_ r: Request) throws -> PartitionLayout {
        let ss = UInt64(r.sectorSize)
        let align = Units.MB
        let cluster = UInt64(max(r.clusterSize, 512))
        var parts: [PlannedPartition] = []

        // Offset of the first partition.
        var offset: UInt64
        if r.scheme == .gpt || !r.oldBIOSFixes {
            offset = Units.MB
        } else {
            // Old BIOS fixes: cylinder aligned (63 sectors/track), doubled so GRUB2's core.img fits.
            let track = 63 * ss
            offset = Units.alignUp(track, cluster) * 2
        }

        if r.addESPAndMSR && r.scheme == .gpt {
            parts.append(PlannedPartition(role: .esp, name: "EFI System Partition", offset: offset, size: 260 * Units.MB,
                                          mbrType: 0xef, gptType: GPTType.efiSystem))
            offset = Units.alignUp(offset + 260 * Units.MB, align)
            parts.append(PlannedPartition(role: .msr, name: "Microsoft Reserved Partition", offset: offset, size: 128 * Units.MB,
                                          mbrType: 0x00, gptType: GPTType.msReserved))
            offset = Units.alignUp(offset + 128 * Units.MB, align)
        }

        let mainIndex = parts.count
        parts.append(PlannedPartition(role: .main, name: r.mainName, offset: offset, size: 0,
                                      mbrType: r.fileSystem.mbrType, gptType: r.fileSystem.gptType,
                                      bootable: r.bootable))

        // Trailing extra partitions.
        var trailing: [PlannedPartition] = []
        if r.persistenceSize > 0 {
            trailing.append(PlannedPartition(role: .persistence, name: "Linux Persistence",
                                             size: Units.alignUp(r.persistenceSize, align),
                                             mbrType: 0x83, gptType: GPTType.linuxData))
        }
        if r.uefiNTFSSize > 0 {
            // Never declare it as an ESP on GPT: Windows setup chokes on two ESPs.
            trailing.append(PlannedPartition(role: .uefiNTFS, name: "UEFI:NTFS",
                                             size: Units.alignUp(r.uefiNTFSSize, align),
                                             mbrType: 0xef, gptType: GPTType.basicData,
                                             gptAttributes: GPTType.attrNoDriveLetter))
        } else if r.oldBIOSFixes {
            trailing.append(PlannedPartition(role: .compat, name: "BIOS Compatibility", size: Units.MB,
                                             mbrType: 0xea, gptType: GPTType.basicData))
        }

        var last = r.diskSize
        if r.scheme == .gpt { last -= 33 * ss }   // backup GPT
        last = Units.alignDown(last, align)
        for i in stride(from: trailing.count - 1, through: 0, by: -1) {
            guard trailing[i].size < last else { throw BootKitError.deviceTooSmall(needed: trailing[i].size, available: r.diskSize) }
            trailing[i].offset = Units.alignDown(last - trailing[i].size, align)
            last = trailing[i].offset
        }

        guard last > offset else {
            throw BootKitError.deviceTooSmall(needed: r.persistenceSize + r.uefiNTFSSize + 8 * Units.MB, available: r.diskSize)
        }
        var mainSize = last - offset
        if let cap = r.mainSizeCap { mainSize = min(mainSize, cap) }
        if r.scheme == .mbr {
            // MBR can only address 2 TiB (with 512 byte sectors).
            let maxEnd = UInt64(UInt32.max) * ss
            if offset + mainSize > maxEnd {
                logWarning("MBR can only address \(Units.human(maxEnd)); \(Units.human(offset + mainSize - maxEnd)) will be left unused. Use GPT to use the whole drive.")
                mainSize = maxEnd - offset
            }
        }
        mainSize = Units.alignDown(mainSize, ss)
        if cluster % ss == 0 { mainSize = Units.alignDown(mainSize, cluster) }
        if mainSize > r.fileSystem.maxVolumeSize {
            logWarning("\(r.fileSystem.rawValue) volumes are limited to \(Units.human(r.fileSystem.maxVolumeSize)); the partition will be smaller than the drive.")
            mainSize = r.fileSystem.maxVolumeSize
        }
        guard mainSize >= 8 * Units.MB else {
            throw BootKitError.deviceTooSmall(needed: 8 * Units.MB, available: mainSize)
        }
        parts[mainIndex].size = mainSize
        parts.append(contentsOf: trailing)

        let sig: UInt32? = (r.scheme == .mbr && r.targetSystem == .uefi) ? mbrUEFIMarker : nil
        return PartitionLayout(scheme: r.scheme, diskSize: r.diskSize, sectorSize: r.sectorSize, partitions: parts, mbrSignature: sig)
    }
}

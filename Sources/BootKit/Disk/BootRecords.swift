import Foundation

/// Master / partition boot record writers. Port of Rufus' WriteMBR/WriteSBR/WritePBR
/// using the exact ms-sys boot code (see Resources/BootKit/bootrecords).
public enum BootRecords {

    public enum MBRCode: String, Codable, Sendable {
        case zero, windows7, rufus, rufusProtective, syslinux, syslinuxGPT, grub2, grub4dos, reactos, kolibri

        var resource: String {
            switch self {
            case .zero: return "mbr_zero"
            case .windows7: return "mbr_win7"
            case .rufus: return "mbr_rufus"
            case .rufusProtective: return "mbr_msg_rufus"
            case .syslinux: return "mbr_syslinux"
            case .syslinuxGPT: return "mbr_gpt_syslinux"
            case .grub2: return "mbr_grub2"
            case .grub4dos: return "mbr_grub"
            case .reactos: return "mbr_reactos"
            case .kolibri: return "mbr_kolibri"
            }
        }
    }

    public enum PBRCode: String, Codable, Sendable {
        case standard      // MS-DOS / Windows 9x style "IO.SYS" loader
        case windowsPE     // BOOTMGR (Vista and later)
        case windowsNT     // NTLDR (XP / WinPE 1.x)
        case freeDOS
        case reactOS
        case kolibri
    }

    // MARK: MBR

    /// Write MBR boot code (keeps disk signature and partition table) plus 0x55AA boot marks.
    public static func writeMBR(_ dev: RawDevice, code: MBRCode) throws {
        let bytes = try BootResources.bootRecord(code.resource)
        precondition(bytes.count <= 446)
        try dev.writeBytes(at: 0, bytes)
        try writeBootMarks(dev, at: 0)
        logInfo("Wrote \(code.rawValue) MBR boot code (\(bytes.count) bytes)")
    }

    static func writeBootMarks(_ dev: RawDevice, at offset: UInt64) throws {
        var pos: UInt64 = 0x1FE
        while pos < UInt64(dev.blockSize) {
            try dev.writeBytes(at: offset + pos, [0x55, 0xAA])
            pos += 0x200
        }
    }

    /// Set the boot indicator of an MBR partition entry (0x80 = first BIOS disk, 0x81 = masquerade as second disk).
    public static func setActive(_ dev: RawDevice, partitionIndex: Int, driveID: UInt8 = 0x80) throws {
        var mbr = try dev.readBytes(at: 0, count: 512)
        for i in 0..<4 { mbr[446 + 16 * i] = 0 }
        mbr[446 + 16 * partitionIndex] = driveID
        try dev.writeBytes(at: 0, mbr)
    }

    /// Patch Rufus' MBR so it uses a specific BIOS drive ID (Rufus "Use Rufus MBR with BIOS ID").
    /// The Rufus MBR reads its target drive from the boot indicator of the active partition.
    public static func setRufusMBRDriveID(_ dev: RawDevice, partitionIndex: Int, driveID: UInt8) throws {
        try setActive(dev, partitionIndex: partitionIndex, driveID: driveID)
    }

    // MARK: SBR (data right after the MBR)

    public enum SBR {
        case grub2Core
        case grub4dos
        case protectiveMessage
    }

    public static func writeSBR(_ dev: RawDevice, kind: SBR, firstPartitionOffset: UInt64, override: [UInt8]? = nil) throws {
        var brSize: UInt64 = 0x200
        let data: [UInt8]
        switch kind {
        case .grub2Core:
            data = try override ?? [UInt8](BootResources.data("grub2/core.img"))
        case .grub4dos:
            let d = [UInt8](try BootResources.data("grub/grldr.mbr"))
            data = Array(d.dropFirst(Int(brSize)))
        case .protectiveMessage:
            // 34 sectors are reserved for the protective MBR + primary GPT (512 byte sectors).
            brSize = 17 * 1024
            data = [UInt8](try BootResources.data("bootrecords/protective_msg.txt"))
        }
        guard brSize + UInt64(data.count) <= firstPartitionOffset else {
            throw BootKitError.generic("Secondary boot record does not fit before the first partition. Disable 'Add fixes for old BIOSes'.")
        }
        try dev.writeBytes(at: brSize, data)
        logInfo("Wrote \(kind) secondary boot record (\(data.count) bytes)")
    }

    // MARK: PBR

    /// Write the partition boot record of the FAT/NTFS volume starting at `partitionOffset`.
    /// The BIOS parameter block created by the formatter is preserved.
    public static func writePBR(_ dev: RawDevice, partitionOffset: UInt64, fileSystem: FileSystemType, code: PBRCode) throws {
        let ss = UInt64(dev.blockSize)
        func has(_ off: UInt64, _ magic: String) throws -> Bool {
            try dev.readBytes(at: partitionOffset + off, count: magic.utf8.count) == Array(magic.utf8)
        }
        func put(_ off: UInt64, _ name: String) throws {
            try dev.writeBytes(at: partitionOffset + off, try BootResources.bootRecord(name))
        }

        switch fileSystem {
        case .fat32:
            for copy in 0..<2 {
                let base: UInt64 = copy == 0 ? 0 : 6 * ss
                guard try has(base + 0x52, "FAT32   ") else {
                    throw BootKitError.generic("New volume does not have a \(copy == 0 ? "primary" : "backup") FAT32 boot sector.")
                }
                try put(base + 0x0, "br_fat32_0x0")
                switch code {
                case .standard:
                    try put(base + 0x52, "br_fat32_0x52"); try put(base + 0x3f0, "br_fat32_0x3f0")
                case .windowsPE:
                    try put(base + 0x52, "br_fat32pe_0x52"); try put(base + 0x3f0, "br_fat32pe_0x3f0"); try put(base + 0x1800, "br_fat32pe_0x1800")
                case .windowsNT:
                    try put(base + 0x52, "br_fat32nt_0x52"); try put(base + 0x3f0, "br_fat32nt_0x3f0"); try put(base + 0x1800, "br_fat32nt_0x1800")
                case .freeDOS:
                    try put(base + 0x52, "br_fat32fd_0x52"); try put(base + 0x3f0, "br_fat32fd_0x3f0")
                case .reactOS:
                    try put(base + 0x52, "br_fat32ros_0x52"); try put(base + 0x3f0, "br_fat32ros_0x3f0"); try put(base + 0x1c00, "br_fat32ros_0x1c00")
                case .kolibri:
                    try put(base + 0x52, "br_fat32kos_0x52")
                }
                // Physical drive number (0x80 = C:), needed by XP era loaders.
                try dev.writeBytes(at: partitionOffset + base + 0x40, [0x80])
            }
        case .fat16:
            guard try has(0x36, "FAT16   ") || has(0x36, "FAT12   ") else {
                throw BootKitError.generic("New volume does not have a FAT16 boot sector.")
            }
            switch code {
            case .freeDOS:
                try put(0x0, "br_fat16_0x0"); try put(0x3e, "br_fat16fd_0x3e")
            case .reactOS:
                try put(0x0, "br_fat16ros_0x0"); try put(0x3e, "br_fat16ros_0x3e")
            default:
                try put(0x0, "br_fat16_0x0"); try put(0x3e, "br_fat16_0x3e")
            }
            try dev.writeBytes(at: partitionOffset + 0x24, [0x80])
        case .ntfs:
            guard try has(0x3, "NTFS    ") else {
                throw BootKitError.generic("New volume does not have an NTFS boot sector.")
            }
            try put(0x0, "br_ntfs_0x0")
            try put(0x54, "br_ntfs_0x54")
        default:
            logDebug("No partition boot record needed for \(fileSystem.rawValue)")
            return
        }
        dev.sync()
        logInfo("Wrote \(code.rawValue) \(fileSystem.rawValue) partition boot record")
    }
}

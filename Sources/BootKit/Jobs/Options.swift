import Foundation

/// File systems that can be created on the target.
public enum FileSystemType: String, Codable, CaseIterable, Sendable, Identifiable {
    case fat16 = "FAT"
    case fat32 = "FAT32"
    case exfat = "exFAT"
    case ntfs = "NTFS"
    case udf = "UDF"
    case ext2 = "ext2"
    case ext3 = "ext3"
    case ext4 = "ext4"
    case hfsPlus = "Mac OS Extended (Journaled)"
    case apfs = "APFS"

    public var id: String { rawValue }

    public var isFAT: Bool { self == .fat16 || self == .fat32 }
    public var isExt: Bool { self == .ext2 || self == .ext3 || self == .ext4 }

    public var shortName: String {
        switch self {
        case .hfsPlus: return "HFS+"
        default: return rawValue
        }
    }

    public var mbrType: UInt8 {
        switch self {
        case .fat16: return 0x0e
        case .fat32: return 0x0c
        case .exfat, .ntfs, .udf: return 0x07
        case .ext2, .ext3, .ext4: return 0x83
        case .hfsPlus, .apfs: return 0xaf
        }
    }

    public var gptType: UUID {
        switch self {
        case .ext2, .ext3, .ext4: return GPTType.linuxData
        case .hfsPlus: return GPTType.appleHFS
        case .apfs: return GPTType.appleAPFS
        default: return GPTType.basicData
        }
    }

    /// Maximum volume size this file system can sensibly be created with.
    public var maxVolumeSize: UInt64 {
        switch self {
        case .fat16: return 4 * Units.GB
        case .fat32: return 2 * Units.TB  // newfs_msdos handles "large FAT32" fine
        default: return UInt64.max
        }
    }

    /// Maximum label length.
    public var maxLabelLength: Int {
        switch self {
        case .fat16, .fat32: return 11
        case .exfat: return 15
        case .ntfs: return 32
        case .ext2, .ext3, .ext4: return 16
        case .udf: return 30
        case .hfsPlus, .apfs: return 255
        }
    }

    /// Valid cluster sizes (bytes) for a volume of the given size. First entry is the default.
    public func clusterSizes(volumeSize: UInt64) -> [UInt32] {
        let k: UInt32 = 1024
        switch self {
        case .fat16:
            return [16 * k, 512, 1 * k, 2 * k, 4 * k, 8 * k, 32 * k, 64 * k]
        case .fat32:
            let def: UInt32
            if volumeSize < 8 * Units.GB { def = 4 * k }
            else if volumeSize < 16 * Units.GB { def = 8 * k }
            else if volumeSize < 32 * Units.GB { def = 16 * k }
            else { def = 32 * k }
            return [def] + [512, 1 * k, 2 * k, 4 * k, 8 * k, 16 * k, 32 * k, 64 * k].filter { $0 != def }
        case .exfat:
            let def: UInt32 = volumeSize <= 256 * Units.MB ? 4 * k : (volumeSize <= 32 * Units.GB ? 32 * k : 128 * k)
            return [def] + [4 * k, 8 * k, 16 * k, 32 * k, 64 * k, 128 * k, 256 * k, 512 * k, 1024 * k].filter { $0 != def }
        case .ntfs:
            return [4 * k, 512, 1 * k, 2 * k, 8 * k, 16 * k, 32 * k, 64 * k]
        case .udf:
            return [2 * k, 4 * k]
        case .ext2, .ext3, .ext4:
            return [4 * k, 1 * k, 2 * k]
        case .hfsPlus, .apfs:
            return [4 * k]
        }
    }
}

/// The firmware the media is meant to boot on (Rufus' "Target system").
public enum TargetSystem: String, Codable, CaseIterable, Sendable, Identifiable {
    case bios = "BIOS (or UEFI-CSM)"
    case uefi = "UEFI (non CSM)"
    case biosOrUefi = "BIOS or UEFI"
    public var id: String { rawValue }
}

/// Boot selection (Rufus' "Boot selection" combo).
public enum BootSelection: String, Codable, CaseIterable, Sendable, Identifiable {
    case image = "Disk or ISO image"
    case macInstaller = "macOS installer"
    case nonBootable = "Non bootable"
    case freeDOS = "FreeDOS"
    case syslinux6 = "Syslinux 6.04"
    case syslinux4 = "Syslinux 4.07"
    case grub2 = "GRUB 2.14"
    case uefiNTFS = "UEFI:NTFS"
    public var id: String { rawValue }

    /// Boot selections only shown with advanced drive properties visible (like Rufus).
    public var isAdvanced: Bool {
        switch self {
        case .syslinux6, .syslinux4, .grub2, .uefiNTFS: return true
        default: return false
        }
    }
}

/// How an image is written.
public enum WriteMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case iso = "ISO Image mode"          // extract files to a fresh file system
    case dd = "DD Image mode"            // raw sector copy
    case createInstallMedia = "macOS createinstallmedia"
    case asrRestore = "Apple Software Restore"
    public var id: String { rawValue }
}

/// Strategy for Windows images whose install.wim is larger than 4 GB.
public enum LargeWIMStrategy: String, Codable, CaseIterable, Sendable, Identifiable {
    case ntfsUEFINTFS = "NTFS + UEFI:NTFS (recommended, like Rufus)"
    case splitWIM = "FAT32 + split install.wim (needs wimlib)"
    case exfatUEFINTFS = "exFAT + UEFI:NTFS (UEFI only, Secure Boot off)"
    public var id: String { rawValue }
}

/// Bad block check configuration.
public struct BadBlocksOptions: Codable, Sendable, Equatable {
    public enum PatternSet: String, Codable, CaseIterable, Sendable, Identifiable {
        case onePass = "1 pass"
        case twoPasses = "2 passes"
        case slc = "4 passes for SLC NAND"
        case mlc = "4 passes for MLC NAND"
        case tlc = "4 passes for TLC NAND"
        public var id: String { rawValue }

        /// Test patterns, matching Rufus (rufus.h BADBLOCK_PATTERN_*). Multi-byte values
        /// (TLC) are repeated little-endian over the 3 bytes they span.
        public var patterns: [UInt32] {
            switch self {
            case .onePass: return [0x55]
            case .twoPasses: return [0x55, 0xaa]
            case .slc: return [0x00, 0xff, 0x55, 0xaa]
            case .mlc: return [0x00, 0xff, 0x33, 0xcc]
            case .tlc: return [0x00, 0xff, 0x1c71c7, 0xe38e38]
            }
        }
    }
    public var patternSet: PatternSet
    public init(patternSet: PatternSet = .onePass) { self.patternSet = patternSet }
}

/// Windows User Experience customization (Rufus' WUE dialog).
public struct WindowsCustomization: Codable, Sendable, Equatable {
    public var bypassRequirements = true          // TPM / Secure Boot / RAM
    public var noOnlineAccount = true             // BypassNRO
    public var localAccountName: String? = nil
    public var duplicateRegionalSettings = false
    public var disableDataCollection = false
    public var disableBitLocker = false
    public var qualityOfLife = false              // Copilot, OneDrive, Outlook, Fast Startup...
    public var forceSMode = false
    public var applySkuSiPolicy = false
    public var useCA2023Bootloaders = false
    public var silentInstall = false              // ⚠ wipes disk 0
    public var offlineInternalDrives = false      // Windows To Go only
    public var editionIndex: Int = 1              // install.wim image index (silent install)

    public init() {}

    public var isEmpty: Bool {
        !bypassRequirements && !noOnlineAccount && (localAccountName ?? "").isEmpty && !duplicateRegionalSettings
            && !disableDataCollection && !disableBitLocker && !qualityOfLife && !forceSMode && !applySkuSiPolicy
            && !useCA2023Bootloaders && !silentInstall && !offlineInternalDrives
    }

    /// Regional settings captured from the host (macOS) by the app.
    public var timeZone: String? = nil           // Windows time zone name, e.g. "W. Europe Standard Time"
    public var inputLocale: String? = nil        // e.g. "0409:00000409"
    public var systemLocale: String? = nil       // e.g. "en-US"
    public var uiLanguage: String? = nil
}

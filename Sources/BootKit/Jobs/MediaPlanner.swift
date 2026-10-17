import Foundation

/// Rufus-style automatic selection of sensible defaults, plus the set of valid choices,
/// for a given boot selection / image / drive.
public struct MediaRecommendation: Sendable, Equatable {
    public var writeMode: WriteMode
    public var scheme: PartitionScheme
    public var target: TargetSystem
    public var fileSystem: FileSystemType
    public var label: String
    public var largeWIMStrategy: LargeWIMStrategy = .ntfsUEFINTFS
    public var notes: [String] = []

    public init(writeMode: WriteMode, scheme: PartitionScheme, target: TargetSystem, fileSystem: FileSystemType, label: String,
                largeWIMStrategy: LargeWIMStrategy = .ntfsUEFINTFS, notes: [String] = []) {
        self.writeMode = writeMode
        self.scheme = scheme
        self.target = target
        self.fileSystem = fileSystem
        self.label = label
        self.largeWIMStrategy = largeWIMStrategy
        self.notes = notes
    }
}

public enum MediaPlanner {

    public static func recommend(image: ImageReport, disk: DiskInfo?) -> MediaRecommendation {
        let mode = image.recommendedWriteMode
        switch image.family {
        case .macOS:
            return MediaRecommendation(writeMode: image.mac?.isLegacyRestore == true ? .asrRestore : .createInstallMedia,
                                       scheme: .gpt, target: .uefi, fileSystem: .hfsPlus,
                                       label: "Install \(image.mac?.name ?? "macOS")")
        case .windows:
            var r = MediaRecommendation(writeMode: .iso, scheme: .gpt, target: .uefi, fileSystem: .fat32, label: image.label)
            if !image.hasEFI {
                r.scheme = .mbr
                r.target = .bios
                r.notes.append("This Windows image only supports legacy BIOS boot.")
            }
            if image.has4GBFile {
                // Like Rufus: NTFS + the (Secure Boot signed) UEFI:NTFS loader, written by the embedded ntfs-3g.
                r.fileSystem = .ntfs
                r.largeWIMStrategy = .ntfsUEFINTFS
                r.notes.append("install.wim is larger than 4 GB (the FAT32 limit): using NTFS + UEFI:NTFS, like Rufus. \(ExternalTool.wimlib.isAvailable ? "FAT32 with a split install.wim is also available." : "")")
            }
            return r
        default:
            if mode == .dd {
                return MediaRecommendation(writeMode: .dd, scheme: image.hasGPT ? .gpt : .mbr, target: .biosOrUefi, fileSystem: .fat32, label: image.label)
            }
            var r = MediaRecommendation(writeMode: .iso, scheme: .mbr, target: image.hasEFI ? .biosOrUefi : .bios, fileSystem: .fat32, label: image.label)
            if !(image.hasElToritoBIOS || !image.syslinuxConfigs.isEmpty || image.hasGrub2BIOS) && image.hasEFI {
                r.target = .uefi
            }
            if image.has4GBFile {
                r.fileSystem = .ntfs
                r.notes.append("This image contains a file larger than 4 GB: using NTFS + UEFI:NTFS.")
            }
            return r
        }
    }

    /// Recommendation when formatting without an image.
    public static func recommend(boot: BootSelection, disk: DiskInfo?) -> MediaRecommendation {
        let size = disk?.size ?? 16 * Units.GB
        let currentLabel = disk?.partitions.compactMap(\.volumeName).first { !$0.isEmpty }
        switch boot {
        case .freeDOS:
            return MediaRecommendation(writeMode: .iso, scheme: .mbr, target: .bios, fileSystem: size <= 2 * Units.GB ? .fat16 : .fat32, label: "FREEDOS")
        case .syslinux4, .syslinux6, .grub2:
            return MediaRecommendation(writeMode: .iso, scheme: .mbr, target: .bios, fileSystem: .fat32, label: boot == .grub2 ? "GRUB" : "SYSLINUX")
        case .uefiNTFS:
            return MediaRecommendation(writeMode: .iso, scheme: .gpt, target: .uefi, fileSystem: .ntfs, label: "UEFI_NTFS")
        default:
            return MediaRecommendation(writeMode: .iso, scheme: .mbr, target: .biosOrUefi,
                                       fileSystem: size > 32 * Units.GB ? .exfat : .fat32, label: currentLabel ?? "USB")
        }
    }

    /// File systems that make sense for the current choice.
    public static func fileSystems(boot: BootSelection, image: ImageReport?, writeMode: WriteMode) -> [FileSystemType] {
        switch boot {
        case .nonBootable:
            return [.fat32, .exfat, .ntfs, .fat16, .udf, .ext2, .ext3, .ext4, .hfsPlus, .apfs]
        case .freeDOS:
            return [.fat32, .fat16]
        case .syslinux4, .syslinux6, .grub2:
            return [.fat32, .fat16]
        case .uefiNTFS:
            return [.ntfs, .exfat]
        case .macInstaller:
            return [.hfsPlus]
        case .image:
            guard let image else { return [.fat32] }
            if writeMode == .dd || image.family == .macOS { return [] }
            var list: [FileSystemType] = [.fat32, .ntfs, .exfat]
            if !image.has4GBFile || image.isWindows { list.insert(.fat16, at: 1) }
            if image.projectedSize > 4 * Units.GB { list.removeAll { $0 == .fat16 } }
            return list
        }
    }

    public static func targets(boot: BootSelection, image: ImageReport?, scheme: PartitionScheme) -> [TargetSystem] {
        if scheme == .gpt { return [.uefi] }
        switch boot {
        case .nonBootable: return [.biosOrUefi]
        case .freeDOS, .syslinux4, .syslinux6, .grub2: return [.bios]
        case .uefiNTFS: return [.uefi]
        case .macInstaller: return [.uefi]
        case .image:
            guard let image else { return [.biosOrUefi] }
            let bios = image.hasElToritoBIOS || image.hasBootmgr || !image.syslinuxConfigs.isEmpty || image.hasGrub2BIOS || image.isWinPE
            if bios && image.hasEFI { return [.biosOrUefi, .bios, .uefi] }
            if image.hasEFI { return [.uefi] }
            return [.bios]
        }
    }
}

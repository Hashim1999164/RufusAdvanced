import Foundation

/// Everything we learned about a source image. Mirrors Rufus' RUFUS_IMG_REPORT.
public struct ImageReport: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case iso                 // ISO9660 / UDF optical image
        case rawDisk             // .img / .bin / .raw / hybrid disk image
        case compressedDisk      // .gz / .xz / .bz2 / .zst / .zip / .lzma containing a raw image
        case vhd                 // fixed VHD (raw + footer)
        case virtualDisk         // VHDX / dynamic VHD / VMDK / QCOW2 (needs qemu-img)
        case appleDiskImage      // .dmg
        case macInstallerApp     // Install macOS *.app
        case macInstallerPackage // InstallAssistant.pkg / InstallMacOSX.pkg
        case unknown
    }

    public enum OSFamily: String, Codable, Sendable {
        case windows, linux, macOS, freeDOS, other, unknown
    }

    public enum Compression: String, Codable, Sendable {
        case none, gzip, xz, bzip2, zstd, zip, lzma, sevenZip
    }

    public var path: String
    public var fileName: String
    public var size: UInt64
    public var kind: Kind
    public var compression: Compression = .none
    public var family: OSFamily = .unknown
    public var label: String = ""
    public var displayName: String = ""

    // Boot capabilities
    public var isHybrid = false               // ISOHybrid: can be DD'd
    public var hasMBRPartitionTable = false
    public var hasGPT = false
    public var hasElToritoBIOS = false
    public var hasElToritoEFI = false
    public var efiBootloaders: [String] = []  // e.g. /efi/boot/bootx64.efi
    public var hasEFI: Bool { !efiBootloaders.isEmpty || hasElToritoEFI }

    // Content
    public var projectedSize: UInt64 = 0      // sum of file sizes (ISO mode)
    public var largestFile: UInt64 = 0
    public var largestFilePath: String = ""
    public var fileCount = 0
    public var has4GBFile: Bool { largestFile >= 4 * Units.GB }
    public var hasMD5Sum = false
    public var hasSymlinks = false
    public var hasAutorun = false

    // Windows
    public var hasBootmgr = false
    public var hasBootmgrEFI = false
    public var windowsInstallImage: String?   // sources/install.wim|esd|swm
    public var windowsInstallImageSize: UInt64 = 0
    public var wim: WIMInfo?
    public var hasPantherUnattend = false
    public var isWinPE = false                // XP-era /i386 /amd64 /minint
    public var windowsBuild: Int? { wim?.build }

    // Linux
    public var syslinuxConfigs: [String] = []
    public var syslinuxVersion: String?
    public var hasGrub2BIOS = false
    public var grub2Version: String?
    public var grubConfigs: [String] = []
    public var usesCasper = false             // Ubuntu & derivatives
    public var usesDebianLive = false         // Debian live-boot
    public var isRedHat8Derivative = false
    public var hasKolibriOS = false
    public var hasReactOS = false

    // macOS
    public var mac: MacInstallerInfo?

    // Problems found while scanning (shown to the user).
    public var warnings: [String] = []

    public var supportsPersistence: Bool { usesCasper || usesDebianLive }
    public var isWindows: Bool { family == .windows }

    /// Whether ISO (file extraction) mode is possible.
    public var canUseISOMode: Bool {
        kind == .iso && (hasEFI || hasBootmgr || !syslinuxConfigs.isEmpty || hasGrub2BIOS || isWinPE || hasReactOS || hasKolibriOS)
    }

    /// Whether DD mode is possible.
    public var canUseDDMode: Bool {
        switch kind {
        case .rawDisk, .compressedDisk, .vhd, .virtualDisk, .appleDiskImage: return true
        case .iso: return isHybrid || hasGPT || hasMBRPartitionTable
        default: return false
        }
    }

    /// The write mode Rufus would recommend.
    public var recommendedWriteMode: WriteMode {
        switch kind {
        case .macInstallerApp, .macInstallerPackage: return .createInstallMedia
        case .appleDiskImage: return mac != nil ? .createInstallMedia : .dd
        case .iso:
            if family == .windows { return .iso }
            if canUseISOMode && !isHybrid { return .iso }
            // Hybrid Linux ISOs are most reliable in DD mode on a Mac (no Syslinux/GRUB BIOS reinstall needed).
            return isHybrid ? .dd : .iso
        default: return .dd
        }
    }

    /// Bootable-media summary line for the UI.
    public var summary: String {
        var parts: [String] = []
        if !displayName.isEmpty { parts.append(displayName) }
        if let mac { parts.append(mac.displayName) }
        if isHybrid { parts.append("ISOHybrid") }
        var fw: [String] = []
        if hasElToritoBIOS || hasBootmgr || !syslinuxConfigs.isEmpty || hasGrub2BIOS { fw.append("BIOS") }
        if hasEFI { fw.append("UEFI") }
        if !fw.isEmpty { parts.append(fw.joined(separator: "+")) }
        parts.append(Units.human(size))
        return parts.joined(separator: " · ")
    }
}

/// Information about a macOS installer.
public struct MacInstallerInfo: Codable, Sendable, Equatable {
    public var appPath: String?               // /Applications/Install macOS Sonoma.app
    public var name: String                   // macOS Sonoma
    public var version: String?               // 14.6.1
    public var build: String?
    public var hasCreateInstallMedia: Bool
    public var needsApplicationPath: Bool     // OS X 10.9 - 10.13 need --applicationpath
    public var isLegacyRestore: Bool          // Lion / Mountain Lion: asr restore of InstallESD
    public var requiresRosetta: Bool          // Intel-only createinstallmedia on Apple Silicon
    public var minimumUSBSize: UInt64

    public var displayName: String {
        [name, version].compactMap { $0 }.joined(separator: " ")
    }
}

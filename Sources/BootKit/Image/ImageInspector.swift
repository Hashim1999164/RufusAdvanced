import Foundation

/// Scans a source image and produces an `ImageReport` (Rufus' "Scanning image...").
public enum ImageInspector {

    public static func inspect(path: String, cancel: CancellationToken? = nil) throws -> ImageReport {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            throw BootKitError.generic("The file \(path) does not exist.")
        }
        let name = (path as NSString).lastPathComponent
        let ext = (path as NSString).pathExtension.lowercased()

        if isDir.boolValue {
            if ext == "app" {
                let mac = try MacInstallerInspector.inspectApp(path)
                var r = ImageReport(path: path, fileName: name, size: directorySize(path), kind: .macInstallerApp)
                r.family = .macOS
                r.mac = mac
                r.displayName = mac.displayName
                return r
            }
            // A macOS 10.13–10.15 product downloaded from Apple's catalog (packages + .dist).
            if let dist = (try? fm.contentsOfDirectory(atPath: path))?.first(where: { $0.hasSuffix(".dist") }) {
                var r = ImageReport(path: path, fileName: name, size: directorySize(path), kind: .macInstallerPackage)
                r.family = .macOS
                if let meta = DownloadMetadata.load(for: path), let mac = meta.macInstaller {
                    r.mac = mac
                } else if let text = try? String(contentsOfFile: path + "/" + dist, encoding: .utf8) {
                    let (title, version, build) = AppleCatalog.parseDist(text)
                    r.mac = MacInstallerInfo(appPath: nil, name: title ?? "macOS", version: version, build: build, hasCreateInstallMedia: true,
                                             needsApplicationPath: true, isLegacyRestore: false, requiresRosetta: false, minimumUSBSize: 7_500_000_000)
                }
                r.displayName = r.mac?.displayName ?? name
                return r
            }
            throw BootKitError.unsupportedImage("Folders are not supported (except macOS installer apps and downloaded macOS products).")
        }

        let size = (try? fm.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
        var report = ImageReport(path: path, fileName: name, size: size, kind: .unknown)

        if ext == "pkg" {
            report.kind = .macInstallerPackage
            report.family = .macOS
            report.mac = try MacInstallerInspector.inspectPackage(path)
            report.displayName = report.mac?.displayName ?? name
            return report
        }

        guard let fh = FileHandle(forReadingAtPath: path) else { throw BootKitError.openFailed(path, errno) }
        defer { try? fh.close() }
        let head = [UInt8](try fh.read(upToCount: 64 * 1024) ?? Data())
        func magic(_ bytes: [UInt8], at off: Int = 0) -> Bool {
            head.count >= off + bytes.count && Array(head[off..<(off + bytes.count)]) == bytes
        }

        // Compressed / archived images
        if magic([0x1F, 0x8B]) { report.kind = .compressedDisk; report.compression = .gzip }
        else if magic([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { report.kind = .compressedDisk; report.compression = .xz }
        else if magic(Array("BZh".utf8)) { report.kind = .compressedDisk; report.compression = .bzip2 }
        else if magic([0x28, 0xB5, 0x2F, 0xFD]) { report.kind = .compressedDisk; report.compression = .zstd }
        else if magic([0x50, 0x4B, 0x03, 0x04]) { report.kind = .compressedDisk; report.compression = .zip }
        else if magic([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { report.kind = .compressedDisk; report.compression = .sevenZip }
        else if ext == "lzma" { report.kind = .compressedDisk; report.compression = .lzma }
        if report.kind == .compressedDisk {
            report.family = .other
            report.displayName = "Compressed disk image (\(report.compression.rawValue))"
            report.isHybrid = true
            return report
        }

        // Virtual disks
        if magic(Array("vhdxfile".utf8)) || magic(Array("KDMV".utf8)) || magic([0x51, 0x46, 0x49, 0xFB]) {
            report.kind = .virtualDisk
            report.displayName = ext.uppercased() + " virtual disk"
            return report
        }
        if size >= 512 {
            try fh.seek(toOffset: size - 512)
            let footer = [UInt8](try fh.read(upToCount: 512) ?? Data())
            if footer.count == 512, Array(footer[0..<8]) == Array("conectix".utf8) {
                let diskType = UInt32(footer[60]) << 24 | UInt32(footer[61]) << 16 | UInt32(footer[62]) << 8 | UInt32(footer[63])
                report.kind = diskType == 2 ? .vhd : .virtualDisk
                report.displayName = diskType == 2 ? "Fixed VHD image" : "Dynamic VHD image"
                if diskType == 2 { try probePartitionTable(head, into: &report) }
                return report
            }
        }

        if ext == "dmg" || ext == "sparseimage" || ext == "sparsebundle" {
            report.kind = .appleDiskImage
            report.displayName = "Apple disk image"
            if let mac = try? MacInstallerInspector.inspectDMG(path) {
                report.mac = mac
                report.family = .macOS
                report.displayName = mac.displayName
            }
            return report
        }

        // Optical images
        let isISO9660 = magic(Array("CD001".utf8), at: 0x8001)
        let isUDF = (0..<8).contains { magic(Array("BEA01".utf8), at: 0x8001 + $0 * 2048) || magic(Array("NSR02".utf8), at: 0x8001 + $0 * 2048) || magic(Array("NSR03".utf8), at: 0x8001 + $0 * 2048) }
        try probePartitionTable(head, into: &report)

        if isISO9660 || isUDF {
            report.kind = .iso
            if isISO9660 {
                report.label = String(decoding: head[0x8028..<0x8048], as: UTF8.self).trimmingCharacters(in: .whitespaces.union(.controlCharacters))
                // Joliet labels keep case and spaces but are limited to 16 characters: only use one
                // when it is complete and names the same volume as the primary descriptor.
                if let joliet = jolietLabel(head), !joliet.isEmpty, joliet.count < 16 {
                    let norm = { (s: String) in s.uppercased().filter { $0.isLetter || $0.isNumber } }
                    if norm(joliet) == norm(report.label) { report.label = joliet }
                }
                parseElTorito(fh: fh, head: head, into: &report)
            }
            report.isHybrid = report.hasMBRPartitionTable || report.hasGPT
            try scanISOContents(path: path, report: &report, cancel: cancel)
        } else if report.hasMBRPartitionTable || report.hasGPT {
            report.kind = .rawDisk
            report.family = .other
            report.displayName = "Disk image"
        } else {
            report.kind = .rawDisk
            report.displayName = "Raw image (no partition table found)"
            report.warnings.append("This image does not look bootable (no partition table). It will be written as-is in DD mode.")
        }
        return report
    }

    /// Volume identifier from a Joliet supplementary volume descriptor (UCS-2 BE).
    static func jolietLabel(_ head: [UInt8]) -> String? {
        for sector in 17..<32 {
            let off = sector * 2048
            guard head.count >= off + 0x60 else { break }
            if head[off] == 0xFF { break }
            guard head[off] == 2, Array(head[(off + 1)..<(off + 6)]) == Array("CD001".utf8) else { continue }
            let esc = Array(head[(off + 0x58)..<(off + 0x5B)])
            guard esc == [0x25, 0x2F, 0x40] || esc == [0x25, 0x2F, 0x43] || esc == [0x25, 0x2F, 0x45] else { continue }
            var units: [UInt16] = []
            for i in stride(from: 0, to: 32, by: 2) { units.append(UInt16(head[off + 0x28 + i]) << 8 | UInt16(head[off + 0x29 + i])) }
            return String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespaces.union(.controlCharacters))
        }
        return nil
    }

    // MARK: Partition table / El Torito

    static func probePartitionTable(_ head: [UInt8], into r: inout ImageReport) throws {
        guard head.count >= 1024, head[510] == 0x55, head[511] == 0xAA else { return }
        var any = false
        for i in 0..<4 {
            let o = 446 + 16 * i
            let type = head[o + 4]
            let sectors = LE.get32(head, o + 12)
            if type != 0 && sectors != 0 { any = true }
            if type == 0xEE { r.hasGPT = true }
        }
        if Array(head[512..<520]) == Array("EFI PART".utf8) { r.hasGPT = true }
        r.hasMBRPartitionTable = any && !r.hasGPT
    }

    static func parseElTorito(fh: FileHandle, head: [UInt8], into r: inout ImageReport) {
        // Volume descriptors start at sector 16; find the boot record (type 0, "EL TORITO SPECIFICATION").
        for sector in 16..<32 {
            let off = sector * 2048
            guard head.count >= off + 0x4B else { break }
            if head[off] == 0xFF { break }
            guard head[off] == 0, Array(head[(off + 7)..<(off + 30)]) == Array("EL TORITO SPECIFICATION".utf8) else { continue }
            let catalog = UInt64(LE.get32(head, off + 0x47))
            guard (try? fh.seek(toOffset: catalog * 2048)) != nil,
                  let cat = try? fh.read(upToCount: 2048).map({ [UInt8]($0) }), cat.count == 2048 else { return }
            // Validation entry: platform at byte 1. Then default entry, then section headers.
            if cat[0] == 0x01 {
                if cat[1] == 0x00 { r.hasElToritoBIOS = true }
                if cat[1] == 0xEF { r.hasElToritoEFI = true }
            }
            var i = 64
            while i + 32 <= cat.count {
                let indicator = cat[i]
                if indicator == 0x90 || indicator == 0x91 {
                    if cat[i + 1] == 0xEF { r.hasElToritoEFI = true }
                    if cat[i + 1] == 0x00 { r.hasElToritoBIOS = true }
                } else if indicator == 0 && cat[i + 1] == 0 {
                    break
                }
                i += 32
            }
            return
        }
    }

    // MARK: Content scan

    static let syslinuxConfigNames: Set<String> = ["isolinux.cfg", "syslinux.cfg", "extlinux.conf", "txt.cfg", "live.cfg"]

    static func scanISOContents(path: String, report r: inout ImageReport, cancel: CancellationToken?) throws {
        let mount: DiskImageMount
        do {
            mount = try DiskImageMount(imagePath: path)
        } catch {
            r.warnings.append("Could not open the image contents: \(error.userMessage)")
            return
        }
        defer { mount.detach() }
        guard let root = mount.primaryMountPoint else {
            r.warnings.append("The image could not be mounted for inspection.")
            return
        }
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: root) else { return }

        var linuxHints = 0
        var winpeFiles = Set<String>()
        while let relRaw = e.nextObject() as? String {
            try cancel?.check()
            let attrs = e.fileAttributes ?? [:]
            let type = attrs[.type] as? FileAttributeType
            let rel = "/" + relRaw.lowercased()   // "/efi/boot/bootx64.efi"
            let url = URL(fileURLWithPath: root + "/" + relRaw)
            let base = (rel as NSString).lastPathComponent
            let dir = (rel as NSString).deletingLastPathComponent
            if type == .typeSymbolicLink { r.hasSymlinks = true; continue }
            if type == .typeDirectory {
                if rel == "/casper" { r.usesCasper = true }
                if rel == "/boot/grub/i386-pc" || rel == "/boot/grub2/i386-pc" { r.hasGrub2BIOS = true }
                continue
            }
            let fsize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            r.fileCount += 1
            r.projectedSize += Units.alignUp(fsize, 2048)
            if fsize > r.largestFile { r.largestFile = fsize; r.largestFilePath = rel }

            switch rel {
            case "/bootmgr": r.hasBootmgr = true
            case "/bootmgr.efi": r.hasBootmgrEFI = true
            case "/autorun.inf": r.hasAutorun = true
            case "/md5sum.txt", "/md5sums": r.hasMD5Sum = true
            case "/sources/install.wim", "/sources/install.esd", "/sources/install.swm":
                r.windowsInstallImage = rel
                r.windowsInstallImageSize = fsize
                r.wim = try? WIMInfo.read(path: url.path)
            case "/sources/$oem$/$$/panther/unattend.xml": r.hasPantherUnattend = true
            case "/.treeinfo": r.isRedHat8Derivative = true
            default: break
            }
            if dir == "/efi/boot", base.hasPrefix("boot"), base.hasSuffix(".efi") {
                r.efiBootloaders.append(rel)
            }
            if syslinuxConfigNames.contains(base) {
                r.syslinuxConfigs.append(rel)
                linuxHints += 1
            }
            if base == "isolinux.bin" || base == "syslinux.bin", r.syslinuxVersion == nil {
                r.syslinuxVersion = versionString(in: url.path, prefixes: ["ISOLINUX ", "SYSLINUX "])
            }
            if base == "grub.cfg" || base == "loopback.cfg" {
                r.grubConfigs.append(rel)
                linuxHints += 1
                if let s = try? String(contentsOfFile: url.path, encoding: .utf8), s.contains("inst.stage2") { r.isRedHat8Derivative = true }
            }
            if (dir == "/boot/grub/i386-pc" || dir == "/boot/grub2/i386-pc") && base == "normal.mod" && r.grub2Version == nil {
                r.grub2Version = versionString(in: url.path, prefixes: ["GRUB  version ", "GRUB version "])
            }
            if dir == "/live" && base.hasSuffix(".squashfs") { r.usesDebianLive = true }
            if dir.hasPrefix("/casper") && base.hasSuffix(".squashfs") { r.usesCasper = true }
            if base.hasPrefix("vmlinuz") || base == "initrd" || base.hasPrefix("initrd.") { linuxHints += 1 }
            if ["/i386", "/amd64", "/minint"].contains(dir), ["ntdetect.com", "setupldr.bin", "txtsetup.sif"].contains(base) {
                winpeFiles.insert(base)
            }
            if base == "kolibri.img" { r.hasKolibriOS = true }
            if base == "freeldr.sys" || base == "setupldr.sys" { r.hasReactOS = true }
        }
        r.isWinPE = winpeFiles.count >= 2 && r.windowsInstallImage == nil

        if r.windowsInstallImage != nil || r.hasBootmgr || r.isWinPE {
            r.family = .windows
            if let wim = r.wim, let v = wim.versionName {
                r.displayName = v + (wim.arch.map { " \($0)" } ?? "")
            } else {
                r.displayName = r.isWinPE ? "Windows XP / WinPE" : "Windows installer"
            }
        } else if linuxHints > 0 || r.usesCasper || r.usesDebianLive {
            r.family = .linux
            r.displayName = prettyLabel(r.label)
        } else {
            r.family = .other
            r.displayName = prettyLabel(r.label)
        }
        if r.hasSymlinks {
            r.warnings.append("This image contains symbolic links, which FAT cannot store. DD mode is recommended.")
        }
    }

    static func prettyLabel(_ l: String) -> String {
        l.isEmpty ? "Bootable ISO" : l.replacingOccurrences(of: "_", with: " ")
    }

    /// Search the first 2 MB of a binary for "<prefix><version>".
    static func versionString(in path: String, prefixes: [String]) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path), let data = try? fh.read(upToCount: 2 * Int(Units.MB)) else { return nil }
        try? fh.close()
        let s = String(decoding: data.map { ($0 >= 0x20 && $0 < 0x7f) ? $0 : 0x20 }, as: UTF8.self)
        for p in prefixes {
            if let r = s.range(of: p) {
                let tail = s[r.upperBound...].prefix(16)
                let v = tail.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0.isLetter && $0 != " " }
                if !v.isEmpty { return String(v) }
            }
        }
        return nil
    }

    static func directorySize(_ path: String) -> UInt64 {
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let u as URL in e { total += UInt64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }
}

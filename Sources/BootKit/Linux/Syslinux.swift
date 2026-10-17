import Foundation

/// Syslinux installer for FAT volumes (port of syslinux' libinstaller as used by Rufus).
public enum SyslinuxInstaller {
    static let ldlinuxMagic: UInt32 = 0x3EB2_02FE
    static let advMagic1: UInt32 = 0x5A2D_2FA5
    static let advMagic2: UInt32 = 0xA304_1767
    static let advMagic3: UInt32 = 0xDD28_BF64
    static let advSize = 512

    /// Bundled versions (from Rufus): 4.07 and 6.04.
    public static func bundledFiles(major: Int) throws -> (sys: [UInt8], bss: [UInt8]) {
        let v = major >= 5 ? "v6" : "v4"
        return ([UInt8](try BootResources.data("syslinux/ldlinux_\(v).sys")), [UInt8](try BootResources.data("syslinux/ldlinux_\(v).bss")))
    }

    public static func isBundled(_ version: String) -> Bool {
        version.hasPrefix("4.07") || version == "6.04" || version.hasPrefix("6.04-pre1")
    }

    /// Empty Auxiliary Data Vector (two identical 512 byte copies).
    static func emptyADV() -> [UInt8] {
        var adv = [UInt8](repeating: 0, count: advSize)
        LE.put32(&adv, 0, advMagic1)
        var csum = advMagic2
        for i in stride(from: 8, to: advSize - 4, by: 4) { csum = csum &- LE.get32(adv, i) }
        LE.put32(&adv, 4, csum)
        LE.put32(&adv, advSize - 4, advMagic3)
        return adv + adv
    }

    /// Patch ldlinux.sys (`image`) and the boot sector template (`bss`) for the given sector map.
    /// Port of syslinux_patch(). `sectors` are relative to the start of the file system.
    static func patch(image: inout [UInt8], bss: inout [UInt8], sectors: [UInt64], sectorSize: Int, subdir: String?) throws {
        let nsect = (image.count + sectorSize - 1) / sectorSize + 2
        guard sectors.count >= nsect else { throw BootKitError.generic("Syslinux: ldlinux.sys is fragmented or too small on disk") }
        // Find the patch area.
        var pa = -1
        var i = 0
        while i + 4 <= image.count - 32 {
            if LE.get32(image, i) == ldlinuxMagic { pa = i; break }
            i += 4
        }
        guard pa >= 0 else { throw BootKitError.generic("Syslinux: patch area not found in ldlinux.sys") }
        // struct patch_area: magic, instance, data_sectors(u16), adv_sectors(u16), dwords, checksum, maxtransfer(u16), epaoffset(u16)
        let epa = Int(LE.get16(image, pa + 22))
        let advptroffset = Int(LE.get16(image, epa + 0))
        let diroffset = Int(LE.get16(image, epa + 2))
        let dirlen = Int(LE.get16(image, epa + 4))
        let secptroffset = Int(LE.get16(image, epa + 10))
        let secptrcnt = Int(LE.get16(image, epa + 12))
        let sect1ptr0 = Int(LE.get16(image, epa + 14))
        let sect1ptr1 = Int(LE.get16(image, epa + 16))

        // First sector pointer lives in the boot sector.
        LE.put32(&bss, sect1ptr0, UInt32(sectors[0] & 0xFFFF_FFFF))
        LE.put32(&bss, sect1ptr1, UInt32(sectors[0] >> 32))
        let rest = Array(sectors.dropFirst())

        let dw = image.count >> 2
        LE.put16(&image, pa + 8, UInt16(nsect - 2))  // data_sectors
        LE.put16(&image, pa + 10, 2)                 // adv_sectors
        LE.put32(&image, pa + 12, UInt32(dw))        // dwords

        // Sector extents (generate_extents)
        let extentCount = nsect - 1 - 2
        for k in 0..<(secptrcnt * 10) where secptroffset + k < image.count { image[secptroffset + k] = 0 }
        var ex = secptroffset
        var addr: UInt32 = 0x8000
        var base: UInt32 = addr
        var len: UInt32 = 0
        var lba: UInt64 = 0
        var written = 0
        func flush() {
            guard written < secptrcnt else { return }
            LE.put64(&image, ex, lba)
            LE.put16(&image, ex + 8, UInt16(len))
            ex += 10
            written += 1
        }
        for k in 0..<extentCount {
            let sect = rest[k]
            if len > 0 {
                let xbytes = (len + 1) * UInt32(sectorSize)
                if sect == lba + UInt64(len) && xbytes < 65536 && ((addr ^ (base + xbytes - 1)) & 0xFFFF_0000) == 0 {
                    len += 1
                    addr += UInt32(sectorSize)
                    continue
                }
                flush()
            }
            base = addr
            lba = sect
            len = 1
            addr += UInt32(sectorSize)
        }
        if len > 0 { flush() }

        // ADV pointers
        LE.put64(&image, advptroffset, rest[nsect - 1 - 2])
        LE.put64(&image, advptroffset + 8, rest[nsect - 1 - 1])

        if let subdir {
            let bytes = Array(subdir.utf8) + [0]
            guard dirlen >= bytes.count else { throw BootKitError.generic("Syslinux: directory path too long") }
            image.replaceSubrange(diroffset..<(diroffset + bytes.count), with: bytes)
        }

        // Checksum
        LE.put32(&image, pa + 16, 0)
        var csum = ldlinuxMagic
        for k in 0..<dw { csum = csum &- LE.get32(image, k * 4) }
        LE.put32(&image, pa + 16, csum)
    }

    /// Install Syslinux on the FAT volume `slice` (mounted at `mountPoint`).
    /// The volume is unmounted during the raw patching and remounted afterwards.
    public static func install(sys: [UInt8], bss: [UInt8], slice: String, mountPoint: String, subdir: String?) throws {
        logInfo("Installing Syslinux (\(sys.count) byte ldlinux.sys)\(subdir.map { ", config dir '\($0)'" } ?? "")")
        let ldPath = (mountPoint as NSString).appendingPathComponent("ldlinux.sys")
        try? FileManager.default.removeItem(atPath: ldPath)
        let fileData = Data(sys + emptyADV())
        guard FileManager.default.createFile(atPath: ldPath, contents: fileData) else {
            throw BootKitError.writeFailed(ldPath, errno)
        }
        _ = try? Shell.run("/usr/bin/chflags", ["hidden", ldPath], logCommand: false)
        // Flush and release the volume so the FAT on disk is final.
        Darwin.sync()
        DiskUtil.unmount(slice)
        if DiskUtil.mountPointOf(slice) != nil { DiskUtil.unmount(slice, force: true) }

        let dev = try RawDevice(path: "/dev/r\(slice)", writable: true)
        defer { dev.close() }
        let fat = try FATVolume(device: dev)
        guard let entry = try fat.findRootFile(shortName: "LDLINUX SYS") else {
            throw BootKitError.generic("Syslinux: ldlinux.sys not found in the root directory")
        }
        let ss = Int(fat.bytesPerSector)
        let needed = (fileData.count + ss - 1) / ss
        let sectors = Array(try fat.sectors(ofChainStarting: entry.cluster).prefix(needed))

        var image = sys
        var bootTemplate = bss
        try patch(image: &image, bss: &bootTemplate, sectors: sectors, sectorSize: ss, subdir: subdir)

        // Rewrite the patched ldlinux.sys data sectors.
        let padded = image + [UInt8](repeating: 0, count: (ss - image.count % ss) % ss)
        for (k, s) in sectors.enumerated() where k * ss < padded.count {
            try dev.writeBytes(at: s * UInt64(ss), Array(padded[(k * ss)..<((k + 1) * ss)]))
        }
        // Merge the Syslinux boot code into the existing boot sector (keeping the BPB).
        var bs = try dev.readBytes(at: 0, count: 512)
        bs.replaceSubrange(0..<0x0B, with: bootTemplate[0..<0x0B])
        bs.replaceSubrange(0x5A..<0x1FE, with: bootTemplate[0x5A..<0x1FE])
        try dev.writeBytes(at: 0, bs)
        dev.sync()
        dev.close()
        try DiskUtil.mount(slice, at: mountPoint)
        logInfo("Syslinux installed")
    }

    /// Choose the Syslinux config to use and create a root /syslinux.cfg pointing to it (Rufus behaviour).
    /// Returns the subdirectory to patch into ldlinux.sys.
    public static func prepareConfig(mountPoint: String, image: ImageReport) -> String? {
        let candidates = image.syslinuxConfigs.filter {
            let b = ($0 as NSString).lastPathComponent
            return b == "isolinux.cfg" || b == "syslinux.cfg" || b == "extlinux.conf"
        }
        guard !candidates.isEmpty else { return nil }
        var chosen = candidates.first { $0 == "/boot/i386/loader/isolinux.cfg" || $0 == "/boot/x86_64/loader/isolinux.cfg" }
        if chosen == nil {
            // Shortest path wins; at equal length, the later entry (Tails: /isolinux over /efi/boot).
            chosen = candidates.reduce(nil as String?) { best, c in
                guard let b = best else { return c }
                return c.count <= b.count ? c : b
            }
        }
        guard let cfg = chosen else { return nil }
        let fm = FileManager.default
        // Find the real (case preserved) path on the target.
        let real = resolveCase(cfg, root: mountPoint) ?? cfg
        let dir = (real as NSString).deletingLastPathComponent
        let rootCfg = mountPoint + "/syslinux.cfg"
        if real != "/syslinux.cfg" {
            if fm.fileExists(atPath: rootCfg) { try? fm.moveItem(atPath: rootCfg, toPath: mountPoint + "/syslinux.org") }
            var text = "DEFAULT loadconfig\n\nLABEL loadconfig\n  CONFIG \(real)\n"
            if dir != "/" { text += "  APPEND \(dir)/\n" }
            try? text.write(toFile: rootCfg, atomically: true, encoding: .utf8)
            logInfo("Created /syslinux.cfg → \(real)")
        }
        // Tails & co: duplicate /efi/boot/isolinux.cfg as syslinux.cfg.
        if let efiCfg = resolveCase("/efi/boot/isolinux.cfg", root: mountPoint),
           resolveCase("/efi/boot/syslinux.cfg", root: mountPoint) == nil {
            let src = mountPoint + efiCfg
            try? fm.copyItem(atPath: src, toPath: (src as NSString).deletingLastPathComponent + "/syslinux.cfg")
        }
        return dir == "/" ? "" : dir
    }

    /// Case-insensitive path lookup on a mounted volume.
    static func resolveCase(_ path: String, root: String) -> String? {
        var current = ""
        for comp in path.split(separator: "/") {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: root + (current.isEmpty ? "/" : current)),
                  let match = items.first(where: { $0.caseInsensitiveCompare(String(comp)) == .orderedSame }) else { return nil }
            current += "/" + match
        }
        return current.isEmpty ? nil : current
    }
}

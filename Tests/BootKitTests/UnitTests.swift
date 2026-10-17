import Foundation
import Testing
@testable import BootKit

@Suite struct LayoutTests {
    @Test func mbrLayoutWithPersistenceAndUEFINTFS() throws {
        var r = LayoutPlanner.Request(diskSize: 16 * Units.GB, sectorSize: 512, scheme: .mbr, fileSystem: .exfat, bootable: true, targetSystem: .biosOrUefi)
        r.persistenceSize = 4 * Units.GB
        r.uefiNTFSSize = Units.MB
        let l = try LayoutPlanner.plan(r)
        #expect(l.partitions.map(\.role) == [.main, .persistence, .uefiNTFS])
        #expect(l.partitions[0].offset == Units.MB)
        #expect(l.partitions[0].mbrType == 0x07)
        #expect(l.partitions[1].mbrType == 0x83)
        #expect(l.partitions[2].mbrType == 0xef)
        for p in l.partitions { #expect(p.offset % Units.MB == 0) }
        for (a, b) in zip(l.partitions, l.partitions.dropFirst()) { #expect(a.end <= b.offset) }
        #expect(l.partitions.last!.end <= 16 * Units.GB)
    }

    @Test func gptLeavesRoomForBackupHeader() throws {
        let size: UInt64 = 8 * Units.GB
        let l = try LayoutPlanner.plan(.init(diskSize: size, sectorSize: 512, scheme: .gpt, fileSystem: .fat32, bootable: true, targetSystem: .uefi))
        #expect(l.partitions[0].end <= size - 33 * 512)
        #expect(l.mbrSignature != LayoutPlanner.mbrUEFIMarker)
    }

    @Test func mbrUEFIMarker() throws {
        let l = try LayoutPlanner.plan(.init(diskSize: 8 * Units.GB, sectorSize: 512, scheme: .mbr, fileSystem: .fat32, bootable: true, targetSystem: .uefi))
        #expect(l.mbrSignature == 0x4946_4555)
    }

    @Test func mbrIsCappedAt2TiB() throws {
        let l = try LayoutPlanner.plan(.init(diskSize: 4 * Units.TB, sectorSize: 512, scheme: .mbr, fileSystem: .exfat, bootable: false, targetSystem: .biosOrUefi))
        #expect(l.partitions[0].end <= UInt64(UInt32.max) * 512)
    }

    @Test func tooSmallDiskThrows() {
        #expect(throws: BootKitError.self) {
            _ = try LayoutPlanner.plan(.init(diskSize: 4 * Units.MB, sectorSize: 512, scheme: .gpt, fileSystem: .fat32, bootable: true, targetSystem: .uefi))
        }
    }

    @Test func oldBiosFixesAddCompatPartition() throws {
        var r = LayoutPlanner.Request(diskSize: 4 * Units.GB, sectorSize: 512, scheme: .mbr, fileSystem: .fat32, bootable: true, targetSystem: .bios)
        r.oldBIOSFixes = true
        let l = try LayoutPlanner.plan(r)
        #expect(l.partitions.last?.role == .compat)
        #expect(l.partitions[0].offset == 64512)   // Rufus: 2 x (63 sector track aligned to the cluster size)
    }
}

@Suite struct PartitionTableTests {
    @Test func gptStructuresHaveValidCRCs() throws {
        let path = NSTemporaryDirectory() + "gpt-\(UUID().uuidString).img"
        FileManager.default.createFile(atPath: path, contents: nil)
        let fh = FileHandle(forWritingAtPath: path)!
        try fh.truncate(atOffset: 64 * Units.MB); try fh.close()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let dev = try RawDevice(path: path, writable: true)
        let layout = try LayoutPlanner.plan(.init(diskSize: dev.size, sectorSize: 512, scheme: .gpt, fileSystem: .fat32, bootable: true, targetSystem: .uefi))
        try PartitionTableWriter.write(layout, to: dev)
        for lba in [UInt64(1), dev.size / 512 - 1] {
            var hdr = try dev.readBytes(at: lba * 512, count: 92)
            let stored = LE.get32(hdr, 16)
            LE.put32(&hdr, 16, 0)
            #expect(CRC32.checksum(hdr) == stored)
            let entriesLBA = LE.get64(hdr, 72)
            let entries = try dev.readBytes(at: entriesLBA * 512, count: 128 * 128)
            #expect(CRC32.checksum(entries) == LE.get32(hdr, 88))
        }
        let mbr = try dev.readBytes(at: 0, count: 512)
        #expect(mbr[446 + 4] == 0xEE)
        let (scheme, parts) = try PartitionTableWriter.read(from: dev)
        #expect(scheme == .gpt)
        #expect(parts.first?.gptType == GPTType.basicData)
        #expect(parts.first?.startLBA == 2048)
    }

    @Test func guidMixedEndianRoundTrip() {
        let u = GPTType.efiSystem
        #expect(u.gptBytes.prefix(4) == [0x28, 0x73, 0x2A, 0xC1])
        #expect(UUID(gptBytes: u.gptBytes) == u)
    }

    @Test func chsBeyond1024CylindersSaturates() {
        #expect(PartitionTableWriter.chs(100_000_000) == [0xFE, 0xFF, 0xFF])
        #expect(PartitionTableWriter.chs(2048) == [32, 33, 0])
    }
}

@Suite struct LabelTests {
    @Test(arguments: [
        ("Win11 24h2 x64", FileSystemType.fat32, "WIN11 24H2 "),
        ("ubuntu-26.04", .fat32, "UBUNTU-26_0"),
        ("Données", .fat32, "DONN_ES"),
        ("a*b?c", .fat32, "ABC"),
        ("My Long exFAT label!", .exfat, "My Long exFAT l"),
        ("persistence", .ext3, "persistence"),
    ])
    func validLabels(_ input: String, _ fs: FileSystemType, _ expected: String) {
        #expect(Formatter.validLabel(input, for: fs) == expected.trimmingCharacters(in: .whitespaces))
    }
}

@Suite struct WindowsTests {
    @Test func unattendWithBypassAndLocalAccount() throws {
        var c = WindowsCustomization()
        c.bypassRequirements = true
        c.noOnlineAccount = true
        c.localAccountName = "Ehti"
        c.disableBitLocker = true
        let r = try #require(Unattend.generate(c, arch: "amd64"))
        #expect(r.hasWindowsPEPass)
        #expect(r.xml.contains("BypassTPMCheck") && r.xml.contains("BypassSecureBootCheck") && r.xml.contains("BypassRAMCheck"))
        #expect(r.xml.contains("BypassNRO"))
        #expect(r.xml.contains("<Name>Ehti</Name>"))
        #expect(r.xml.contains("PreventDeviceEncryption"))
        #expect(r.xml.contains("net user &quot;Ehti&quot; /logonpasswordchg:yes"))
        // Well-formed XML
        _ = try XMLDocument(xmlString: r.xml)
    }

    @Test func noOptionsMeansNoAnswerFile() {
        var c = WindowsCustomization()
        c.bypassRequirements = false
        c.noOnlineAccount = false
        #expect(Unattend.generate(c, arch: "amd64") == nil)
    }

    @Test func reservedAccountNamesAreRejected() {
        #expect(Unattend.sanitize(user: "Administrator") == nil)
        #expect(Unattend.sanitize(user: "guest") == nil)
        #expect(Unattend.sanitize(user: "a/b:c") == "a_b_c")
    }

    @Test func specializeOnlyGoesToPanther() throws {
        var c = WindowsCustomization()
        c.bypassRequirements = false
        c.noOnlineAccount = true
        let r = try #require(Unattend.generate(c, arch: "arm64"))
        #expect(!r.hasWindowsPEPass)
        #expect(r.xml.contains("processorArchitecture=\"arm64\""))
        _ = try XMLDocument(xmlString: r.xml)
    }

    @Test func fullOptionSetIsWellFormed() throws {
        var c = WindowsCustomization()
        c.disableDataCollection = true; c.duplicateRegionalSettings = true; c.qualityOfLife = true
        c.applySkuSiPolicy = true; c.silentInstall = true; c.forceSMode = true; c.timeZone = "Romance Standard Time"
        let r = try #require(Unattend.generate(c, arch: "amd64"))
        _ = try XMLDocument(xmlString: r.xml)
        #expect(r.xml.contains("<TimeZone>Romance Standard Time</TimeZone>"))
        #expect(r.xml.contains("SkuPolicyRequired"))
        #expect(r.xml.contains("WillWipeDisk"))
    }

    @Test func wimXmlParsing() {
        let xml = """
        <WIM><TOTALBYTES>1</TOTALBYTES><IMAGE INDEX="1"><NAME>Windows 11 Home</NAME><WINDOWS><ARCH>9</ARCH><EDITIONID>Core</EDITIONID>
        <LANGUAGES><LANGUAGE>en-US</LANGUAGE></LANGUAGES><VERSION><MAJOR>10</MAJOR><MINOR>0</MINOR><BUILD>26100</BUILD><SPBUILD>1742</SPBUILD></VERSION></WINDOWS></IMAGE>
        <IMAGE INDEX="2"><DISPLAYNAME>Windows 11 Pro</DISPLAYNAME><NAME>Windows 11 Pro</NAME><WINDOWS><ARCH>12</ARCH><VERSION><MAJOR>10</MAJOR><BUILD>26100</BUILD></VERSION></WINDOWS></IMAGE></WIM>
        """
        let images = WIMInfo.parseImages(xml)
        #expect(images.count == 2)
        #expect(images[0].arch == "x64" && images[0].editionID == "Core" && images[0].spBuild == 1742)
        #expect(images[1].arch == "arm64" && images[1].title == "Windows 11 Pro")
        let info = WIMInfo(images: images, partNumber: 1, totalParts: 1, bootIndex: 0)
        #expect(info.versionName == "Windows 11 24H2 (build 26100.1742)")
    }

    @Test func timeZoneMapping() {
        #expect(WindowsTimeZones.windowsName(for: "Europe/Paris") == "Romance Standard Time")
        #expect(WindowsTimeZones.windowsName(for: "Asia/Karachi") == "Pakistan Standard Time")
        #expect(WindowsTimeZones.windowsName(for: "America/New_York") == "Eastern Standard Time")
    }

    @Test func fidoTableParsing() {
        let text = """
        $WindowsVersions = @(
        \t@(
        \t\t@("Windows 11", "windows11"),
        \t\t@(
        \t\t\t"26H2 (Build 26300.9457 - 2026.09)",
        \t\t\t@("Windows 11 Home/Pro/Edu", @(3813, 3816)),
        \t\t\t@("Windows 11 Home China ", @(3814, 3817))
        \t\t)
        \t),
        \t@(
        \t\t@("Windows 10", "Windows10ISO"),
        \t\t@(
        \t\t\t"22H2 v1 (Build 19045.2965 - 2023.05)",
        \t\t\t@("Windows 10 Home/Pro/Edu", 2618)
        \t\t)
        \t)
        )
        #endregion
        """
        let products = MicrosoftISO.parseFido(text)
        #expect(products?.count == 2)
        #expect(products?[0].releases.first?.editions.first?.productEditionIDs == [3813, 3816])
        #expect(products?[1].releases.first?.editions.first?.productEditionIDs == [2618])
    }
}

@Suite struct CatalogParsingTests {
    @Test func checksumFormats() {
        let text = """
        faabcf33ae53976d2b8207a001ff32f4e5daae013505ac7188c9ea63988f8328 *ubuntu-24.04.3-desktop-amd64.iso
        a7ef94ac2fb9a7fec454552abd629b7cc9d5155c886165a45649f5ce6167e355  debian-13.7.0-amd64-netinst.iso
        SHA256 (Rocky-10.2-x86_64-dvd1.iso) = 16ca9c96cdb221ba6e1f68579f21bd69fd8da81c6a921d9068949796f91c8feb
        # comment line
        """
        let sums = LinuxCatalog.parseChecksums(text)
        #expect(sums.count == 3)
        #expect(sums[0].file == "ubuntu-24.04.3-desktop-amd64.iso")
        #expect(sums[2].file == "Rocky-10.2-x86_64-dvd1.iso")
        #expect(sums[2].hash.hasPrefix("16ca9c96"))
    }

    @Test func appleDistParsing() {
        let dist = """
        <installer-gui-script><title>SU_TITLE</title><auxinfo><dict><key>BUILD</key><string>23G93</string>
        <key>VERSION</key><string>14.6.1</string></dict></auxinfo>
        <localization><strings language="English">"SU_TITLE" = "macOS Sonoma";</strings></localization></installer-gui-script>
        """
        let (t, v, b) = AppleCatalog.parseDist(dist)
        #expect(t == "macOS Sonoma" && v == "14.6.1" && b == "23G93")
    }

    @Test func macReleaseNames() {
        #expect(MacInstallerInspector.majorVersion(fromName: "macOS High Sierra") == "10.13")
        #expect(MacInstallerInspector.majorVersion(fromName: "OS X Mountain Lion") == "10.8")
        #expect(MacInstallerInspector.majorVersion(fromName: "Mac OS X Lion") == "10.7")
        #expect(MacInstallerInspector.versionLess("10.15", "11"))
        #expect(!MacInstallerInspector.versionLess("26", "15"))
        #expect(AppleCatalog.legacyReleases.allSatisfy {
            if case .legacyDMG(let url, _) = $0.payload { return url.hasPrefix("https://updates.cdn-apple.com/") }
            return false
        })
    }
}

@Suite struct MiscTests {
    @Test func vhdFooterChecksum() {
        let f = VHD.fixedFooter(diskSize: 512 * Units.MB)
        #expect(Array(f[0..<8]) == Array("conectix".utf8))
        var copy = f
        let stored = UInt32(f[64]) << 24 | UInt32(f[65]) << 16 | UInt32(f[66]) << 8 | UInt32(f[67])
        for i in 64..<68 { copy[i] = 0 }
        var sum: UInt32 = 0
        for b in copy { sum = sum &+ UInt32(b) }
        #expect(~sum == stored)
    }

    @Test func badBlockPatterns() {
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 9, alignment: 8)
        defer { buf.deallocate() }
        BadBlocks.fill(buf, count: 9, pattern: 0x1c71c7)
        let b = buf.assumingMemoryBound(to: UInt8.self)
        #expect((0..<6).map { b[$0] } == [0xc7, 0x71, 0x1c, 0xc7, 0x71, 0x1c])
        BadBlocks.fill(buf, count: 9, pattern: 0x00)
        #expect((0..<9).allSatisfy { b[$0] == 0 })
    }

    @Test func syslinuxADV() {
        let adv = SyslinuxInstaller.emptyADV()
        #expect(adv.count == 1024)
        #expect(LE.get32(adv, 0) == 0x5A2D_2FA5)
        #expect(LE.get32(adv, 508) == 0xDD28_BF64)
        var sum: UInt32 = 0
        for i in stride(from: 4, to: 508, by: 4) { sum = sum &+ LE.get32(adv, i) }
        #expect(sum == 0xA304_1767)
        #expect(Array(adv[0..<512]) == Array(adv[512..<1024]))
    }

    @Test func tokenReplacement() {
        let cfg = "label live\n  append boot=casper quiet\n  kernel /casper/vmlinuz\nlinux /casper/vmlinuz boot=casper"
        let r = LinuxSetup.replaceInToken(cfg, token: "append", from: "boot=casper", to: "boot=casper persistent")
        #expect(r?.contains("append boot=casper persistent quiet") == true)
        #expect(r?.contains("linux /casper/vmlinuz boot=casper\n") == false || r?.hasSuffix("linux /casper/vmlinuz boot=casper") == true)
        #expect(LinuxSetup.replaceInToken(cfg, token: "initrd", from: "x", to: "y") == nil)
    }

    @Test func bootRecordsAreBundled() throws {
        for name in ["mbr_win7", "mbr_rufus", "mbr_syslinux", "mbr_grub2", "mbr_msg_rufus", "mbr_zero",
                     "br_fat32_0x0", "br_fat32pe_0x52", "br_fat32pe_0x3f0", "br_fat32pe_0x1800", "br_fat32fd_0x52", "br_ntfs_0x54"] {
            let b = try BootResources.bootRecord(name)
            #expect(!b.isEmpty)
        }
        #expect(try BootResources.data("uefi/uefi-ntfs.img").count == 1_048_576)
        #expect(try BootResources.bootRecord("mbr_win7").count == 440)
    }

    @Test func recommendations() {
        var r = ImageReport(path: "/x.iso", fileName: "x.iso", size: 6 * Units.GB, kind: .iso)
        r.family = .windows
        r.hasBootmgr = true
        r.efiBootloaders = ["/efi/boot/bootx64.efi"]
        let rec = MediaPlanner.recommend(image: r, disk: nil)
        #expect(rec.writeMode == .iso && rec.scheme == .gpt && rec.target == .uefi)
        var l = ImageReport(path: "/y.iso", fileName: "y.iso", size: 3 * Units.GB, kind: .iso)
        l.family = .linux
        l.isHybrid = true
        l.hasMBRPartitionTable = true
        l.syslinuxConfigs = ["/isolinux/isolinux.cfg"]
        l.efiBootloaders = ["/efi/boot/bootx64.efi"]
        #expect(MediaPlanner.recommend(image: l, disk: nil).writeMode == .dd)
        #expect(MediaPlanner.targets(boot: .image, image: l, scheme: .mbr).contains(.biosOrUefi))
        #expect(MediaPlanner.targets(boot: .image, image: l, scheme: .gpt) == [.uefi])
    }
}

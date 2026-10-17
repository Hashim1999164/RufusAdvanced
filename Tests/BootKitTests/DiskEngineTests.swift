import Foundation
import Testing
@testable import BootKit

@Suite(.serialized) struct DiskEngineTests {

    @Test func gptLayoutWithUEFINTFSAndPersistence() throws {
        let td = try TestDisk(sizeMB: 256)
        defer { td.detach() }
        let dev = try RawDevice(path: "/dev/r\(td.disk)", writable: true)
        var req = LayoutPlanner.Request(diskSize: dev.size, sectorSize: dev.blockSize, scheme: .gpt, fileSystem: .fat32,
                                        bootable: true, targetSystem: .uefi)
        req.persistenceSize = 64 * Units.MB
        req.uefiNTFSSize = Units.MB
        let layout = try LayoutPlanner.plan(req)
        #expect(layout.partitions.map(\.role) == [.main, .persistence, .uefiNTFS])
        try PartitionTableWriter.write(layout, to: dev)
        let (scheme, entries) = try PartitionTableWriter.read(from: dev)
        #expect(scheme == .gpt)
        #expect(entries.count == 3)
        #expect(entries[2].name == "UEFI:NTFS")
        dev.close()

        try DiskUtil.rescan(td.disk, expecting: ["\(td.disk)s1", "\(td.disk)s2", "\(td.disk)s3"])
        let list = try Shell.check("/usr/sbin/diskutil", ["list", td.disk]).stdout
        print(list)
        #expect(list.contains("UEFI:NTFS") || list.contains("Microsoft Basic Data"))
    }

    @Test func mbrFat32WithWindowsBootRecords() throws {
        let td = try TestDisk(sizeMB: 128)
        defer { td.detach() }
        // 1) Whole disk session: partition table + MBR boot code + active flag.
        var dev = try RawDevice(path: "/dev/r\(td.disk)", writable: true)
        let layout = try LayoutPlanner.plan(LayoutPlanner.Request(diskSize: dev.size, sectorSize: dev.blockSize, scheme: .mbr,
                                                                  fileSystem: .fat32, bootable: true, targetSystem: .biosOrUefi))
        try PartitionTableWriter.write(layout, to: dev)
        try BootRecords.writeMBR(dev, code: .windows7)
        try BootRecords.setActive(dev, partitionIndex: 0)
        dev.close()
        let slice = "\(td.disk)s1"
        try DiskUtil.rescan(td.disk, expecting: [slice])
        try DiskUtil.unmountDisk(td.disk)
        // 2) Slice session: format + PBR.
        let main = layout.partitions[0]
        let fr = Formatter.Request(disk: td.disk, slice: slice, fileSystem: .fat32, label: "Win11 24h2 x64!",
                                   clusterSize: 0, partitionOffset: main.offset, partitionSize: main.size)
        try Formatter.format(fr, cancel: nil)
        dev = try RawDevice(path: "/dev/r\(slice)", writable: true)
        try BootRecords.writePBR(dev, partitionOffset: 0, fileSystem: .fat32, code: .windowsPE)
        let pbr = try dev.readBytes(at: 0, count: 512)
        #expect(Array(pbr[0x52..<0x5A]) == Array("FAT32   ".utf8))
        #expect(LE.get32(pbr, 0x1C) == UInt32(main.offset / 512))
        dev.close()
        // 3) Verify MBR survived and the volume is still valid FAT32.
        let whole = try RawDevice(path: "/dev/r\(td.disk)", writable: false)
        let mbr = try whole.readBytes(at: 0, count: 512)
        whole.close()
        #expect(mbr[446] == 0x80)
        #expect(mbr[446 + 4] == 0x0c)
        #expect(mbr[510] == 0x55 && mbr[511] == 0xAA)
        #expect(Array(mbr[0..<440]) == (try BootResources.bootRecord("mbr_win7")))
        let fsck = try Shell.run("/sbin/fsck_msdos", ["-n", "/dev/r\(slice)"])
        print(fsck.combined)
        #expect(fsck.ok)
        try DiskUtil.waitForSlices([slice])
        _ = try DiskUtil.mount(slice)
        let name = try Shell.check("/usr/sbin/diskutil", ["info", slice]).stdout
        #expect(name.contains("WIN11 24H2"))
        DiskUtil.unmount(slice)
    }

    @Test func ext3PersistenceFormatter() throws {
        let td = try TestDisk(sizeMB: 160)
        defer { td.detach() }
        let dev = try RawDevice(path: "/dev/r\(td.disk)", writable: true)
        var fmt = Ext2Formatter(label: "persistence", journal: true, partitionSize: 128 * Units.MB)
        fmt.files = [.init(name: "persistence.conf", contents: Data("/ union\n".utf8))]
        try fmt.format(dev, offset: Units.MB, size: 128 * Units.MB)
        let sb = try dev.readBytes(at: Units.MB + 1024, count: 1024)
        #expect(LE.get16(sb, 56) == 0xEF53)
        // Keep a copy of the raw file system for an optional external e2fsck run.
        let out = NSTemporaryDirectory() + "rufusadv-tests/ext3.img"
        let data = try dev.readBytes(at: Units.MB, count: Int(128 * Units.MB))
        try Data(data).write(to: URL(fileURLWithPath: out))
        print("ext3 image saved at \(out)")
    }
}

/// Full jobs through JobRunner against RAM-free sparse disk images (no root needed).
@Suite(.serialized) struct JobEndToEndTests {

    static func makeISO() throws -> String {
        let dir = NSTemporaryDirectory() + "rufusadv-tests/iso-\(UUID().uuidString.prefix(6))"
        let src = dir + "/src"
        let fm = FileManager.default
        for d in ["/isolinux", "/efi/boot", "/boot/grub", "/live"] { try fm.createDirectory(atPath: src + d, withIntermediateDirectories: true) }
        try "ISOLINUX 6.04 test".write(toFile: src + "/isolinux/isolinux.bin", atomically: true, encoding: .utf8)
        try "default live\nlabel live\n  kernel /live/vmlinuz\n  append boot=live components quiet\n".write(toFile: src + "/isolinux/isolinux.cfg", atomically: true, encoding: .utf8)
        try "menuentry Live {\n  linux /live/vmlinuz boot=live components\n}\n".write(toFile: src + "/boot/grub/grub.cfg", atomically: true, encoding: .utf8)
        try "efi".write(toFile: src + "/efi/boot/bootx64.efi", atomically: true, encoding: .utf8)
        try Data(count: 3 * 1024 * 1024).write(to: URL(fileURLWithPath: src + "/live/filesystem.squashfs"))
        try "k".write(toFile: src + "/live/vmlinuz", atomically: true, encoding: .utf8)
        let iso = dir + "/debianlike.iso"
        try Shell.check("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-default-volume-name", "DEBLIVE", "-o", iso, src])
        return iso
    }

    func run(_ spec: JobSpec) -> (Bool, String?) {
        var result: (Bool, String?) = (false, nil)
        let reporter = JobReporter { e in if case .finished(let ok, let err, _) = e { result = (ok, err) } }
        JobRunner.run(spec, reporter: reporter, cancel: CancellationToken())
        return result
    }

    func baseSpec(_ td: TestDisk) throws -> JobSpec {
        let info = try #require(DiskEnumerator.info(td.disk))
        var s = JobSpec(disk: td.disk, diskSize: info.size, diskMediaName: info.mediaName)
        s.allowVirtualDisks = true
        s.ejectWhenDone = false
        s.mountWhenDone = false     // tests mount the result themselves
        return s
    }

    @Test func finishedDriveIsMountedForFinder() throws {
        let td = try TestDisk(sizeMB: 96)
        defer { td.detach() }
        var s = try baseSpec(td)
        s.bootSelection = .nonBootable
        s.partitionScheme = .mbr
        s.targetSystem = .biosOrUefi
        s.fileSystem = .fat32
        s.label = "RAFINDER"
        s.mountWhenDone = true
        var state: (Bool, [String])?
        var result: (Bool, String?) = (false, nil)
        let reporter = JobReporter { e in
            if case .driveState(let ejected, let mps) = e { state = (ejected, mps) }
            if case .finished(let ok, let err, _) = e { result = (ok, err) }
        }
        JobRunner.run(s, reporter: reporter, cancel: CancellationToken())
        defer { _ = try? Shell.run("/usr/sbin/diskutil", ["unmountDisk", "force", td.disk]) }
        #expect(result.0, "\(result.1 ?? "")")
        let st = try #require(state)
        #expect(st.0 == false)
        let mp = try #require(st.1.first)
        #expect(mp.hasPrefix("/Volumes/"))
        #expect(!DiskUtil.isHiddenFromFinder(mp))
        #expect(reporter.notices.contains { $0.hasPrefix("Ready: mounted at /Volumes/") })
        #expect(DiskUtil.finderMountPoints(of: td.disk) == st.1)
    }

    @Test func isoModeWithDebianPersistence() throws {
        let iso = try Self.makeISO()
        let report = try ImageInspector.inspect(path: iso)
        #expect(report.family == .linux)
        #expect(report.usesDebianLive)
        #expect(report.syslinuxConfigs == ["/isolinux/isolinux.cfg"])
        let td = try TestDisk(sizeMB: 300)
        defer { td.detach() }
        var s = try baseSpec(td)
        s.imagePath = iso
        s.image = report
        s.writeMode = .iso
        s.partitionScheme = .mbr
        s.targetSystem = .biosOrUefi
        s.fileSystem = .fat32
        s.persistenceSize = 64 * Units.MB
        s.extendedLabel = true
        let (ok, err) = run(s)
        #expect(ok, "\(err ?? "")")
        let mp = try DiskUtil.mount("\(td.disk)s1")
        defer { DiskUtil.unmount("\(td.disk)s1") }
        let cfg = try String(contentsOfFile: mp + "/isolinux/isolinux.cfg", encoding: .utf8)
        #expect(cfg.contains("boot=live persistence"))
        #expect(FileManager.default.fileExists(atPath: mp + "/ldlinux.sys"))
        #expect(FileManager.default.fileExists(atPath: mp + "/syslinux.cfg"))
        #expect(FileManager.default.fileExists(atPath: mp + "/autorun.inf"))
        let litter = try Shell.run("/usr/bin/find", [mp, "-name", "._*"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(litter.isEmpty)
        if let e2fsck = ProcessInfo.processInfo.environment["E2FSCK"] {
            let r = try Shell.run(e2fsck, ["-fn", "/dev/\(td.disk)s2"])
            #expect(r.ok, "\(r.combined)")
            #expect(r.combined.contains("persistence"))
        }
    }

    @Test func ddModeRoundTrip() throws {
        let iso = try Self.makeISO()
        let td = try TestDisk(sizeMB: 64)
        defer { td.detach() }
        var s = try baseSpec(td)
        s.imagePath = iso
        s.image = try ImageInspector.inspect(path: iso)
        s.writeMode = .dd
        s.verifyWrite = true
        let (ok, err) = run(s)
        #expect(ok, "\(err ?? "")")
        let img = try Data(contentsOf: URL(fileURLWithPath: iso))
        let dev = try RawDevice(path: "/dev/r\(td.disk)", writable: false)
        let back = try dev.readBytes(at: 0, count: img.count)
        #expect(Data(back) == img)
    }

    @Test func gzipCompressedDD() throws {
        let iso = try Self.makeISO()
        _ = try Shell.check("/usr/bin/gzip", ["-k", "-f", iso])
        let td = try TestDisk(sizeMB: 64)
        defer { td.detach() }
        var s = try baseSpec(td)
        s.imagePath = iso + ".gz"
        s.image = try ImageInspector.inspect(path: iso + ".gz")
        #expect(s.image?.kind == .compressedDisk)
        s.writeMode = .dd
        let (ok, err) = run(s)
        #expect(ok, "\(err ?? "")")
        let img = try Data(contentsOf: URL(fileURLWithPath: iso))
        let dev = try RawDevice(path: "/dev/r\(td.disk)", writable: false)
        #expect(Data(try dev.readBytes(at: 0, count: img.count)) == img)
    }

    @Test func freeDOSAndNonBootable() throws {
        let td = try TestDisk(sizeMB: 128)
        defer { td.detach() }
        var s = try baseSpec(td)
        s.bootSelection = .freeDOS
        s.partitionScheme = .mbr
        s.targetSystem = .bios
        s.fileSystem = .fat32
        s.freeDOSKeyboard = "fr"
        var (ok, err) = run(s)
        #expect(ok, "\(err ?? "")")
        let mp = try DiskUtil.mount("\(td.disk)s1")
        let autoexec = try String(contentsOfFile: mp + "/AUTOEXEC.BAT", encoding: .ascii)
        #expect(autoexec.contains("keyb fr,,\\locale\\keyboard.sys"))
        #expect(FileManager.default.fileExists(atPath: mp + "/KERNEL.SYS"))
        DiskUtil.unmount("\(td.disk)s1")

        s.bootSelection = .nonBootable
        s.fileSystem = .exfat
        s.partitionScheme = .gpt
        s.label = "Data Stick"
        (ok, err) = run(s)
        print("non-bootable result:", ok, err ?? "")
        #expect(ok, "\(err ?? "")")
        let info = try Shell.check("/usr/sbin/diskutil", ["info", "\(td.disk)s1"]).stdout
        #expect(info.contains("ExFAT") || info.contains("exfat"))
        #expect(info.contains("Data Stick"))
    }

    @Test func largeExt3MultiGroup4K() throws {
        let td = try TestDisk(sizeMB: 1200)
        defer { td.detach() }
        let dev = try RawDevice(path: "/dev/r\(td.disk)", writable: true)
        var fmt = Ext2Formatter(label: "bigext3", journal: true, partitionSize: 1100 * Units.MB)
        fmt.files = [.init(name: "persistence.conf", contents: Data("/ union\n".utf8))]
        try fmt.format(dev, offset: 0, size: 1100 * Units.MB)
        dev.close()
        #expect(fmt.blockSize == 4096)
        if let e2fsck = ProcessInfo.processInfo.environment["E2FSCK"] {
            let r = try Shell.run(e2fsck, ["-fn", "/dev/\(td.disk)"])
            #expect(r.ok, "\(r.combined)")
            print(r.combined)
        }
    }
}

import Foundation
import Testing
import CryptoKit
@testable import BootKit

/// Embedded ntfs-3g: format + write + read back on attached disk images.
/// Set NTFSPROGS=<dir with ntfsfix/ntfsls/ntfscat> to also check with the upstream tools.
@Suite(.serialized) struct NTFSTests {

    @Test func formatWriteReadBack() throws {
        let td = try TestDisk(sizeMB: 400)
        defer { td.detach() }
        let dev = try RawDevice(path: "/dev/r\(td.disk)", writable: true)
        let part: UInt64 = Units.MB
        let size = dev.size - 2 * Units.MB
        try NTFSVolume.format(dev, offset: part, size: size, hiddenSectors: part / 512, clusterSize: 0, label: "Win Install", quick: true)

        // Source tree with a large file, nested folders, unicode and empty files.
        let src = NSTemporaryDirectory() + "ntfs-src-\(UUID().uuidString.prefix(6))"
        let fm = FileManager.default
        try fm.createDirectory(atPath: src + "/sources/$OEM$/$$/Panther", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: src + "/efi/boot", withIntermediateDirectories: true)
        var bigBytes = [UInt8](repeating: 0, count: 150 * 1024 * 1024)
        var x: UInt32 = 2463534242
        for i in bigBytes.indices { x ^= x << 13; x ^= x >> 17; x ^= x << 5; bigBytes[i] = UInt8(truncatingIfNeeded: x) }
        let big = Data(bigBytes)
        try big.write(to: URL(fileURLWithPath: src + "/sources/install.wim"))
        try Data("bootmgr".utf8).write(to: URL(fileURLWithPath: src + "/bootmgr"))
        try Data().write(to: URL(fileURLWithPath: src + "/sources/appraiserres.dll"))
        try Data("Données ✓".utf8).write(to: URL(fileURLWithPath: src + "/efi/boot/Ünïcode file.txt"))
        defer { try? fm.removeItem(atPath: src) }

        var vol: NTFSVolume? = try NTFSVolume(device: dev, offset: part, size: size)
        var copied: UInt64 = 0
        for rel in ["/sources/$OEM$/$$/Panther", "/efi/boot"] { try vol!.mkdir(rel) }
        for rel in ["/sources/install.wim", "/bootmgr", "/sources/appraiserres.dll", "/efi/boot/Ünïcode file.txt"] {
            try vol!.writeFile(rel, from: src + rel) { copied += $0 }
        }
        try vol!.writeData("/sources/$OEM$/$$/Panther/unattend.xml", Data("<unattend/>".utf8))
        // Replace an existing file.
        try vol!.writeData("/bootmgr", Data("bootmgr v2".utf8))
        let unicodeBytes = UInt64(Data("Données ✓".utf8).count)
        let expected: UInt64 = UInt64(big.count) + 7 + unicodeBytes
        #expect(copied == expected)
        try vol!.close()
        vol = nil

        // Reopen and verify everything.
        let check = try NTFSVolume(device: dev, offset: part, size: size)
        #expect(check.kind("/sources") == 2)
        #expect(check.kind("/SOURCES/INSTALL.WIM") == 1)      // Windows style case-insensitive lookup
        #expect(check.read("/sources/install.wim") == big)
        #expect(check.read("/bootmgr") == Data("bootmgr v2".utf8))
        #expect(check.size("/sources/appraiserres.dll") == 0)
        #expect(check.read("/efi/boot/Ünïcode file.txt") == Data("Données ✓".utf8))
        #expect(check.read("/sources/$OEM$/$$/Panther/unattend.xml") == Data("<unattend/>".utf8))
        let space = check.space
        #expect(space.total > 390 * Units.MB && space.free < space.total)
        try check.close()
        dev.close()

        if let tools = ProcessInfo.processInfo.environment["NTFSPROGS"] {
            // Upstream consistency check + listing on the raw partition (as a file range via offset).
            let img = NSTemporaryDirectory() + "ntfs-part.img"
            let d = try RawDevice(path: "/dev/r\(td.disk)", writable: false)
            let bytes = try d.readBytes(at: part, count: Int(size))
            d.close()
            try Data(bytes).write(to: URL(fileURLWithPath: img))
            defer { try? fm.removeItem(atPath: img) }
            let fix = try Shell.run(tools + "/ntfsfix", ["-n", img])
            print(fix.combined)
            #expect(fix.ok)
            let ls = try Shell.run(tools + "/ntfsls", ["-R", "-l", img])
            print(ls.stdout)
            #expect(ls.stdout.contains("install.wim"))
        }
    }

    // MARK: Full jobs (ISO mode / format only) onto NTFS

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
        s.mountWhenDone = false
        return s
    }

    /// Windows-like ISO: bootmgr, EFI loaders, sources/*.wim (fake), setup.exe.
    static func makeWindowsISO() throws -> (iso: String, wim: Data) {
        let dir = NSTemporaryDirectory() + "rufusadv-tests/winiso-\(UUID().uuidString.prefix(6))"
        let src = dir + "/src"
        let fm = FileManager.default
        for d in ["/sources", "/efi/boot", "/efi/microsoft/boot", "/boot"] {
            try fm.createDirectory(atPath: src + d, withIntermediateDirectories: true)
        }
        var bytes = [UInt8](repeating: 0, count: 24 * 1024 * 1024)
        var x: UInt32 = 0x9e3779b9
        for i in bytes.indices { x ^= x << 13; x ^= x >> 17; x ^= x << 5; bytes[i] = UInt8(truncatingIfNeeded: x) }
        let wim = Data(bytes)
        try wim.write(to: URL(fileURLWithPath: src + "/sources/install.wim"))
        for (rel, text) in [("/bootmgr", "bootmgr"), ("/bootmgr.efi", "bootmgr.efi"), ("/setup.exe", "MZsetup"),
                            ("/sources/boot.wim", "bootwim"), ("/sources/appraiserres.dll", "appraiser"),
                            ("/efi/boot/bootx64.efi", "MZbootx64"), ("/efi/microsoft/boot/bcd", "bcd"), ("/boot/bcd", "bcd")] {
            try Data(text.utf8).write(to: URL(fileURLWithPath: src + rel))
        }
        let iso = dir + "/win.iso"
        try Shell.check("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-udf", "-default-volume-name", "CCCOMA_X64FRE", "-o", iso, src])
        return (iso, wim)
    }

    @Test func windowsISOOnNTFSWithUEFINTFS() throws {
        let (iso, wim) = try Self.makeWindowsISO()
        let report = try ImageInspector.inspect(path: iso)
        #expect(report.family == .windows)
        let td = try TestDisk(sizeMB: 200)
        defer { td.detach() }
        var s = try baseSpec(td)
        s.imagePath = iso
        s.image = report
        s.writeMode = .iso
        s.partitionScheme = .gpt
        s.targetSystem = .uefi
        s.fileSystem = .ntfs
        s.label = "WIN11 NTFS"
        s.extendedLabel = true
        s.uefiMediaValidation = true
        s.windows = WindowsCustomization()          // TPM/Secure Boot/RAM bypass + no online account
        let (ok, err) = run(s)
        #expect(ok, "\(err ?? "")")

        // Partition 1: NTFS with the image + customization. Partition 2: UEFI:NTFS (FAT).
        let dev = try RawDevice(path: "/dev/r\(td.disk)s1", writable: false)
        defer { dev.close() }
        let vol = try NTFSVolume(device: dev)
        defer { try? vol.close() }
        #expect(vol.read("/sources/install.wim") == wim)
        #expect(vol.read("/bootmgr") == Data("bootmgr".utf8))
        #expect(vol.read("/efi/boot/bootx64_original.efi") == Data("MZbootx64".utf8))
        #expect(vol.size("/efi/boot/bootx64.efi") > 1000)               // uefi-md5sum loader
        #expect(vol.size("/sources/appraiserres.dll") == 0)
        #expect(vol.read("/sources/appraiserres.bak") == Data("appraiser".utf8))
        let unattend = String(decoding: vol.read("/autounattend.xml") ?? Data(), as: UTF8.self)
        #expect(unattend.contains("BypassTPMCheck") && unattend.contains("BypassNRO"))
        let md5 = String(decoding: vol.read("/md5sum.txt") ?? Data(), as: UTF8.self)
        #expect(md5.contains("./sources/install.wim") && md5.contains("./efi/boot/bootx64_original.efi"))
        #expect(!md5.contains("./efi/boot/bootx64.efi"))
        #expect(String(decoding: vol.read("/autorun.inf") ?? Data(), as: UTF8.self).contains("label = WIN11 NTFS"))
        #expect(vol.kind("/EFI/MICROSOFT/BOOT/BCD") == 1)
        let fsck = try Shell.run("/sbin/fsck_msdos", ["-n", "/dev/\(td.disk)s2"])
        #expect(fsck.ok, "\(fsck.combined)")
        try checkWithUpstream(td, slice: "s1", expect: "install.wim")
    }

    @Test func linuxISOOnNTFS() throws {
        let iso = try JobEndToEndTests.makeISO()
        let report = try ImageInspector.inspect(path: iso)
        let td = try TestDisk(sizeMB: 160)
        defer { td.detach() }
        var s = try baseSpec(td)
        s.imagePath = iso
        s.image = report
        s.writeMode = .iso
        s.partitionScheme = .mbr
        s.targetSystem = .biosOrUefi
        s.fileSystem = .ntfs
        s.label = "LIVE USB"
        let (ok, err) = run(s)
        #expect(ok, "\(err ?? "")")
        let dev = try RawDevice(path: "/dev/r\(td.disk)s1", writable: false)
        defer { dev.close() }
        let vol = try NTFSVolume(device: dev)
        defer { try? vol.close() }
        #expect(vol.size("/live/filesystem.squashfs") == Int64(3 * Units.MB))
        let grub = String(decoding: vol.read("/boot/grub/grub.cfg") ?? Data(), as: UTF8.self)
        #expect(grub.contains("linux /live/vmlinuz"))
        #expect(vol.read("/efi/boot/bootx64.efi") == Data("efi".utf8))
        try checkWithUpstream(td, slice: "s1", expect: "filesystem.squashfs")
    }

    @Test func formatOnlyNTFSAndUEFINTFS() throws {
        for boot in [BootSelection.nonBootable, .uefiNTFS] {
            let td = try TestDisk(sizeMB: 96)
            defer { td.detach() }
            var s = try baseSpec(td)
            s.bootSelection = boot
            s.partitionScheme = .gpt
            s.targetSystem = .uefi
            s.fileSystem = .ntfs
            s.label = "DATA"
            s.extendedLabel = true
            let (ok, err) = run(s)
            #expect(ok, "\(boot): \(err ?? "")")
            let dev = try RawDevice(path: "/dev/r\(td.disk)s1", writable: false)
            let vol = try NTFSVolume(device: dev)
            #expect(String(decoding: vol.read("/autorun.inf") ?? Data(), as: UTF8.self).contains("label = DATA"))
            #expect(vol.space.free > 80 * Units.MB)
            try vol.close()
            dev.close()
            try checkWithUpstream(td, slice: "s1", expect: "autorun.inf")
        }
    }

    /// Opt-in: WIN_ISO=<a real Windows ISO with install.wim > 4 GB>. Needs ~image size of free disk space.
    @Test func realWindowsISOOnNTFS() throws {
        guard let path = ProcessInfo.processInfo.environment["WIN_ISO"] else { return }
        let report = try ImageInspector.inspect(path: path)
        #expect(report.family == .windows && report.has4GBFile)
        let rec = MediaPlanner.recommend(image: report, disk: nil)
        #expect(rec.fileSystem == .ntfs && rec.largeWIMStrategy == .ntfsUEFINTFS)
        let td = try TestDisk(sizeMB: Int((report.projectedSize + 600 * Units.MB) / Units.MB))
        defer { td.detach() }
        var s = try baseSpec(td)
        s.imagePath = path
        s.image = report
        s.writeMode = rec.writeMode
        s.partitionScheme = rec.scheme
        s.targetSystem = rec.target
        s.fileSystem = rec.fileSystem
        s.largeWIMStrategy = rec.largeWIMStrategy
        s.label = rec.label
        s.uefiMediaValidation = true
        s.windows = WindowsCustomization()
        let start = Date()
        let (ok, err) = run(s)
        print("Real Windows ISO written in \(Int(Date().timeIntervalSince(start))) s")
        #expect(ok, "\(err ?? "")")

        let dev = try RawDevice(path: "/dev/r\(td.disk)s1", writable: false)
        defer { dev.close() }
        let vol = try NTFSVolume(device: dev)
        defer { try? vol.close() }
        let wimRel = try #require(report.windowsInstallImage)
        let md5 = String(decoding: vol.read("/md5sum.txt") ?? Data(), as: UTF8.self)
        let line = try #require(md5.split(separator: "\n").first { $0.lowercased().hasSuffix(".\(wimRel)") })
        let expected = String(line.prefix(32))
        // Stream install.wim back from NTFS.
        let size = UInt64(vol.size(wimRel))
        #expect(size == report.windowsInstallImageSize)
        var h = Insecure.MD5()
        var off: UInt64 = 0
        while off < size {
            let chunk = try #require(vol.read(wimRel, offset: off, count: 8 * 1024 * 1024))
            #expect(!chunk.isEmpty)
            if chunk.isEmpty { break }
            h.update(data: chunk)
            off += UInt64(chunk.count)
        }
        let got = h.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(got == expected)
        #expect(vol.size("/sources/appraiserres.dll") == 0)
        if let wimlib = ExternalTool.wimlib.path {
            // The answer file is injected into boot.wim[2] (like Rufus) instead of \autounattend.xml.
            let bootWim = NSTemporaryDirectory() + "boot-\(UUID().uuidString.prefix(6)).wim"
            try #require(vol.read("/sources/boot.wim")).write(to: URL(fileURLWithPath: bootWim))
            defer { try? FileManager.default.removeItem(atPath: bootWim) }
            let dir = try Shell.run(wimlib, ["dir", bootWim, "2"])
            #expect(dir.stdout.contains("/Autounattend.xml"), "\(dir.combined.suffix(500))")
        } else {
            #expect(vol.kind("/autounattend.xml") == 1)
        }
    }

    /// With NTFSPROGS set: upstream ntfsfix -n + ntfsls on a copy of the partition.
    func checkWithUpstream(_ td: TestDisk, slice: String, expect name: String) throws {
        guard let tools = ProcessInfo.processInfo.environment["NTFSPROGS"] else { return }
        let d = try RawDevice(path: "/dev/r\(td.disk)\(slice)", writable: false)
        let bytes = try d.readBytes(at: 0, count: Int(d.size))
        d.close()
        let img = NSTemporaryDirectory() + "ntfs-\(UUID().uuidString.prefix(6)).img"
        try Data(bytes).write(to: URL(fileURLWithPath: img))
        defer { try? FileManager.default.removeItem(atPath: img) }
        let fix = try Shell.run(tools + "/ntfsfix", ["-n", img])
        #expect(fix.ok, "\(fix.combined)")
        let ls = try Shell.run(tools + "/ntfsls", ["-R", img])
        #expect(ls.stdout.contains(name), "\(ls.combined)")
    }
}

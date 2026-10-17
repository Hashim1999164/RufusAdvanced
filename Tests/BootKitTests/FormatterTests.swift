import Foundation
import Testing
@testable import BootKit

/// In-process formatters validated with macOS' own fsck tools and a real mount + write.
@Suite(.serialized) struct FormatterTests {

    func check(_ td: TestDisk, fsck: String) throws {
        let r = try Shell.run(fsck, ["-n", "/dev/r\(td.disk)"])
        #expect(r.ok, "\(r.combined)")
        // macOS must mount it and accept writes.
        let mp = try DiskUtil.mount(td.disk)
        defer { DiskUtil.unmount(td.disk) }
        let payload = Data((0..<300_000).map { UInt8($0 & 0xff) })
        try payload.write(to: URL(fileURLWithPath: mp + "/Hello World long name.bin"))
        try FileManager.default.createDirectory(atPath: mp + "/sub dir/nested", withIntermediateDirectories: true)
        #expect(try Data(contentsOf: URL(fileURLWithPath: mp + "/Hello World long name.bin")) == payload)
        DiskUtil.unmount(td.disk)
        let r2 = try Shell.run(fsck, ["-n", "/dev/r\(td.disk)"])
        #expect(r2.ok, "after write: \(r2.combined)")
    }

    @Test(arguments: [(64, false, UInt32(0)), (300, false, 0), (300, true, 0), (600, true, 0), (600, true, 512), (2100, true, 32768)])
    func fat(_ sizeMB: Int, _ fat32: Bool, _ cluster: UInt32) throws {
        let td = try TestDisk(sizeMB: sizeMB)
        defer { td.detach() }
        let dev = try RawDevice(path: "/dev/r\(td.disk)", writable: true)
        try FATFormatter.formatFAT(dev, offset: 0, size: dev.size, fat32: fat32,
                                   options: .init(label: "Test Vol", clusterSize: cluster, hiddenSectors: 0))
        dev.close()
        try check(td, fsck: "/sbin/fsck_msdos")
        let info = try Shell.check("/usr/sbin/diskutil", ["info", td.disk]).stdout
        #expect(info.contains("TEST VOL"))
    }

    @Test func fat12Tiny() throws {
        let td = try TestDisk(sizeMB: 4)
        defer { td.detach() }
        let dev = try RawDevice(path: "/dev/r\(td.disk)", writable: true)
        try FATFormatter.formatFAT(dev, offset: 0, size: dev.size, fat32: false, options: .init(label: "TINY", hiddenSectors: 0))
        dev.close()
        try check(td, fsck: "/sbin/fsck_msdos")
    }

    @Test(arguments: [(64, UInt32(0)), (700, 0), (700, 131072), (3000, 0)])
    func exfat(_ sizeMB: Int, _ cluster: UInt32) throws {
        let td = try TestDisk(sizeMB: sizeMB)
        defer { td.detach() }
        let dev = try RawDevice(path: "/dev/r\(td.disk)", writable: true)
        try FATFormatter.formatExFAT(dev, offset: 0, size: dev.size, options: .init(label: "Données USB", clusterSize: cluster, hiddenSectors: 0))
        dev.close()
        try check(td, fsck: "/sbin/fsck_exfat")
        let info = try Shell.check("/usr/sbin/diskutil", ["info", td.disk]).stdout
        #expect(info.contains("Données USB") || info.contains("Donn"))
    }
}

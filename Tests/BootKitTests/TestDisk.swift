import Foundation
@testable import BootKit

/// A RAM-backed raw disk image attached with hdiutil, usable as a fake USB drive.
final class TestDisk {
    let imagePath: String
    let disk: String

    init(sizeMB: Int) throws {
        let dir = NSTemporaryDirectory() + "rufusadv-tests"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        imagePath = dir + "/disk-\(UUID().uuidString).img"
        FileManager.default.createFile(atPath: imagePath, contents: nil)
        let fh = FileHandle(forWritingAtPath: imagePath)!
        try fh.truncate(atOffset: UInt64(sizeMB) * 1024 * 1024)
        try fh.close()
        let r = try Shell.check("/usr/bin/hdiutil", ["attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", imagePath])
        guard let id = r.stdout.split(separator: "\n").first?.split(separator: " ").first?.replacingOccurrences(of: "/dev/", with: "") else {
            throw BootKitError.generic("attach failed: \(r.combined)")
        }
        disk = String(id).trimmingCharacters(in: .whitespaces)
    }

    func detach() {
        _ = try? Shell.run("/usr/bin/hdiutil", ["detach", "-force", "/dev/\(disk)"])
        try? FileManager.default.removeItem(atPath: imagePath)
    }

    deinit { detach() }
}

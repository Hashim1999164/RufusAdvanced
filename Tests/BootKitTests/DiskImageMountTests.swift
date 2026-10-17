import Foundation
import Testing
@testable import BootKit

/// Two users of the same image must not pull it from under each other (EIO while copying).
@Suite(.serialized) struct DiskImageMountTests {

    @Test func secondUserDetachingDoesNotBreakTheFirst() throws {
        let iso = try JobEndToEndTests.makeISO()
        let a = try DiskImageMount(imagePath: iso)
        defer { a.detach() }
        let mpA = try #require(a.primaryMountPoint)
        let file = mpA + "/live/filesystem.squashfs"
        let before = try Data(contentsOf: URL(fileURLWithPath: file))

        // Like the app scanning the image while the helper copies from it.
        let b = try DiskImageMount(imagePath: iso)
        #expect(b.wholeDevice != a.wholeDevice)
        #expect(FileManager.default.fileExists(atPath: (b.primaryMountPoint ?? "") + "/live/filesystem.squashfs"))
        b.detach()

        let after = try Data(contentsOf: URL(fileURLWithPath: file))
        #expect(after == before)
    }

    @Test func imageOpenedInFinderStaysMounted() throws {
        // A DMG the user opened (attached and mounted outside of us).
        let dir = NSTemporaryDirectory() + "rufusadv-tests/dmg-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir + "/src", withIntermediateDirectories: true)
        try "hello".write(toFile: dir + "/src/hello.txt", atomically: true, encoding: .utf8)
        let dmg = dir + "/test.dmg"
        try Shell.check("/usr/bin/hdiutil", ["create", "-srcfolder", dir + "/src", "-format", "UDZO", "-volname", "RATEST", "-ov", dmg])
        let r = try Shell.check("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountrandom", dir, "-plist", dmg])
        let plist = try PropertyListSerialization.propertyList(from: Data(r.stdout.utf8), format: nil) as? [String: Any]
        let ents = (plist?["system-entities"] as? [[String: Any]]) ?? []
        let userMount = try #require(ents.compactMap { $0["mount-point"] as? String }.first)
        let userDev = try #require(ents.compactMap { $0["dev-entry"] as? String }.min { $0.count < $1.count })
        defer { _ = try? Shell.run("/usr/bin/hdiutil", ["detach", "-force", userDev]) }

        let m = try DiskImageMount(imagePath: dmg)
        #expect(m.primaryMountPoint == userMount)
        m.detach()
        #expect((try? String(contentsOfFile: userMount + "/hello.txt", encoding: .utf8)) == "hello")
    }
}

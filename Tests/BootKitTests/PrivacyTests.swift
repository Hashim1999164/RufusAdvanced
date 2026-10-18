import Foundation
import Testing
@testable import BootKit

@Suite struct PrivacyTests {

    @Test func protectedLocations() {
        let home = NSHomeDirectory()
        #expect(Privacy.isProtectedLocation(home + "/Downloads/RufusAdvanced/macOS/macOS Ventura 13.7.8 22H730/InstallAssistant.pkg"))
        #expect(Privacy.isProtectedLocation(home + "/Desktop/x.iso"))
        #expect(Privacy.isProtectedLocation(home + "/Documents/y.dmg"))
        #expect(!Privacy.isProtectedLocation("/Applications/Install macOS Ventura.app"))
        #expect(!Privacy.isProtectedLocation(home + "/Library/Caches/RufusAdvanced/staging/a/b.pkg"))
        #expect(!Privacy.isProtectedLocation(home + "/Downloadsx/file"))
    }

    @Test func stagingIsAnInstantCloneAndIsRemoved() throws {
        let dir = NSTemporaryDirectory() + "privacy-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: dir + "/with spaces", withIntermediateDirectories: true)
        let src = dir + "/with spaces/InstallAssistant.pkg"
        let payload = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try payload.write(to: URL(fileURLWithPath: src))
        defer { try? FileManager.default.removeItem(atPath: dir) }
        // Temporary folder and caches are on the same APFS volume: the clone must succeed.
        let staged = try #require(Privacy.cloneToStaging(src))
        #expect(staged.contains("/RufusAdvanced/staging/"))
        #expect((staged as NSString).lastPathComponent == "InstallAssistant.pkg")
        #expect(try Data(contentsOf: URL(fileURLWithPath: staged)) == payload)
        Privacy.removeStaged(staged)
        #expect(!FileManager.default.fileExists(atPath: (staged as NSString).deletingLastPathComponent))
        #expect(FileManager.default.fileExists(atPath: src))      // the original is untouched
    }

    @Test func responsibleProcessAndFullDiskAccessProbe() {
        let r = Privacy.responsibleProcess()
        #expect(r != nil)
        #expect((r?.path ?? "").hasPrefix("/"))
        _ = Privacy.hasFullDiskAccess()   // must not crash; value depends on this Mac
    }
}

import Foundation
import Testing
@testable import BootKit

/// macOS installer assistant: discovery, verification and package signature policy.
@Suite struct MacInstallerLibraryTests {

    /// A fake "Install macOS Test.app": Apple-signed createinstallmedia (a copy of /usr/bin/true),
    /// a sparse 3 GB SharedSupport.dmg, but no signature on the bundle itself.
    static func makeFakeInstaller(in dir: String, payloadSize: UInt64 = 3 * Units.GB) throws -> String {
        let app = dir + "/Install macOS Sequoia.app"
        let fm = FileManager.default
        try fm.createDirectory(atPath: app + "/Contents/Resources", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: app + "/Contents/SharedSupport", withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleDisplayName": "Install macOS Sequoia", "CFBundleIdentifier": "com.apple.InstallAssistant.macOSSequoia"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
        try fm.copyItem(atPath: "/usr/bin/true", toPath: app + "/Contents/Resources/createinstallmedia")
        let dmg = app + "/Contents/SharedSupport/SharedSupport.dmg"
        fm.createFile(atPath: dmg, contents: nil)
        let fh = try #require(FileHandle(forWritingAtPath: dmg))
        try fh.truncate(atOffset: payloadSize)
        try fh.close()
        return app
    }

    func tempDir() throws -> String {
        let d = NSTemporaryDirectory() + "macinst-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    @Test func discoversAndVerifiesInstallerApps() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let app = try Self.makeFakeInstaller(in: dir)
        try FileManager.default.createDirectory(atPath: dir + "/Install Something Else.app", withIntermediateDirectories: true)
        #expect(MacInstallerLibrary.installerApps(in: [dir]) == [app])

        let found = MacInstallerLibrary.verify(app: app)
        #expect(found.info?.name == "macOS Sequoia")
        #expect(found.info?.version == "15")
        let byTitle = Dictionary(uniqueKeysWithValues: found.checks.map { ($0.title, $0) })
        #expect(byTitle["Full installer"]?.ok == true)
        #expect(byTitle["Installer payload"]?.ok == true)
        #expect(byTitle["Apple signature (createinstallmedia)"]?.ok == true)   // /usr/bin/true is Apple signed
        #expect(byTitle["Apple signature (app)"]?.ok == false)                 // the fake bundle is not
        #expect(!found.isUsable)
        #expect(found.problem?.hasPrefix("Apple signature (app)") == true)
    }

    @Test func truncatedPayloadIsRejected() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let app = try Self.makeFakeInstaller(in: dir, payloadSize: 200 * Units.MB)
        let payload = MacInstallerLibrary.verify(app: app).checks.first { $0.title == "Installer payload" }
        #expect(payload?.ok == false)
        #expect(payload?.detail.contains("incomplete") == true)
    }

    @Test func stubAppIsNotAFullInstaller() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let app = dir + "/Install macOS Tahoe.app"
        try FileManager.default.createDirectory(atPath: app + "/Contents", withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleDisplayName": "Install macOS Tahoe"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: app + "/Contents/Info.plist"))
        let found = MacInstallerLibrary.verify(app: app)
        #expect(found.info == nil)
        #expect(found.checks.first?.ok == false)
        #expect(found.checks.first?.detail.contains("stub") == true)
    }

    @Test func appleSignatureOfSystemApps() {
        #expect(MacInstallerLibrary.signatureCheck("x", path: "/System/Applications/Calculator.app").ok)
        #expect(MacInstallerLibrary.signatureCheck("x", path: "/usr/bin/true").ok)
    }

    @Test func unsignedPackagesAreRefused() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let root = dir + "/root/Applications"
        _ = try Self.makeFakeInstaller(in: root, payloadSize: Units.MB)
        let pkg = dir + "/InstallAssistant.pkg"
        try Shell.check("/usr/bin/pkgbuild", ["--root", dir + "/root", "--identifier", "com.example.fake", "--version", "1", "--install-location", "/", pkg])
        let sig = MacInstallerLibrary.checkPackageSignature(pkg)
        #expect(!sig.ok)
        var finished: (Bool, String?)?
        let reporter = JobReporter { e in if case .finished(let ok, let err, _) = e { finished = (ok, err) } }
        var spec = JobSpec(disk: "", diskSize: 0, diskMediaName: "")
        spec.operation = .installMacPackage
        spec.imagePath = pkg
        JobRunner.run(spec, reporter: reporter, cancel: CancellationToken())
        #expect(finished?.0 == false)
        #expect(finished?.1?.contains("Refusing to install") == true)
    }

    @Test func installedPathFromNotices() {
        #expect(MacInstallerLibrary.installedPath(fromNotices: ["x", "Installed: /Applications/Install macOS Sequoia.app"]) == "/Applications/Install macOS Sequoia.app")
        #expect(MacInstallerLibrary.installedPath(fromNotices: []) == nil)
    }
}

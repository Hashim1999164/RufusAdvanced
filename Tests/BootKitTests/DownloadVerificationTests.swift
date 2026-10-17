import Foundation
import Testing
import CryptoKit
@testable import BootKit

/// Download verification: Apple package digests (xar TOC) and "never delete on mismatch".
@Suite(.serialized) struct DownloadVerificationTests {

    func tempDir() throws -> String {
        let d = NSTemporaryDirectory() + "dlverify-\(UUID().uuidString.prefix(6))"
        try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    /// A real (unsigned) installer package built with pkgbuild.
    func makePackage(in dir: String) throws -> String {
        let root = dir + "/root/Applications/Test.app/Contents"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 3 * 1024 * 1024)
        var x: UInt32 = 0x12345678
        for i in bytes.indices { x ^= x << 13; x ^= x >> 17; x ^= x << 5; bytes[i] = UInt8(truncatingIfNeeded: x) }
        try Data(bytes).write(to: URL(fileURLWithPath: root + "/payload.bin"))
        let pkg = dir + "/InstallAssistant.pkg"
        try Shell.check("/usr/bin/pkgbuild", ["--root", dir + "/root", "--identifier", "com.example.verify", "--version", "1",
                                              "--install-location", "/", pkg])
        return pkg
    }

    func sha1Hex(_ d: Data) -> String { Insecure.SHA1.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    @Test func catalogDigestIsTheTOCHashNotTheFileHash() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let pkg = try makePackage(in: dir)
        let digest = try ApplePackageVerifier.catalogDigest(of: pkg)
        let fileSHA1 = sha1Hex(try Data(contentsOf: URL(fileURLWithPath: pkg)))
        #expect(digest != fileSHA1)                      // the bug in 1.1.0 and older
        // xar stores the TOC checksum at the start of the heap: it must equal our digest.
        let (heap, entries) = try ApplePackageVerifier.entries(of: pkg)
        let fh = try #require(FileHandle(forReadingAtPath: pkg))
        try fh.seek(toOffset: heap)
        let stored = try #require(try fh.read(upToCount: 20))
        try fh.close()
        #expect(stored.map { String(format: "%02x", $0) }.joined() == digest)
        #expect(entries.count >= 3)                      // Bom, PackageInfo, Payload…
        #expect(try ApplePackageVerifier.verify(pkg, catalogDigest: digest) == .verified(files: entries.count, bytes: entries.reduce(0) { $0 + $1.length }))
    }

    @Test func detectsWrongDigestAndDamagedPayload() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let pkg = try makePackage(in: dir)
        let digest = try ApplePackageVerifier.catalogDigest(of: pkg)
        if case .mismatch = try ApplePackageVerifier.verify(pkg, catalogDigest: String(repeating: "0", count: 40)) {} else {
            Issue.record("a wrong catalog digest must be reported")
        }
        // Flip one byte inside the largest stored file (the Payload).
        let (heap, entries) = try ApplePackageVerifier.entries(of: pkg)
        let payload = try #require(entries.max { $0.length < $1.length })
        let fh = try #require(FileHandle(forUpdatingAtPath: pkg))
        let pos = heap + payload.offset + payload.length / 2
        try fh.seek(toOffset: pos)
        let b = try #require(try fh.read(upToCount: 1))
        try fh.seek(toOffset: pos)
        try fh.write(contentsOf: Data([b[0] ^ 0xff]))
        try fh.close()
        guard case .mismatch(let why) = try ApplePackageVerifier.verify(pkg, catalogDigest: digest) else {
            Issue.record("a damaged payload must be reported"); return
        }
        #expect(why.contains("damaged"))
    }

    // MARK: HTTPDownload against a local web server

    final class Server {
        let process = Process()
        let port: Int
        init(root: String) throws {
            port = Int.random(in: 20000...40000)
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-I", "-m", "http.server", String(port), "--bind", "127.0.0.1", "--directory", root]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            // Wait until it accepts connections.
            for _ in 0..<50 {
                if let u = URL(string: "http://127.0.0.1:\(port)/"), (try? Data(contentsOf: u)) != nil { return }
                usleep(100_000)
            }
        }
        func stop() { process.terminate(); process.waitUntilExit() }
    }

    func download(_ url: String, to dest: String, expected: (HashAlgorithm, String)? = nil, appleDigest: String? = nil) -> (Result<String, Error>, HTTPDownload) {
        let d = HTTPDownload(url: URL(string: url)!, destination: dest, expected: expected, appleDigest: appleDigest)
        let sem = DispatchSemaphore(value: 0)
        var result: Result<String, Error> = .failure(BootKitError.generic("timeout"))
        d.start(progress: { _ in }) { r in result = r; sem.signal() }
        _ = sem.wait(timeout: .now() + 60)
        return (result, d)
    }

    @Test func mismatchKeepsTheFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let pkg = try makePackage(in: dir)
        let server = try Server(root: dir)
        defer { server.stop() }
        let base = "http://127.0.0.1:\(server.port)/InstallAssistant.pkg"

        // Wrong SHA-256: success, file kept, mismatch reported.
        let dest1 = dir + "/out1/InstallAssistant.pkg"
        let (r1, d1) = download(base, to: dest1, expected: (.sha256, String(repeating: "a", count: 64)))
        #expect((try? r1.get()) == dest1)
        #expect(FileManager.default.fileExists(atPath: dest1))
        if case .mismatch = d1.verification {} else { Issue.record("expected a mismatch, got \(d1.verification)") }

        // Wrong Apple digest: kept as well.
        let dest2 = dir + "/out2/InstallAssistant.pkg"
        let (r2, d2) = download(base, to: dest2, appleDigest: String(repeating: "0", count: 40))
        #expect((try? r2.get()) == dest2)
        #expect(FileManager.default.fileExists(atPath: dest2))
        if case .mismatch = d2.verification {} else { Issue.record("expected a mismatch, got \(d2.verification)") }

        // Right Apple digest: verified.
        let dest3 = dir + "/out3/InstallAssistant.pkg"
        let (r3, d3) = download(base, to: dest3, appleDigest: try ApplePackageVerifier.catalogDigest(of: pkg))
        #expect((try? r3.get()) == dest3)
        if case .verified = d3.verification {} else { Issue.record("expected verified, got \(d3.verification)") }
        #expect(try Data(contentsOf: URL(fileURLWithPath: dest3)) == Data(contentsOf: URL(fileURLWithPath: pkg)))
    }

    /// Opt-in (network): APPLE_CATALOG_CHECK=1 downloads a few small packages listed in Apple's
    /// software update catalog and checks them against the catalog's Digest.
    @Test func realApplePackagesVerify() async throws {
        guard ProcessInfo.processInfo.environment["APPLE_CATALOG_CHECK"] != nil else { return }
        let (data, _) = try await HTTP.get(AppleCatalog.publicCatalog, timeout: 120)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let products = try #require(plist?["Products"] as? [String: [String: Any]])
        var picks: [(String, String)] = []
        var seen = Set<String>()
        for (_, p) in products {
            for pk in (p["Packages"] as? [[String: Any]]) ?? [] {
                guard let u = pk["URL"] as? String, let d = pk["Digest"] as? String, u.hasSuffix(".pkg"),
                      let size = (pk["Size"] as? NSNumber)?.intValue, size > 100_000, size < 3_000_000,
                      seen.insert((u as NSString).lastPathComponent).inserted else { continue }
                picks.append((u, d))
                if picks.count >= 3 { break }
            }
            if picks.count >= 3 { break }
        }
        #expect(picks.count == 3)
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for (u, digest) in picks.prefix(3) {
            let dest = dir + "/" + (u as NSString).lastPathComponent
            let (r, d) = download(u, to: dest, appleDigest: digest)
            #expect((try? r.get()) == dest, "\(u)")
            if case .verified = d.verification {} else { Issue.record("\(u): \(d.verification)") }
        }
    }
}

import Foundation
import Security

/// Version specific boot files (Syslinux ldlinux.sys/bss, GRUB core.img) published by the
/// Rufus project at https://rufus.ie/files, each with a detached RSA-2048/SHA-256 signature.
/// Files are only used after the signature has been verified with Rufus' public key.
public enum SignedFiles {
    public static let baseURL = "https://rufus.ie/files"

    public static var cacheDirectory: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.path
        return base + "/RufusAdvanced/files"
    }

    /// Verify `data` against a PKCS#1 v1.5 SHA-256 signature made with Rufus' key.
    public static func verify(_ data: Data, signature: Data) -> Bool {
        guard let der = try? BootResources.data("licenses/rufus-files-pubkey.der") else { return false }
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits: 2048]
        guard let key = SecKeyCreateWithData(der as CFData, attrs as CFDictionary, nil) else { return false }
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, data as CFData, signature as CFData, nil)
    }

    /// Fetch (or reuse from cache) a signed file, e.g. "syslinux-6.03/ldlinux.sys".
    public static func fetch(_ relative: String) async throws -> String {
        let local = cacheDirectory + "/" + relative
        let fm = FileManager.default
        if let d = fm.contents(atPath: local), let s = fm.contents(atPath: local + ".sig"), verify(d, signature: s) {
            return local
        }
        let (data, r1) = try await HTTP.get("\(baseURL)/\(relative)")
        guard r1.statusCode == 200 else { throw BootKitError.network("\(relative) is not available from rufus.ie (HTTP \(r1.statusCode)).") }
        let (sig, r2) = try await HTTP.get("\(baseURL)/\(relative).sig")
        guard r2.statusCode == 200, verify(data, signature: sig) else {
            throw BootKitError.verificationFailed("the signature of \(relative) is invalid. The file was not used.")
        }
        try fm.createDirectory(atPath: (local as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: local))
        try sig.write(to: URL(fileURLWithPath: local + ".sig"))
        logInfo("Downloaded and verified \(relative) (\(Units.human(UInt64(data.count))))")
        return local
    }

    /// Syslinux ldlinux.sys + ldlinux.bss for a given version (e.g. "6.03"). Returns the folder.
    public static func syslinux(version: String) async throws -> String {
        let sys = try await fetch("syslinux-\(version)/ldlinux.sys")
        _ = try await fetch("syslinux-\(version)/ldlinux.bss")
        return (sys as NSString).deletingLastPathComponent
    }

    /// GRUB 2 core.img matching an ISO's GRUB version (e.g. "2.12").
    public static func grubCore(version: String) async throws -> String {
        try await fetch("grub-\(version)/core.img")
    }
}

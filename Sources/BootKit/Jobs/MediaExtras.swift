import Foundation
import CryptoKit

/// Optional finishing touches on the created media.
public enum MediaExtras {

    /// "Create extended label and icon files": autorun.inf + autorun.ico (Windows shows them).
    public static func writeAutorun(root: String, label: String) {
        let inf = (root as NSString).appendingPathComponent("autorun.inf")
        if FileManager.default.fileExists(atPath: inf) { return }
        let text = "; Created by RufusAdvanced\r\n[autorun]\r\nicon  = autorun.ico\r\nlabel = \(label)\r\n"
        try? text.write(toFile: inf, atomically: false, encoding: .utf8)
        if let ico = try? BootResources.data("icons/autorun.ico") {
            try? ico.write(to: URL(fileURLWithPath: (root as NSString).appendingPathComponent("autorun.ico")))
        }
        _ = try? Shell.run("/usr/bin/chflags", ["hidden", inf], logCommand: false)
        logInfo("Created autorun.inf (label '\(label)')")
    }

    /// "Enable runtime UEFI media validation": install uefi-md5sum in front of the original
    /// EFI bootloaders and write an md5sum.txt covering every file of the media.
    public static func installUEFIMediaValidation(root: String, reporter: JobReporter, cancel: CancellationToken) throws {
        let fm = FileManager.default
        guard let efiBoot = SyslinuxInstaller.resolveCase("/efi/boot", root: root) else {
            logWarning("No /efi/boot directory: UEFI media validation skipped")
            return
        }
        var installed: [String] = []
        for arch in ["x64", "ia32", "aa64", "arm", "riscv64", "loongarch64"] {
            guard let rel = SyslinuxInstaller.resolveCase("\(efiBoot)/boot\(arch).efi", root: root),
                  let loader = try? BootResources.data("uefi-md5sum/boot\(arch).efi") else { continue }
            let original = root + (rel as NSString).deletingLastPathComponent + "/boot\(arch)_original.efi"
            try? fm.removeItem(atPath: original)
            try fm.moveItem(atPath: root + rel, toPath: original)
            try loader.write(to: URL(fileURLWithPath: root + rel))
            installed.append(rel)
        }
        guard !installed.isEmpty else { return }

        reporter.begin("Computing MD5 checksums for UEFI media validation")
        var lines: [String] = []
        var total: UInt64 = 0
        let skip = Set(installed.map { $0.lowercased() } + ["/md5sum.txt", "/autorun.inf", "/autorun.ico"])
        guard let e = fm.enumerator(atPath: root) else { return }
        let litter: Set<String> = [".fseventsd", ".spotlight-v100", ".trashes", ".metadata_never_index", ".temporaryitems", ".ds_store"]
        var files: [(String, UInt64)] = []
        while let relRaw = e.nextObject() as? String {
            let first = relRaw.split(separator: "/").first.map { $0.lowercased() } ?? ""
            if litter.contains(first) { e.skipDescendants(); continue }
            let rel = "/" + relRaw
            let a = e.fileAttributes ?? [:]
            guard (a[.type] as? FileAttributeType) == .typeRegular, !skip.contains(rel.lowercased()),
                  !(rel as NSString).lastPathComponent.hasPrefix("._") else { continue }
            files.append((rel, (a[.size] as? NSNumber)?.uint64Value ?? 0))
        }
        let grand = files.reduce(0) { $0 + $1.1 }
        var done: UInt64 = 0
        for (rel, size) in files.sorted(by: { $0.0 < $1.0 }) {
            try cancel.check()
            let h = try MultiHasher.hashFile(at: root + rel, algorithms: [.md5], cancel: cancel) { f in
                reporter.bytes(done + UInt64(Double(size) * f), of: grand, detail: (rel as NSString).lastPathComponent)
            }
            done += size
            total += size
            lines.append("\(h[.md5] ?? "")  .\(rel)")
        }
        let text = "# md5sum_totalbytes = 0x\(String(total, radix: 16))\n" + lines.joined(separator: "\n") + "\n"
        try text.write(toFile: root + "/md5sum.txt", atomically: false, encoding: .utf8)
        logInfo("Installed uefi-md5sum for \(installed.joined(separator: ", ")) and wrote md5sum.txt (\(lines.count) files)")
    }

    /// Mount an NTFS volume read/write through ntfs-3g (needs macFUSE).
    public static func mountNTFS(slice: String, at mountPoint: String) throws {
        guard let tool = ExternalTool.ntfs3g.path else {
            throw BootKitError.toolMissing(tool: "ntfs-3g", hint: "Writing files to NTFS on a Mac needs macFUSE + ntfs-3g (brew install --cask macfuse; brew install gromgit/fuse/ntfs-3g-mac). Use exFAT or FAT32 instead if you can.")
        }
        try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
        try Shell.check(tool, ["/dev/\(slice)", mountPoint, "-o", "local", "-o", "allow_other", "-o", "nobrowse"])
    }
}

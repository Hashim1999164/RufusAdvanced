import Foundation

/// Linux specific fixes applied after extracting an ISO (port of Rufus' fix_config()).
public enum LinuxSetup {

    /// Replace `from` with `to` on lines whose first token is `token` (Rufus' replace_in_token_data).
    static func replaceInToken(_ text: String, token: String, from: String, to: String) -> String? {
        var changed = false
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.lowercased().hasPrefix(token.lowercased()),
                  trimmed.count == token.count || trimmed.dropFirst(token.count).first?.isWhitespace == true,
                  line.contains(from) else { return line }
            changed = true
            return line.replacingOccurrences(of: from, with: to)
        }
        return changed ? lines.joined(separator: "\n") : nil
    }

    /// Patch boot loader configuration files on the target volume.
    public static func patchConfigs(root: String, image: ImageReport, usbLabel: String, persistence: Bool) {
        var files = Set(image.syslinuxConfigs + image.grubConfigs)
        // systemd-boot entries and other *.cfg in grub dirs
        for dir in ["/loader/entries", "/boot/grub", "/boot/grub2", "/efi/boot", "/isolinux", "/syslinux", "/boot/isolinux", "/boot/syslinux"] {
            guard let real = SyslinuxInstaller.resolveCase(dir, root: root),
                  let items = try? FileManager.default.contentsOfDirectory(atPath: root + real) else { continue }
            for i in items where i.lowercased().hasSuffix(".cfg") || i.lowercased().hasSuffix(".conf") {
                files.insert((dir + "/" + i).lowercased())
            }
        }
        let isoLabel = image.label.replacingOccurrences(of: " ", with: "\\x20")
        let newLabel = usbLabel.replacingOccurrences(of: " ", with: "\\x20")
        let tokens = ["options", "append", "linux", "linuxefi", "$linux", "search", "for"]
        let isNetinst = image.fileName.lowercased().contains("netinst")

        for rel in files.sorted() {
            guard let real = SyslinuxInstaller.resolveCase(rel, root: root) else { continue }
            let path = root + real
            guard var text = try? String(contentsOfFile: path, encoding: .utf8) ?? String(contentsOfFile: path, encoding: .isoLatin1) else { continue }
            let base = (rel as NSString).lastPathComponent
            let isGrub = base == "grub.cfg" || base == "loopback.cfg"
            let isSyslinux = SyslinuxInstallerConfigNames.contains(base) || base == "menu.cfg"
            var modified = false

            if persistence && (isGrub || isSyslinux) {
                let kernelToken = isGrub ? "linux" : "append"
                if let t = replaceInToken(text, token: kernelToken, from: "file=/cdrom/preseed", to: "persistent file=/cdrom/preseed") {
                    text = t; modified = true
                    if isGrub, let t2 = replaceInToken(text, token: "linux", from: "maybe-ubiquity", to: "") { text = t2 }
                    logInfo("  Added 'persistent' kernel option to \(real)")
                } else if let t = replaceInToken(text, token: kernelToken, from: "boot=casper", to: "boot=casper persistent") {
                    text = t; modified = true
                    logInfo("  Added 'persistent' kernel option to \(real)")
                } else if let t = replaceInToken(text, token: "linux", from: "/casper/vmlinuz", to: "/casper/vmlinuz persistent") {
                    text = t; modified = true
                    logInfo("  Added 'persistent' kernel option to \(real)")
                } else if let t = replaceInToken(text, token: "kernel", from: "/casper/vmlinuz", to: "/casper/vmlinuz persistent") {
                    text = t; modified = true
                    logInfo("  Added 'persistent' kernel option to \(real)")
                } else if let t = replaceInToken(text, token: kernelToken, from: "boot=live", to: "boot=live persistence") {
                    text = t; modified = true
                    logInfo("  Added 'persistence' kernel option to \(real)")
                }
            }

            if !isoLabel.isEmpty && isoLabel != newLabel {
                var patched = false
                for t in tokens {
                    if let r = replaceInToken(text, token: t, from: isoLabel, to: newLabel) { text = r; patched = true }
                }
                if patched { modified = true; logInfo("  Patched \(real): '\(isoLabel)' ➔ '\(newLabel)'") }
            }
            if image.isRedHat8Derivative && !isNetinst {
                var patched = false
                for t in tokens {
                    if let r = replaceInToken(text, token: t, from: "inst.stage2", to: "inst.repo") { text = r; patched = true }
                }
                if patched { modified = true; logInfo("  Patched \(real): 'inst.stage2' ➔ 'inst.repo'") }
            }
            if isGrub, !image.label.isEmpty,
               let r = replaceInToken(text, token: "set", from: "cd9660:/dev/iso9660/\(image.label)", to: "msdosfs:/dev/msdosfs/\(usbLabel)") {
                text = r; modified = true
            }
            if modified {
                do { try text.write(toFile: path, atomically: false, encoding: .utf8) }
                catch { logWarning("Could not update \(real): \(error.localizedDescription)") }
            }
        }
    }

    static let SyslinuxInstallerConfigNames: Set<String> = ["isolinux.cfg", "syslinux.cfg", "extlinux.conf", "txt.cfg", "live.cfg"]

    /// Some ISOs only carry their EFI bootloaders inside the El Torito EFI image (efi.img /
    /// efiboot.img). Extract its /EFI tree to the target so the USB is UEFI bootable.
    /// `sourceRoot` is where the EFI image is read from (defaults to `root`); the /EFI tree goes to `root`.
    public static func extractEFIImageIfNeeded(root: String, image: ImageReport, scratch: String, sourceRoot: String? = nil) {
        let readRoot = sourceRoot ?? root
        guard image.efiBootloaders.isEmpty, image.hasElToritoEFI else { return }
        let candidates = ["/boot/grub/efi.img", "/isolinux/efiboot.img", "/efi/boot/efiboot.img", "/images/efiboot.img",
                          "/boot/efi.img", "/efiboot.img", "/efi.img", "/boot/grub/efiboot.img", "/efi/efiboot.img"]
        for c in candidates {
            guard let real = SyslinuxInstaller.resolveCase(c, root: readRoot) else { continue }
            let tmp = scratch + "/efiimg-\(UUID().uuidString.prefix(6)).img"
            do {
                try FileManager.default.copyItem(atPath: readRoot + real, toPath: tmp)
                let r = try Shell.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-imagekey", "diskimage-class=CRawDiskImage",
                                                           "-mountrandom", scratch, "-plist", tmp])
                guard r.ok, let d = r.stdout.data(using: .utf8),
                      let pl = try PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
                      let ents = pl["system-entities"] as? [[String: Any]] else { continue }
                let mp = ents.compactMap { $0["mount-point"] as? String }.first
                let dev = ents.compactMap { $0["dev-entry"] as? String }.min { $0.count < $1.count }
                defer { if let dev { _ = try? Shell.run("/usr/bin/hdiutil", ["detach", "-force", dev]) } }
                guard let mp, let efi = SyslinuxInstaller.resolveCase("/efi", root: mp) else { continue }
                logInfo("Extracting EFI boot files from \(real)")
                let copier = FileCopier(options: FileCopier.Options(), cancel: CancellationToken()) { _, _ in }
                try copier.copyTree(from: mp + efi, to: root + "/EFI")
                return
            } catch {
                logWarning("Could not extract \(real): \(error.userMessage)")
            }
        }
    }
}

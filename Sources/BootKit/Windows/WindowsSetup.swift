import Foundation

/// Windows specific media preparation (port of the relevant parts of Rufus' wue.c / format.c).
public enum WindowsSetup {

    // MARK: wimlib helpers

    static func wimlib() throws -> String {
        guard let w = ExternalTool.wimlib.path else {
            throw BootKitError.toolMissing(tool: "wimlib-imagex", hint: "Install it with: brew install wimlib")
        }
        return w
    }

    /// Split install.wim into <4 GB .swm parts directly onto the FAT32 target.
    public static func splitWIM(source: String, targetSources: String, reporter: JobReporter, cancel: CancellationToken) throws {
        let tool = try wimlib()
        let dest = targetSources + "/install.swm"
        reporter.begin("Splitting install.wim for FAT32", detail: "3800 MB parts")
        try Shell.check(tool, ["split", source, dest, "3800"], cancel: cancel) { line in
            // "Writing "…" (part 2 of 3): 1234 MiB of 5678 MiB (21%) written"
            if let r = line.range(of: #"\((\d+)%\)"#, options: .regularExpression) {
                let pct = Double(line[r].dropFirst().dropLast(2)) ?? 0
                reporter.update(fraction: pct / 100, detail: line.trimmingCharacters(in: .whitespaces))
            }
        }
    }

    // MARK: Windows User Experience

    /// Apply the customization to the mounted target volume. Mirrors ApplyWindowsCustomization().
    public static func applyCustomization(_ c: WindowsCustomization, root: String, image: ImageReport,
                                          reporter: JobReporter, cancel: CancellationToken, scratch: String) throws {
        let arch = Unattend.unattendArch(image.wim?.arch)
        let lang = image.wim?.images.first?.languages.first ?? "en-US"
        guard let result = Unattend.generate(c, arch: arch, uiLanguage: lang) else {
            logInfo("No Windows User Experience options selected")
            return
        }
        reporter.begin("Applying Windows customization")
        let fm = FileManager.default
        let xmlPath = scratch + "/unattend.xml"
        try result.xml.write(toFile: xmlPath, atomically: true, encoding: .utf8)
        let sources = SyslinuxInstaller.resolveCase("/sources", root: root).map { root + $0 } ?? root + "/sources"
        let bootWim = SyslinuxInstaller.resolveCase("/sources/boot.wim", root: root).map { root + $0 }

        if c.bypassRequirements || c.silentInstall {
            // In-place upgrade bypass: empty appraiserres.dll so setup.exe can't check the hardware.
            let appraiser = sources + "/appraiserres.dll"
            if fm.fileExists(atPath: appraiser) {
                try? fm.removeItem(atPath: sources + "/appraiserres.bak")
                try fm.moveItem(atPath: appraiser, toPath: sources + "/appraiserres.bak")
                fm.createFile(atPath: appraiser, contents: Data())
                logInfo("Renamed 'appraiserres.dll' → 'appraiserres.bak' and created an empty placeholder")
            }
            // Windows 11 24H2+ in-place upgrade wrapper.
            if (image.windowsBuild ?? 0) >= 26000, let setupRel = SyslinuxInstaller.resolveCase("/setup.exe", root: root) {
                let setupExe = root + setupRel
                let setupDll = (setupExe as NSString).deletingLastPathComponent + "/setup.dll"
                if let arch = peMachine(setupExe), arch == 0x8664 || arch == 0xAA64 {
                    let wrapper = try BootResources.data(arch == 0x8664 ? "setup/setup_x64.exe" : "setup/setup_arm64.exe")
                    try? fm.removeItem(atPath: setupDll)
                    try fm.moveItem(atPath: setupExe, toPath: setupDll)
                    try wrapper.write(to: URL(fileURLWithPath: setupExe))
                    logInfo("Renamed 'setup.exe' → 'setup.dll' and installed the bypass wrapper")
                } else {
                    logWarning("Unsupported setup.exe architecture: in-place upgrade wrapper not added")
                }
            }
        }

        var injectedIntoBootWim = false
        if result.hasWindowsPEPass {
            if let bootWim, let w = ExternalTool.wimlib.path {
                // Setup image is index 2 of boot.wim (index 1 on some unofficial images).
                let info = try? WIMInfo.read(path: bootWim)
                let index = (info?.images.count ?? 2) >= 2 ? 2 : 1
                if index == 1 { logWarning("This image appears to be an UNOFFICIAL Windows ISO (boot.wim has no index 2).") }
                reporter.update(fraction: nil, detail: "Adding Autounattend.xml to boot.wim[\(index)]", force: true)
                let r = try Shell.run(w, ["update", bootWim, String(index), "--command=add '\(xmlPath)' '/Autounattend.xml'"], cancel: cancel)
                if r.ok {
                    injectedIntoBootWim = true
                    logInfo("Added 'Autounattend.xml' to boot.wim[\(index)]")
                } else {
                    logWarning("Could not update boot.wim (\(r.combined.trimmingCharacters(in: .whitespacesAndNewlines))); using \\autounattend.xml instead")
                }
            }
            if !injectedIntoBootWim {
                // Windows Setup scans the root of removable media for an answer file.
                try fm.copyItem(atPath: xmlPath, toPath: root + "/autounattend.xml")
                logInfo("Created '\\autounattend.xml'")
            }
        } else {
            // No windowsPE pass: Setup copies \sources\$OEM$\$$\* into %WINDIR%.
            let panther = sources + "/$OEM$/$$/Panther"
            try fm.createDirectory(atPath: panther, withIntermediateDirectories: true)
            try? fm.removeItem(atPath: panther + "/unattend.xml")
            try fm.copyItem(atPath: xmlPath, toPath: panther + "/unattend.xml")
            logInfo("Created '\\sources\\$OEM$\\$$\\Panther\\unattend.xml'")
        }

        if c.useCA2023Bootloaders {
            try applyCA2023(root: root, bootWim: bootWim, scratch: scratch, cancel: cancel)
        }
    }

    /// Replace the EFI bootloaders with the 'Windows UEFI CA 2023' signed ones from boot.wim.
    static func applyCA2023(root: String, bootWim: String?, scratch: String, cancel: CancellationToken) throws {
        guard let bootWim, let w = ExternalTool.wimlib.path else {
            logWarning("'Windows CA 2023' bootloaders need wimlib (brew install wimlib) - option ignored")
            return
        }
        let dir = scratch + "/ca2023"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let r1 = try Shell.run(w, ["extract", bootWim, "2", "/Windows/Boot/EFI_EX", "/Windows/Boot/Fonts_EX", "--dest-dir=\(dir)", "--no-acls", "--no-attributes"], cancel: cancel)
        guard r1.ok else {
            logWarning("Could not extract 2023 signed UEFI bootloaders - option ignored")
            return
        }
        let fm = FileManager.default
        var replaced = 0
        if let fonts = try? fm.contentsOfDirectory(atPath: dir + "/Fonts_EX") {
            let dst = root + (SyslinuxInstaller.resolveCase("/efi/microsoft/boot/fonts", root: root) ?? "/efi/microsoft/boot/fonts")
            try? fm.createDirectory(atPath: dst, withIntermediateDirectories: true)
            for f in fonts {
                let name = f.replacingOccurrences(of: "_EX", with: "")
                try? fm.removeItem(atPath: dst + "/" + name)
                if (try? fm.copyItem(atPath: dir + "/Fonts_EX/" + f, toPath: dst + "/" + name)) != nil { replaced += 1 }
            }
        }
        let bootmgfw = dir + "/EFI_EX/bootmgfw_EX.efi"
        for arch in ["x64", "aa64", "ia32", "arm"] {
            if let rel = SyslinuxInstaller.resolveCase("/efi/boot/boot\(arch).efi", root: root), fm.fileExists(atPath: bootmgfw) {
                try? fm.removeItem(atPath: root + rel)
                if (try? fm.copyItem(atPath: bootmgfw, toPath: root + rel)) != nil { replaced += 1 }
                break
            }
        }
        if let rel = SyslinuxInstaller.resolveCase("/bootmgr.efi", root: root), fm.fileExists(atPath: dir + "/EFI_EX/bootmgr_EX.efi") {
            try? fm.removeItem(atPath: root + rel)
            if (try? fm.copyItem(atPath: dir + "/EFI_EX/bootmgr_EX.efi", toPath: root + rel)) != nil { replaced += 1 }
        }
        if replaced > 0 {
            logInfo("Replaced \(replaced) EFI bootloader files with 'Windows UEFI CA 2023' compatible versions.")
            logNotice("To boot this media, the target PC must have the 'Windows UEFI CA 2023' Secure Boot certificate installed.")
        }
    }

    /// Windows 7 x64 ISOs have no \efi\boot\bootx64.efi: extract it from install.wim (Rufus "Win7 EFI boot setup").
    /// `sourceRoot` is where install.wim is read from (defaults to `root`).
    public static func win7EFIFix(root: String, image: ImageReport, scratch: String, cancel: CancellationToken, sourceRoot: String? = nil) {
        let readRoot = sourceRoot ?? root
        guard image.hasBootmgr, !image.hasEFI, image.wim?.arch == "x64",
              let major = image.wim?.images.first?.major, major == 6,
              let installRel = image.windowsInstallImage,
              let real = SyslinuxInstaller.resolveCase(installRel, root: readRoot),
              let w = ExternalTool.wimlib.path else { return }
        let dir = scratch + "/win7efi"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let r = try? Shell.run(w, ["extract", readRoot + real, "1", "/Windows/Boot/EFI/bootmgfw.efi", "--dest-dir=\(dir)", "--no-acls"], cancel: cancel), r.ok else {
            logWarning("Could not extract bootmgfw.efi from install.wim: UEFI boot will not be available")
            return
        }
        let efiBoot = root + "/efi/boot"
        try? FileManager.default.createDirectory(atPath: efiBoot, withIntermediateDirectories: true)
        try? FileManager.default.copyItem(atPath: dir + "/bootmgfw.efi", toPath: efiBoot + "/bootx64.efi")
        logInfo("Win7 EFI boot setup: created \\efi\\boot\\bootx64.efi")
    }

    /// PE machine type of an executable (0x8664 = x64, 0xAA64 = ARM64, 0x14C = x86).
    static func peMachine(_ path: String) -> UInt16? {
        guard let fh = FileHandle(forReadingAtPath: path), let d = try? fh.read(upToCount: 4096) else { return nil }
        try? fh.close()
        let b = [UInt8](d)
        guard b.count > 0x40, b[0] == 0x4D, b[1] == 0x5A else { return nil }
        let pe = Int(LE.get32(b, 0x3C))
        guard pe + 6 < b.count, b[pe] == 0x50, b[pe + 1] == 0x45 else { return nil }
        return LE.get16(b, pe + 4)
    }

    // MARK: Host regional settings → Windows

    /// Capture the Mac's locale for "Set regional options to the same values as this user's".
    public static func hostRegionalSettings() -> (timeZone: String?, inputLocale: String, systemLocale: String, uiLanguage: String) {
        let locale = Locale.current
        let tag = locale.identifier.replacingOccurrences(of: "_", with: "-").components(separatedBy: "@").first ?? "en-US"
        let ui = (Locale.preferredLanguages.first ?? tag)
        let windowsTZ = WindowsTimeZones.windowsName(for: TimeZone.current.identifier)
        return (windowsTZ, tag, tag, ui)
    }
}

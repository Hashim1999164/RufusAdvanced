import Foundation

/// Formats media without an image: Non bootable, FreeDOS, Syslinux, GRUB 2 and UEFI:NTFS.
public enum FormatWriter {

    public static func write(_ ctx: JobContext) throws {
        let spec = ctx.spec
        let r = ctx.reporter
        let boot = spec.bootSelection
        var fs = spec.fileSystem
        if boot == .freeDOS && !fs.isFAT { fs = .fat32 }
        if (boot == .syslinux4 || boot == .syslinux6 || boot == .grub2) && !fs.isFAT && fs != .ntfs { fs = .fat32 }
        if boot == .uefiNTFS && fs != .ntfs && fs != .exfat { fs = .exfat }
        if fs == .ntfs && boot != .nonBootable && !ExternalTool.ntfs3g.isAvailable && boot != .uefiNTFS {
            throw BootKitError.toolMissing(tool: "ntfs-3g", hint: "Choose FAT32 instead.")
        }

        r.plan([("Preparing drive", 1), ("Partitioning", 1), ("Formatting", spec.quickFormat ? 3 : 60), ("Installing boot loader", 2), ("Finalizing", 1)])
        let syslinux = boot == .syslinux4 || boot == .syslinux6
        var (mbr, sbr, driveID) = DiskPreparer.mbrCode(scheme: spec.partitionScheme, target: spec.targetSystem, bootSelection: boot,
                                                       image: nil, useRufusMBR: spec.useRufusMBR, syslinuxInstalled: syslinux)
        if boot == .uefiNTFS && spec.partitionScheme == .mbr { mbr = .zero; sbr = nil }
        var plan = DiskPreparer.Plan(scheme: spec.partitionScheme, target: spec.targetSystem, fileSystem: fs, bootable: boot != .nonBootable)
        plan.mbrCode = mbr
        plan.sbr = sbr
        plan.activeDriveID = driveID
        plan.uefiNTFS = boot == .uefiNTFS
        let prep = DiskPreparer(ctx: ctx)
        let prepared = try prep.partition(plan)

        let label = Formatter.validLabel(spec.label.isEmpty ? defaultLabel(boot) : spec.label, for: fs, fallbackSize: prepared.main.size)
        let biosTarget = spec.targetSystem != .uefi
        let pbr: BootRecords.PBRCode?
        switch boot {
        case .freeDOS: pbr = .freeDOS
        case .grub2: pbr = biosTarget ? .standard : nil
        default: pbr = nil
        }
        try prep.formatMain(prepared, fileSystem: fs, label: label, pbr: pbr)

        if boot == .nonBootable && fs == .ntfs || boot == .uefiNTFS && fs == .ntfs {
            // Nothing to copy: leave NTFS unmounted (macOS can't write it natively).
            if spec.extendedLabel { logWarning("Extended label files are not created on NTFS from macOS.") }
            r.begin("Finalizing")
            return
        }
        if [.udf, .ext2, .ext3, .ext4, .apfs].contains(fs) {
            r.begin("Finalizing")
            return
        }

        let target = try prep.mountMain(prepared)
        switch boot {
        case .freeDOS:
            r.begin("Installing boot loader", detail: "FreeDOS")
            try installFreeDOS(root: target, keyboard: spec.freeDOSKeyboard)
        case .syslinux4, .syslinux6:
            r.begin("Installing boot loader", detail: boot.rawValue)
            let files: (sys: [UInt8], bss: [UInt8])
            if let dir = spec.syslinuxFilesDir, let s = FileManager.default.contents(atPath: dir + "/ldlinux.sys"),
               let b = FileManager.default.contents(atPath: dir + "/ldlinux.bss") {
                files = ([UInt8](s), [UInt8](b))
            } else {
                files = try SyslinuxInstaller.bundledFiles(major: boot == .syslinux6 ? 6 : 4)
            }
            if boot == .syslinux6, let dir = spec.syslinuxFilesDir, FileManager.default.fileExists(atPath: dir + "/ldlinux.c32") {
                try? FileManager.default.copyItem(atPath: dir + "/ldlinux.c32", toPath: target + "/ldlinux.c32")
            }
            if boot == .syslinux4, let mboot = try? BootResources.data("syslinux/mboot.c32") {
                try? mboot.write(to: URL(fileURLWithPath: target + "/mboot.c32"))
            }
            try SyslinuxInstaller.install(sys: files.sys, bss: files.bss, slice: prepared.mainSlice, mountPoint: target, subdir: "")
        default:
            break
        }
        if spec.extendedLabel { MediaExtras.writeAutorun(root: target, label: spec.label.isEmpty ? label : spec.label) }
        r.begin("Finalizing", detail: "Flushing data to the drive")
        prep.unmount(target, slice: prepared.mainSlice)
    }

    static func defaultLabel(_ b: BootSelection) -> String {
        switch b {
        case .freeDOS: return "FREEDOS"
        case .syslinux4, .syslinux6: return "SYSLINUX"
        case .grub2: return "GRUB"
        default: return "USB"
        }
    }

    // MARK: FreeDOS

    static let fdKeyboardDrivers: [[String]] = [
        ["be", "br", "cf", "co", "cz", "dk", "dv", "fr", "gr", "hu", "it", "jp", "la", "lh", "nl", "no", "pl", "po", "rh", "sf", "sg", "sk", "sp", "su", "sv", "uk", "us", "yu"],
        ["bg", "ce", "gk", "is", "ro", "ru", "rx", "tr", "tt", "yc"],
        ["az", "bl", "et", "fo", "hy", "il", "ka", "kk", "ky", "lt", "lv", "mk", "mn", "mt", "ph", "sq", "tj", "tm", "ur", "uz", "vi"],
        ["ar", "bn", "bx", "fx", "ix", "kx", "ne", "ng", "px", "sx", "ux"],
    ]
    static let kbDriverFiles = [("KEYBOARD.SYS", 437), ("KEYBRD2.SYS", 850), ("KEYBRD3.SYS", 850), ("KEYBRD4.SYS", 853)]

    public static let keyboards: [(code: String, name: String)] = [
        ("us", "US-English"), ("uk", "UK-English"), ("gr", "German"), ("sg", "Swiss-German"), ("fr", "French"), ("be", "Belgian-French"),
        ("sf", "Swiss-French"), ("cf", "CA-French"), ("sp", "Spanish"), ("la", "Latin-American"), ("it", "Italian"), ("nl", "Dutch"),
        ("po", "Portuguese"), ("br", "Brazilian"), ("dk", "Danish"), ("no", "Norwegian"), ("sv", "Swedish"), ("su", "Finnish"),
        ("pl", "Polish"), ("cz", "Czech"), ("sl", "Slovak"), ("hu", "Hungarian"), ("ro", "Romanian"), ("ru", "Russian"),
        ("ur", "Ukrainian"), ("bl", "Belarusian"), ("bg", "Bulgarian"), ("gk", "Greek"), ("tr", "Turkish"), ("il", "Hebrew"),
        ("is", "Icelandic"), ("et", "Estonian"), ("lv", "Latvian"), ("lt", "Lithuanian"), ("jp", "Japanese"), ("yu", "YU-Latin"),
        ("yc", "YU-Cyrillic"), ("dv", "US-Dvorak"), ("vi", "Vietnamese"), ("hy", "Armenian"), ("ka", "Georgian"), ("az", "Azeri"),
        ("mk", "Macedonian"), ("sq", "Albanian"), ("kk", "Kazakh"), ("uz", "Uzbek"), ("mt", "Maltese"), ("fo", "Faeroese"),
    ]

    /// DOS keyboard code for the Mac's current locale.
    public static func defaultKeyboard() -> String {
        let region = Locale.current.region?.identifier.lowercased() ?? "us"
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        switch (lang, region) {
        case ("fr", "ca"): return "cf"
        case ("fr", "ch"): return "sf"
        case ("de", "ch"): return "sg"
        case ("fr", "be"), ("nl", "be"): return "be"
        case ("pt", "br"): return "br"
        case ("en", "gb"), ("en", "ie"): return "uk"
        case ("es", let r) where r != "es": return "la"
        default: break
        }
        let byLang = ["de": "gr", "fr": "fr", "es": "sp", "it": "it", "nl": "nl", "pt": "po", "da": "dk", "nb": "no", "nn": "no",
                      "sv": "sv", "fi": "su", "pl": "pl", "cs": "cz", "sk": "sl", "hu": "hu", "ro": "ro", "ru": "ru", "uk": "ur",
                      "be": "bl", "bg": "bg", "el": "gk", "tr": "tr", "he": "il", "is": "is", "et": "et", "lv": "lv", "lt": "lt",
                      "ja": "jp", "vi": "vi", "hy": "hy", "ka": "ka", "az": "az", "mk": "mk", "sq": "sq", "kk": "kk", "uz": "uz"]
        return byLang[lang] ?? "us"
    }

    static func installFreeDOS(root: String, keyboard: String) throws {
        let fm = FileManager.default
        let files = ["COMMAND.COM", "KERNEL.SYS"]
        for f in files {
            try BootResources.data("freedos/\(f)").write(to: URL(fileURLWithPath: root + "/" + f))
        }
        let localeFiles = ["DISPLAY.EXE", "KEYB.EXE", "MODE.COM", "KEYBOARD.SYS", "KEYBRD2.SYS", "KEYBRD3.SYS", "KEYBRD4.SYS", "EGA.CPX"]
            + (2...18).map { "EGA\($0).CPX" }
        try fm.createDirectory(atPath: root + "/LOCALE", withIntermediateDirectories: true)
        for f in localeFiles {
            if let d = try? BootResources.data("freedos/\(f)") { try d.write(to: URL(fileURLWithPath: root + "/LOCALE/" + f)) }
        }
        let kb = keyboard.lowercased()
        let driverIndex = fdKeyboardDrivers.firstIndex { $0.contains(kb) } ?? 0
        let (driver, cp) = kbDriverFiles[driverIndex]
        let kbName = keyboards.first { $0.code == kb }?.name ?? "US-English"
        func cpName(_ c: Int) -> String { [437: "US", 850: "Multilingual", 852: "Latin-2", 853: "Latin-3", 857: "Turkish"][c] ?? "\(c)" }
        var autoexec = "@echo off\r\nset PATH=.;\\;\\LOCALE\r\n"
        if kb == "us" {
            autoexec += "echo Using US-English keyboard with US codepage [437]\r\n"
        } else {
            var config = "!MENUCOLOR=7,0\r\nMENU\r\nMENU   FreeDOS Language Selection Menu\r\nMENU   " + String(repeating: "=", count: 31) + "\r\nMENU\r\n"
            config += "MENUDEFAULT=1,5\r\n"
            config += "MENU 1) Use \(kbName) keyboard with \(cpName(cp)) codepage [\(cp)]\r\n"
            config += "MENU 2) Use US-English keyboard with US codepage [437]\r\n"
            config += "MENU\r\n12?\r\n"
            try config.write(toFile: root + "/CONFIG.SYS", atomically: false, encoding: .ascii)
            autoexec += "display con=(ega,,1)\r\nGOTO %CONFIG%\r\n:1\r\n"
            autoexec += "mode con codepage prepare=((\(cp)) \\locale\\ega.cpx) > NUL\r\n"
            autoexec += "mode con codepage select=\(cp) > NUL\r\n"
            autoexec += "keyb \(kb),,\\locale\\\(driver.lowercased())\r\n:2\r\n"
        }
        try autoexec.write(toFile: root + "/AUTOEXEC.BAT", atomically: false, encoding: .ascii)
        logInfo("Installed FreeDOS (keyboard: \(kbName))")
    }
}

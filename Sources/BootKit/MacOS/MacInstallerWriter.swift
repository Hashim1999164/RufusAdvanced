import Foundation

/// Creates bootable macOS installer media.
///
/// Accepted sources:
///  - "Install macOS *.app" (any version from Mavericks to today)
///  - InstallAssistant.pkg (macOS 11+, straight from Apple's CDN)
///  - Apple's legacy InstallMacOSX.dmg / InstallOS.dmg (Lion … Sierra)
///  - A folder with a 10.13–10.15 product (packages + .dist) downloaded from the catalog
public enum MacInstallerWriter {

    public static func write(_ ctx: JobContext) throws {
        guard let image = ctx.spec.image else { throw BootKitError.invalidOption("No installer selected") }
        let r = ctx.reporter
        r.plan([("Preparing installer", 25), ("Preparing drive", 2), ("Creating install media", 70), ("Finalizing", 3)])

        var cleanups: [() -> Void] = []
        defer { cleanups.reversed().forEach { $0() } }

        // 1. Get a usable installer app.
        r.begin("Preparing installer", detail: image.displayName)
        let app = try resolveInstallerApp(image, ctx: ctx, cleanups: &cleanups)
        var info = try MacInstallerInspector.inspectApp(app)
        if info.version == nil { info.version = image.mac?.version }
        logInfo("Installer: \(info.displayName) at \(app)")
        if info.minimumUSBSize > ctx.disk.size + Units.GB {
            throw BootKitError.deviceTooSmall(needed: info.minimumUSBSize, available: ctx.disk.size)
        }
        if info.requiresRosetta && !rosettaInstalled() {
            throw BootKitError.generic("This installer's createinstallmedia only runs on Intel. Install Rosetta first: softwareupdate --install-rosetta --agree-to-license")
        }

        // 2. Erase the drive as GUID + Mac OS Extended (Journaled).
        r.begin("Preparing drive", detail: "Erasing \(ctx.spec.disk) as Mac OS Extended (Journaled), GUID")
        let label = sanitizeVolumeName(ctx.spec.label.isEmpty ? "Install \(info.name)" : ctx.spec.label)
        try DiskUtil.unmountDisk(ctx.spec.disk)
        try Shell.check("/usr/sbin/diskutil", ["eraseDisk", "JHFS+", label, "GPT", ctx.spec.disk], cancel: ctx.cancel)
        ctx.refreshDisk()
        guard let slice = ctx.disk.partitions.first(where: { $0.content.contains("Apple_HFS") })?.identifier ?? DiskEnumerator.info(ctx.spec.disk)?.partitions.last?.identifier,
              let volume = DiskUtil.mountPointOf(slice) ?? (try? DiskUtil.mount(slice)) else {
            throw BootKitError.mountFailed("the freshly erased installer volume")
        }

        // 3. Create the media.
        if info.isLegacyRestore {
            try asrRestore(app: app, volume: volume, ctx: ctx)
        } else {
            try createInstallMedia(app: app, info: info, volume: volume, ctx: ctx)
        }
        r.begin("Finalizing")
        Darwin.sync()
        r.notice("To boot it: restart the Mac holding Option (Intel) or the power button (Apple silicon) and pick '\(info.name)'.")
    }

    static func sanitizeVolumeName(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return String(cleaned.prefix(64))
    }

    static func rosettaInstalled() -> Bool {
        (try? Shell.run("/usr/bin/arch", ["-x86_64", "/usr/bin/true"], logCommand: false))?.ok ?? false
    }

    // MARK: Installer app resolution

    static func resolveInstallerApp(_ image: ImageReport, ctx: JobContext, cleanups: inout [() -> Void]) throws -> String {
        let fm = FileManager.default
        switch image.kind {
        case .macInstallerApp:
            return image.path
        case .macInstallerPackage:
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: image.path, isDirectory: &isDir), isDir.boolValue,
               let dist = (try? fm.contentsOfDirectory(atPath: image.path))?.first(where: { $0.hasSuffix(".dist") }) {
                return try installPackage(image.path + "/" + dist, ctx: ctx, cleanups: &cleanups)
            }
            let name = (image.path as NSString).lastPathComponent.lowercased()
            if name.hasPrefix("installmacosx") || name.hasPrefix("installos") {
                return try rebuildLegacyApp(pkg: image.path, ctx: ctx, cleanups: &cleanups)
            }
            return try installPackage(image.path, ctx: ctx, cleanups: &cleanups)
        case .appleDiskImage:
            let mount = try DiskImageMount(imagePath: image.path)
            cleanups.append { mount.detach() }
            guard let root = mount.primaryMountPoint, let items = try? fm.contentsOfDirectory(atPath: root) else {
                throw BootKitError.mountFailed(image.fileName)
            }
            if let app = items.first(where: { $0.hasPrefix("Install") && $0.hasSuffix(".app") }) { return root + "/" + app }
            if let pkg = items.first(where: { $0.hasSuffix(".pkg") }) {
                return try rebuildLegacyApp(pkg: root + "/" + pkg, ctx: ctx, cleanups: &cleanups)
            }
            throw BootKitError.unsupportedImage("This disk image does not contain a macOS installer.")
        default:
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: image.path, isDirectory: &isDir), isDir.boolValue,
               let dist = (try? fm.contentsOfDirectory(atPath: image.path))?.first(where: { $0.hasSuffix(".dist") }) {
                return try installPackage(image.path + "/" + dist, ctx: ctx, cleanups: &cleanups)
            }
            throw BootKitError.unsupportedImage("Not a macOS installer.")
        }
    }

    /// `installer -pkg` into a scratch sparse image (or /Applications) and return the app path.
    static func installPackage(_ pkg: String, ctx: JobContext, cleanups: inout [() -> Void]) throws -> String {
        let r = ctx.reporter
        let target: String
        if ctx.spec.macInstallToApplications {
            target = "/"
        } else {
            let sparse = ctx.scratch + "/installer.sparseimage"
            try Shell.check("/usr/bin/hdiutil", ["create", "-size", "40g", "-type", "SPARSE", "-fs", "HFS+J", "-volname", "RufusAdvInstaller", "-ov", sparse])
            let mount = try DiskImageMount(imagePath: sparse, mountRoot: ctx.scratch + "/mnt")
            cleanups.append {
                mount.detach()
                try? FileManager.default.removeItem(atPath: sparse)
            }
            guard let mp = mount.primaryMountPoint else { throw BootKitError.mountFailed("scratch image") }
            // `installer` refuses read-only / nobrowse quirks on some versions: remount read-write.
            target = mp
        }
        r.update(fraction: 0, detail: "Expanding \((pkg as NSString).lastPathComponent) (this takes a few minutes)", force: true)
        try Shell.check("/usr/sbin/installer", ["-pkg", pkg, "-target", target, "-verboseR"], cancel: ctx.cancel) { line in
            // installer -verboseR prints "installer:%12.345678" progress lines.
            if line.hasPrefix("installer:%"), let v = Double(line.dropFirst("installer:%".count)) {
                r.update(fraction: v / 100)
            } else if line.hasPrefix("installer:PHASE:") {
                r.update(fraction: nil, detail: String(line.dropFirst("installer:PHASE:".count)))
            }
        }
        let apps = target == "/" ? "/Applications" : target + "/Applications"
        guard let app = (try? FileManager.default.contentsOfDirectory(atPath: apps))?
                .filter({ $0.hasPrefix("Install") && $0.hasSuffix(".app") })
                .map({ apps + "/" + $0 })
                .max(by: { modDate($0) < modDate($1) }) else {
            throw BootKitError.generic("The package did not produce an installer app.")
        }
        if target == "/" { ctx.chownToUser(app) }
        return app
    }

    static func modDate(_ p: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? .distantPast
    }

    /// Lion … Sierra packages refuse to install on modern macOS; rebuild the app manually:
    /// expand the package, extract the app from its Payload and add InstallESD.dmg.
    static func rebuildLegacyApp(pkg: String, ctx: JobContext, cleanups: inout [() -> Void]) throws -> String {
        let r = ctx.reporter
        let fm = FileManager.default
        let work = ctx.scratch + "/legacy"
        try? fm.removeItem(atPath: work)
        r.update(fraction: nil, detail: "Expanding \((pkg as NSString).lastPathComponent)", force: true)
        try Shell.check("/usr/sbin/pkgutil", ["--expand", pkg, work + "/expanded"], cancel: ctx.cancel)
        guard let inner = (try? fm.contentsOfDirectory(atPath: work + "/expanded"))?.first(where: { $0.hasSuffix(".pkg") }) else {
            throw BootKitError.unsupportedImage("Unexpected legacy installer package layout.")
        }
        let innerDir = work + "/expanded/" + inner
        try fm.createDirectory(atPath: work + "/app", withIntermediateDirectories: true)
        r.update(fraction: nil, detail: "Extracting the installer app", force: true)
        try Shell.check("/usr/bin/tar", ["-xf", innerDir + "/Payload", "-C", work + "/app"], cancel: ctx.cancel)
        guard let appName = findApp(in: work + "/app") else { throw BootKitError.unsupportedImage("No installer app inside the package.") }
        let app = work + "/app/" + appName
        let shared = app + "/Contents/SharedSupport"
        try fm.createDirectory(atPath: shared, withIntermediateDirectories: true)
        let esd = innerDir + "/InstallESD.dmg"
        guard fm.fileExists(atPath: esd) else { throw BootKitError.unsupportedImage("InstallESD.dmg is missing from the package.") }
        try? fm.removeItem(atPath: shared + "/InstallESD.dmg")
        try fm.moveItem(atPath: esd, toPath: shared + "/InstallESD.dmg")
        cleanups.append { try? fm.removeItem(atPath: work) }
        logInfo("Rebuilt \(appName) from the legacy package")
        return app
    }

    static func findApp(in dir: String) -> String? {
        let fm = FileManager.default
        if let a = (try? fm.contentsOfDirectory(atPath: dir))?.first(where: { $0.hasSuffix(".app") }) { return a }
        if let a = (try? fm.contentsOfDirectory(atPath: dir + "/Applications"))?.first(where: { $0.hasSuffix(".app") }) { return "Applications/" + a }
        return nil
    }

    // MARK: Media creation

    static func createInstallMedia(app: String, info: MacInstallerInfo, volume: String, ctx: JobContext) throws {
        let r = ctx.reporter
        r.begin("Creating install media", detail: "createinstallmedia (\(info.displayName))")
        var args = ["--volume", volume, "--nointeraction"]
        if info.needsApplicationPath { args += ["--applicationpath", app] }
        var exe = app + "/Contents/Resources/createinstallmedia"
        var finalArgs = args
        if info.requiresRosetta {
            finalArgs = ["-x86_64", exe] + args
            exe = "/usr/bin/arch"
        }
        var stage = ""
        try Shell.check(exe, finalArgs, cancel: ctx.cancel) { line in
            logDebug(line)
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("Erasing disk") { stage = "Erasing disk" }
            else if l.hasPrefix("Copying to disk") || l.hasPrefix("Copying installer files") || l.hasPrefix("Copying") { stage = "Copying installer files" }
            else if l.hasPrefix("Making disk bootable") { stage = "Making disk bootable" }
            else if l.hasPrefix("Copying boot files") { stage = "Copying boot files" }
            // createinstallmedia prints "0%... 10%... 20%..." — use the last percentage on the line.
            let pcts = numbers(in: l, pattern: #"(\d+)%"#)
            let weights: [String: (Double, Double)] = ["Erasing disk": (0, 0.05), "Copying installer files": (0.05, 0.9), "Making disk bootable": (0.95, 0.03), "Copying boot files": (0.98, 0.02)]
            if let p = pcts.last, let w = weights[stage] {
                r.update(fraction: w.0 + w.1 * p / 100, detail: stage)
            } else if !stage.isEmpty {
                r.update(fraction: nil, detail: stage)
            }
            if l.contains("Install media now available") { logInfo(l) }
        }
    }

    static func numbers(in text: String, pattern: String) -> [Double] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { Double(ns.substring(with: $0.range(at: 1))) }
    }

    /// Lion / Mountain Lion: restore InstallESD.dmg to the volume with Apple Software Restore.
    static func asrRestore(app: String, volume: String, ctx: JobContext) throws {
        let r = ctx.reporter
        let esd = app + "/Contents/SharedSupport/InstallESD.dmg"
        r.begin("Creating install media", detail: "Apple Software Restore")
        try Shell.check("/usr/sbin/asr", ["restore", "--source", esd, "--target", volume, "--erase", "--noprompt", "--noverify"], cancel: ctx.cancel) { line in
            // "Restoring  ....10....20....30..."
            let nums = numbers(in: line, pattern: #"(\d+)"#).filter { $0 <= 100 }
            if let p = nums.last { r.update(fraction: p / 100, detail: line.contains("Restoring") ? "Restoring" : "Validating") }
        }
    }
}

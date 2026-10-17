import Foundation

/// Identifies macOS installers (apps, packages and Apple's legacy DMGs).
public enum MacInstallerInspector {

    /// Marketing names → major versions.
    public static let releaseNames: [(String, String)] = [
        ("Golden Gate", "27"), ("Tahoe", "26"), ("Sequoia", "15"), ("Sonoma", "14"), ("Ventura", "13"), ("Monterey", "12"),
        ("Big Sur", "11"), ("Catalina", "10.15"), ("Mojave", "10.14"), ("High Sierra", "10.13"),
        ("Sierra", "10.12"), ("El Capitan", "10.11"), ("Yosemite", "10.10"), ("Mavericks", "10.9"),
        ("Mountain Lion", "10.8"), ("Lion", "10.7"),
    ]

    public static func majorVersion(fromName name: String) -> String? {
        // "High Sierra" must be tested before "Sierra", "Mountain Lion" before "Lion" (list order handles it).
        releaseNames.first { name.localizedCaseInsensitiveContains($0.0) }?.1
    }

    /// Compare dotted versions ("10.13" < "10.14", "11" > "10.15").
    public static func versionLess(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedAscending
    }

    public static func inspectApp(_ appPath: String) throws -> MacInstallerInfo {
        let fm = FileManager.default
        let infoPath = appPath + "/Contents/Info.plist"
        guard let info = NSDictionary(contentsOfFile: infoPath) as? [String: Any] else {
            throw BootKitError.unsupportedImage("\((appPath as NSString).lastPathComponent) is not an application bundle.")
        }
        let display = (info["CFBundleDisplayName"] as? String) ?? (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        var name = display.replacingOccurrences(of: "Install ", with: "")
        let cim = appPath + "/Contents/Resources/createinstallmedia"
        let hasCIM = fm.isExecutableFile(atPath: cim)
        let hasInstallESD = fm.fileExists(atPath: appPath + "/Contents/SharedSupport/InstallESD.dmg")
        let hasSharedSupport = fm.fileExists(atPath: appPath + "/Contents/SharedSupport/SharedSupport.dmg")
        guard hasCIM || hasInstallESD || hasSharedSupport else {
            throw BootKitError.unsupportedImage("\(display) is not a full macOS installer (it may be a stub app). Download the full installer instead.")
        }

        var version: String?
        var build: String?
        // macOS 10.13 - 10.15
        if let ii = NSDictionary(contentsOfFile: appPath + "/Contents/SharedSupport/InstallInfo.plist") as? [String: Any],
           let sys = ii["System Image Info"] as? [String: Any] {
            version = sys["version"] as? String
        }
        // macOS 11+: version inside SharedSupport.dmg (mobile asset description)
        if version == nil, hasSharedSupport, let (v, b) = sharedSupportVersion(appPath + "/Contents/SharedSupport/SharedSupport.dmg") {
            version = v
            build = b
        }
        if version == nil { version = majorVersion(fromName: name) }
        if !name.lowercased().hasPrefix("macos") && !name.lowercased().hasPrefix("os x") && !name.lowercased().hasPrefix("mac os") {
            name = "macOS " + name
        }

        let major = version ?? majorVersion(fromName: name) ?? "99"
        let legacyRestore = !hasCIM && hasInstallESD // Lion / Mountain Lion
        var needsRosetta = false
        #if arch(arm64)
        if hasCIM, let r = try? Shell.run("/usr/bin/lipo", ["-archs", cim], logCommand: false), r.ok,
           !r.stdout.contains("arm64") {
            needsRosetta = true
        }
        #endif
        return MacInstallerInfo(
            appPath: appPath, name: name, version: version, build: build,
            hasCreateInstallMedia: hasCIM,
            needsApplicationPath: hasCIM && versionLess(major, "10.14"),
            isLegacyRestore: legacyRestore,
            requiresRosetta: needsRosetta,
            minimumUSBSize: versionLess(major, "11") ? 7_500_000_000 : 14_000_000_000)
    }

    /// Read OSVersion/Build from SharedSupport.dmg (macOS 11+).
    static func sharedSupportVersion(_ dmg: String) -> (String, String?)? {
        guard let m = try? DiskImageMount(imagePath: dmg), let root = m.primaryMountPoint else { return nil }
        defer { m.detach() }
        let xml = root + "/com_apple_MobileAsset_MacSoftwareUpdate/com_apple_MobileAsset_MacSoftwareUpdate.xml"
        guard let d = NSDictionary(contentsOfFile: xml) as? [String: Any],
              let assets = d["Assets"] as? [[String: Any]], let a = assets.first else { return nil }
        guard let v = a["OSVersion"] as? String else { return nil }
        return (v, a["Build"] as? String)
    }

    /// InstallAssistant.pkg (Big Sur+) or InstallMacOSX.pkg / InstallOS.pkg (legacy).
    public static func inspectPackage(_ pkgPath: String) throws -> MacInstallerInfo {
        // Sidecar metadata written by our downloader.
        if let meta = DownloadMetadata.load(for: pkgPath), let mac = meta.macInstaller {
            return mac
        }
        var title = (pkgPath as NSString).lastPathComponent
        if let r = try? Shell.run("/usr/sbin/installer", ["-pkginfo", "-pkg", pkgPath], logCommand: false), r.ok {
            if let first = r.stdout.split(separator: "\n").first { title = String(first) }
        }
        let name = title.replacingOccurrences(of: "Install ", with: "")
        let major = majorVersion(fromName: name)
        let legacy = (pkgPath as NSString).lastPathComponent.lowercased().hasPrefix("installmacosx") ||
                     (pkgPath as NSString).lastPathComponent.lowercased().hasPrefix("installos")
        return MacInstallerInfo(
            appPath: nil, name: name.hasPrefix("macOS") || name.hasPrefix("OS X") ? name : "macOS \(name)",
            version: major, build: nil,
            hasCreateInstallMedia: true,
            needsApplicationPath: major.map { versionLess($0, "10.14") } ?? legacy,
            isLegacyRestore: major.map { versionLess($0, "10.9") } ?? false,
            requiresRosetta: false,
            minimumUSBSize: (major.map { versionLess($0, "11") } ?? legacy) ? 7_500_000_000 : 14_000_000_000)
    }

    /// Apple's legacy InstallMacOSX.dmg / InstallOS.dmg, or a DMG containing an installer app.
    public static func inspectDMG(_ dmgPath: String) throws -> MacInstallerInfo? {
        let m = try DiskImageMount(imagePath: dmgPath)
        defer { m.detach() }
        guard let root = m.primaryMountPoint,
              let items = try? FileManager.default.contentsOfDirectory(atPath: root) else { return nil }
        if let app = items.first(where: { $0.hasSuffix(".app") && $0.hasPrefix("Install") }) {
            var info = try inspectApp(root + "/" + app)
            info.appPath = nil // only valid while mounted
            return info
        }
        if let pkg = items.first(where: { $0.hasSuffix(".pkg") && ($0.hasPrefix("InstallMacOSX") || $0.hasPrefix("InstallOS")) }) {
            var info = try inspectPackage(root + "/" + pkg)
            if let meta = DownloadMetadata.load(for: dmgPath), let mac = meta.macInstaller { info = mac }
            return info
        }
        return nil
    }
}

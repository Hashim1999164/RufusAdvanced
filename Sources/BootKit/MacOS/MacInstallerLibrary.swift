import Foundation
import Security

/// macOS installers on this Mac: finds "Install macOS *.app" bundles, verifies them, and installs
/// Apple's InstallAssistant.pkg into /Applications (the "download → install → use" assistant).
public enum MacInstallerLibrary {

    /// One check shown to the user ("Apple code signature ✓").
    public struct Check: Codable, Sendable, Equatable, Identifiable {
        public var title: String
        public var ok: Bool
        public var detail: String
        public var id: String { title }
        public init(_ title: String, _ ok: Bool, _ detail: String) { self.title = title; self.ok = ok; self.detail = detail }
    }

    /// An installer app found on this Mac and the result of verifying it.
    public struct Found: Sendable, Identifiable, Equatable {
        public var path: String
        public var info: MacInstallerInfo?
        public var checks: [Check]
        public var id: String { path }
        public var isUsable: Bool { info != nil && checks.allSatisfy(\.ok) }
        public var problem: String? { checks.first { !$0.ok }.map { "\($0.title): \($0.detail)" } }
    }

    public static var searchFolders: [String] {
        // RUFUSADV_INSTALLER_DIRS (colon separated) replaces the defaults: development / screenshots.
        if let dirs = ProcessInfo.processInfo.environment["RUFUSADV_INSTALLER_DIRS"] {
            return dirs.split(separator: ":").map(String.init)
        }
        return ["/Applications", NSHomeDirectory() + "/Applications"]
    }

    /// "Install macOS *.app" / "Install OS X *.app" bundles in the search folders (fast, no inspection).
    public static func installerApps(in folders: [String] = searchFolders) -> [String] {
        var out: [String] = []
        for f in folders {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: f) else { continue }
            for i in items.sorted() where i.hasPrefix("Install ") && i.hasSuffix(".app") {
                let p = f + "/" + i
                // Only bundles that look like macOS installers (have an InstallAssistant-style layout).
                if FileManager.default.fileExists(atPath: p + "/Contents/Resources/createinstallmedia")
                    || FileManager.default.fileExists(atPath: p + "/Contents/SharedSupport")
                    || i.contains("macOS") || i.contains("OS X") {
                    out.append(p)
                }
            }
        }
        return out
    }

    /// Inspect + verify every installer found (slow: mounts SharedSupport.dmg to read the version).
    public static func scan(in folders: [String] = searchFolders) -> [Found] {
        installerApps(in: folders).map { verify(app: $0) }
            .sorted { MacInstallerInspector.versionLess($1.info?.version ?? "0", $0.info?.version ?? "0") }
    }

    // MARK: Verification

    /// Check that an installer app is complete, genuine and usable for createinstallmedia.
    public static func verify(app: String) -> Found {
        let fm = FileManager.default
        var checks: [Check] = []
        var info: MacInstallerInfo?
        do {
            info = try MacInstallerInspector.inspectApp(app)
            checks.append(Check("Full installer", true, "\(info!.displayName)\(info!.build.map { " (\($0))" } ?? "")"))
        } catch {
            checks.append(Check("Full installer", false, error.userMessage))
            return Found(path: app, info: nil, checks: checks)
        }
        let cim = app + "/Contents/Resources/createinstallmedia"
        let shared = app + "/Contents/SharedSupport/SharedSupport.dmg"
        let esd = app + "/Contents/SharedSupport/InstallESD.dmg"
        if fm.fileExists(atPath: shared) || fm.fileExists(atPath: esd) {
            let payload = fm.fileExists(atPath: shared) ? shared : esd
            let size = (try? fm.attributesOfItem(atPath: payload)[.size] as? UInt64) ?? 0
            // Real payloads are 4.5 GB (InstallESD) to 15 GB (SharedSupport); a truncated copy is much smaller.
            let ok = size > 2 * Units.GB
            checks.append(Check("Installer payload", ok, "\((payload as NSString).lastPathComponent), \(Units.human(size, decimal: true))\(ok ? "" : " (incomplete: download the installer again)")"))
        } else if info!.hasCreateInstallMedia {
            // 10.13 - 10.15 apps installed from the package set keep the payload elsewhere.
            checks.append(Check("Installer payload", true, "createinstallmedia layout"))
        }
        if fm.isExecutableFile(atPath: cim) {
            checks.append(signatureCheck("Apple signature (createinstallmedia)", path: cim))
        } else if !info!.isLegacyRestore {
            checks.append(Check("createinstallmedia", false, "missing from the app"))
        }
        checks.append(signatureCheck("Apple signature (app)", path: app))
        #if arch(arm64)
        if info!.requiresRosetta {
            let rosetta = (try? Shell.run("/usr/bin/arch", ["-x86_64", "/usr/bin/true"], logCommand: false))?.ok ?? false
            checks.append(Check("Rosetta 2", rosetta, rosetta ? "installed" : "needed by this older installer: softwareupdate --install-rosetta"))
        }
        #endif
        return Found(path: app, info: info, checks: checks)
    }

    /// Is `path` signed by Apple? Resources are not re-hashed (that would read the whole 13 GB payload);
    /// the payload itself was hash-verified when it was downloaded.
    static func signatureCheck(_ title: String, path: String) -> Check {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else {
            return Check(title, false, "cannot read the code signature")
        }
        var req: SecRequirement?
        SecRequirementCreateWithString("anchor apple" as CFString, [], &req)
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources | kSecCSCheckAllArchitectures)
        let st = SecStaticCodeCheckValidity(code, flags, req)
        if st == errSecSuccess { return Check(title, true, "signed by Apple") }
        let msg = (SecCopyErrorMessageString(st, nil) as String?) ?? "error \(st)"
        return Check(title, false, msg)
    }

    /// `pkgutil --check-signature`: must be signed by Apple.
    public static func checkPackageSignature(_ pkg: String) -> Check {
        guard let r = try? Shell.run("/usr/sbin/pkgutil", ["--check-signature", pkg], logCommand: false) else {
            return Check("Package signature", false, "pkgutil failed")
        }
        let out = r.stdout
        let apple = out.contains("Status: signed Apple Software") || (out.contains("Apple Inc.") && out.contains("Status: signed"))
        if r.ok && apple { return Check("Package signature", true, "signed by Apple") }
        let status = out.split(separator: "\n").first { $0.contains("Status:") }.map { $0.trimmingCharacters(in: .whitespaces) } ?? r.combined
        return Check("Package signature", false, status.isEmpty ? "not signed by Apple" : status)
    }

    // MARK: Installing a package (runs as root in the helper)

    /// `installer -pkg <pkg> -target /`, then locate and verify the new "Install macOS *.app".
    @discardableResult
    public static func install(package pkg: String, reporter r: JobReporter, cancel: CancellationToken,
                               ownerUID: UInt32, ownerGID: UInt32) throws -> String {
        r.plan([("Checking package", 2), ("Installing to Applications", 90), ("Verifying installer", 8)])
        r.begin("Checking package", detail: (pkg as NSString).lastPathComponent)
        guard FileManager.default.fileExists(atPath: pkg) else { throw BootKitError.fileAccess(pkg, ENOENT, target: false) }
        let sig = checkPackageSignature(pkg)
        logInfo("\(sig.title): \(sig.detail)")
        guard sig.ok else { throw BootKitError.generic("Refusing to install \((pkg as NSString).lastPathComponent): \(sig.detail).") }

        let before = Dictionary(uniqueKeysWithValues: installerApps(in: ["/Applications"]).map { ($0, modDate($0)) })
        r.begin("Installing to Applications", detail: "installer -pkg \((pkg as NSString).lastPathComponent) -target /")
        try Shell.check("/usr/sbin/installer", ["-pkg", pkg, "-target", "/", "-verboseR"], cancel: cancel) { line in
            if line.hasPrefix("installer:%"), let v = Double(line.dropFirst("installer:%".count)) {
                r.update(fraction: v / 100)
            } else if line.hasPrefix("installer:PHASE:") {
                r.update(fraction: nil, detail: String(line.dropFirst("installer:PHASE:".count)))
            } else if line.hasPrefix("installer:STATUS:") {
                let s = String(line.dropFirst("installer:STATUS:".count))
                if !s.isEmpty { r.update(fraction: nil, detail: s) }
            }
        }
        // The new or updated app.
        let after = installerApps(in: ["/Applications"])
        guard let app = after.filter({ before[$0] == nil || modDate($0) > before[$0]! }).max(by: { modDate($0) < modDate($1) })
                ?? after.max(by: { modDate($0) < modDate($1) }) else {
            throw BootKitError.generic("The package was installed but no 'Install macOS' app appeared in /Applications.")
        }
        // Let the user own it (move/delete it without a password, like an App Store download).
        _ = try? Shell.run("/usr/sbin/chown", ["-R", "\(ownerUID):\(ownerGID)", app], logCommand: false)

        r.begin("Verifying installer", detail: (app as NSString).lastPathComponent)
        let found = verify(app: app)
        for c in found.checks { (c.ok ? logInfo : logWarning)("\(c.title): \(c.detail)") }
        guard found.isUsable else { throw BootKitError.generic("\((app as NSString).lastPathComponent) failed verification: \(found.problem ?? "unknown problem")") }
        r.notice("Installed: \(app)")
        return app
    }

    static func modDate(_ p: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? .distantPast
    }

    /// The "Installed: <path>" notice of a finished install job.
    public static func installedPath(fromNotices notices: [String]) -> String? {
        notices.first { $0.hasPrefix("Installed: ") }.map { String($0.dropFirst("Installed: ".count)) }
    }
}

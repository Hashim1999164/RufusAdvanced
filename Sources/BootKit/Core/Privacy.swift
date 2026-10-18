import Foundation

/// macOS privacy protection (TCC) helpers.
///
/// Root jobs (macOS installers) are started through the system administrator dialog. macOS does not
/// always carry the app's privacy permissions over to such a process, so it may be refused access to
/// ~/Downloads, ~/Desktop, ~/Documents and to USB volumes. These helpers keep root jobs away from
/// protected folders and explain what to grant when access is refused.
public enum Privacy {

    /// System Settings › Privacy & Security › Full Disk Access.
    public static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Does this process (or its responsible app) have Full Disk Access? Probes a file that only
    /// Full Disk Access can open; nil when that can't be determined.
    public static func hasFullDiskAccess() -> Bool? {
        let probe = "/Library/Application Support/com.apple.TCC/TCC.db"
        let fd = open(probe, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return errno == EPERM || errno == EACCES ? false : nil
    }

    /// The process macOS holds responsible for this one (whose privacy permissions apply).
    public static func responsibleProcess() -> (pid: pid_t, path: String)? {
        typealias Fn = @convention(c) (pid_t) -> pid_t
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else { return nil }
        let pid = unsafeBitCast(sym, to: Fn.self)(getpid())
        guard pid > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return (pid, "?") }
        return (pid, String(cString: buf))
    }

    /// Folders macOS protects per app (Files and Folders / iCloud).
    public static func isProtectedLocation(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        let p = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return ["/Downloads", "/Desktop", "/Documents", "/Library/Mobile Documents"].contains { p.hasPrefix(home + $0 + "/") }
    }

    /// For a root job: an instant APFS clone of `path` in a folder macOS doesn't protect
    /// (~/Library/Caches/RufusAdvanced/staging). Returns nil when the file isn't in a protected
    /// folder or can't be cloned (another volume): use the original then.
    public static func stageForRootJob(_ path: String) -> String? {
        guard isProtectedLocation(path) else { return nil }
        return cloneToStaging(path)
    }

    /// Instant APFS clone of `path` into the staging folder (nil when it can't be cloned).
    static func cloneToStaging(_ path: String) -> String? {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.path
            + "/RufusAdvanced/staging/" + UUID().uuidString.prefix(8)
        try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let dst = base + "/" + (path as NSString).lastPathComponent
        guard clonefile(path, dst, 0) == 0 else {
            logDebug("Could not clone \(path) for the administrator job (\(String(cString: strerror(errno)))); using it in place")
            try? FileManager.default.removeItem(atPath: base)
            return nil
        }
        logInfo("Prepared \((path as NSString).lastPathComponent) for the administrator job (instant APFS copy, no extra space)")
        return dst
    }

    /// Remove a copy made by `stageForRootJob`.
    public static func removeStaged(_ staged: String) {
        let dir = (staged as NSString).deletingLastPathComponent
        guard dir.contains("/RufusAdvanced/staging/") else { return }
        try? FileManager.default.removeItem(atPath: dir)
    }
}

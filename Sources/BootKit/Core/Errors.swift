import Foundation

/// Errors raised by the BootKit engine. Messages are written for end users.
public enum BootKitError: Error, LocalizedError, Sendable {
    case cancelled
    case deviceNotFound(String)
    case deviceChanged(String)
    case deviceIsInternal(String)
    case deviceTooSmall(needed: UInt64, available: UInt64)
    case openFailed(String, Int32)
    case readFailed(String, Int32)
    case writeFailed(String, Int32)
    case ioctlFailed(String, Int32)
    case commandFailed(String, Int32, String)
    case toolMissing(tool: String, hint: String)
    case unsupportedImage(String)
    case unsupported(String)
    case invalidOption(String)
    case partitionNotFound(String)
    case mountFailed(String)
    case verificationFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case network(String)
    case badBlocks(Int)
    case generic(String)
    /// macOS refused access to a disk device (EPERM / EACCES), even through authopen.
    case permissionDenied(path: String, errno: Int32, detail: String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "The operation was cancelled."
        case .deviceNotFound(let d): return "The device \(d) could not be found. Was it unplugged?"
        case .deviceChanged(let d): return "The device \(d) changed since it was selected. Please re-select it."
        case .deviceIsInternal(let d): return "\(d) is an internal disk. Refusing to touch it."
        case .deviceTooSmall(let n, let a):
            return "The target device is too small: \(Units.human(n)) needed but only \(Units.human(a)) available."
        case .openFailed(let p, let e): return "Could not open \(p): \(String(cString: strerror(e)))"
        case .readFailed(let p, let e): return "Read error on \(p): \(String(cString: strerror(e)))"
        case .writeFailed(let p, let e): return "Write error on \(p): \(String(cString: strerror(e)))"
        case .ioctlFailed(let p, let e): return "Device control failed (\(p)): \(String(cString: strerror(e)))"
        case .commandFailed(let c, let code, let out):
            let tail = out.split(separator: "\n").suffix(4).joined(separator: "\n")
            return "\(c) failed (exit code \(code)).\(tail.isEmpty ? "" : "\n\(tail)")"
        case .toolMissing(let t, let h): return "The external tool '\(t)' is required but was not found. \(h)"
        case .unsupportedImage(let s): return "Unsupported image: \(s)"
        case .unsupported(let s): return s
        case .invalidOption(let s): return "Invalid option: \(s)"
        case .partitionNotFound(let s): return "Partition \(s) did not appear after partitioning."
        case .mountFailed(let s): return "Could not mount \(s)."
        case .verificationFailed(let s): return "Verification failed: \(s)"
        case .checksumMismatch(let e, let a): return "Checksum mismatch.\nExpected: \(e)\nActual:   \(a)"
        case .network(let s): return "Network error: \(s)"
        case .badBlocks(let n): return "\(n) bad block(s) were found on the device. It is not safe to use."
        case .generic(let s): return s
        case .permissionDenied(let p, let e, let detail):
            return BootKitError.permissionAdvice(path: p, errno: e, detail: detail)
        }
    }
}

extension BootKitError {
    /// Error for a file that could not be opened on the mounted image or USB volume, with advice
    /// when macOS privacy protection (EPERM / EACCES) is the cause.
    public static func fileAccess(_ path: String, _ e: Int32, target: Bool) -> BootKitError {
        guard e == EPERM || e == EACCES else { return .openFailed(path, e) }
        let where_ = target ? "Removable Volumes" : "the folder that holds the image (Downloads, Desktop or Documents)"
        return .generic("macOS blocked access to \(path) (\(String(cString: strerror(e)))). Open System Settings › Privacy & Security › Files and Folders, allow RufusAdvanced to access \(where_), then try again. Granting Full Disk Access to RufusAdvanced also fixes this.")
    }

    /// Plain-language explanation plus what to do about EPERM / EACCES on a disk device.
    public static func permissionAdvice(path: String, errno e: Int32, detail: String) -> String {
        let reason = e > 0 ? String(cString: strerror(e)) : "authorization failed"
        var steps: [String] = []
        if let warning = AppLocation.warning {
            steps.append(warning)
        }
        steps.append("Click START again and enter your Mac password in the dialog that asks to write to the drive (an administrator account is required).")
        steps.append("If it still fails: System Settings › Privacy & Security › Full Disk Access › enable RufusAdvanced (use + to add it from /Applications), then quit and reopen the app.")
        steps.append("Make sure no other app (Disk Utility, Finder copy, antivirus) is using the drive.")
        var text = "macOS did not allow RufusAdvanced to write to the drive (\(path): \(reason))."
        text += "\n" + steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        if !detail.isEmpty { text += "\nDetails: \(detail)" }
        return text
    }
}

/// Where the app bundle runs from. macOS privacy protection (TCC) and App Translocation make
/// authorization unreliable for apps started from Desktop, Documents, Downloads or a quarantined
/// download, so we tell the user to move the app to /Applications.
public enum AppLocation {
    /// Path of the enclosing .app bundle, if any (the helper lives in Contents/MacOS of the app).
    public static var bundlePath: String? {
        var url = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        if let exe = Bundle.main.executableURL { url = exe.resolvingSymlinksInPath() }
        while url.pathComponents.count > 1 {
            if url.pathExtension == "app" { return url.path }
            url.deleteLastPathComponent()
        }
        return nil
    }

    public static var isTranslocated: Bool { bundlePath?.contains("/AppTranslocation/") ?? false }

    /// True when running from a privacy-protected or temporary folder.
    public static var isProtectedLocation: Bool {
        guard let p = bundlePath else { return false }
        if isTranslocated { return true }
        let home = NSHomeDirectory()
        return ["Desktop", "Documents", "Downloads"].contains { p.hasPrefix(home + "/" + $0 + "/") }
            || p.hasPrefix("/Volumes/") || p.hasPrefix("/private/var/folders/") || p.hasPrefix(NSTemporaryDirectory())
    }

    /// User-facing warning, or nil when the location is fine.
    public static var warning: String? {
        guard isProtectedLocation, let p = bundlePath else { return nil }
        let folder = isTranslocated ? "a quarantined download location" : (p as NSString).deletingLastPathComponent
        return "RufusAdvanced is running from \(folder). Quit it, move RufusAdvanced.app to the Applications folder, and open it from there (apps run from Desktop, Documents, Downloads or a disk image can't reliably get permission to write to drives)."
    }
}

public extension Error {
    var userMessage: String {
        (self as? LocalizedError)?.errorDescription ?? String(describing: self)
    }
}

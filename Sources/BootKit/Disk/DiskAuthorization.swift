import Foundation
import Security
import CBootKit

/// Raw disk access without Full Disk Access.
///
/// Since macOS 10.15 opening `/dev/rdiskN` fails with EPERM — even as root — unless the
/// responsible app has Full Disk Access. Apple's `/usr/libexec/authopen` is entitled to open disk
/// devices for an authorized user, so (like Etcher and Raspberry Pi Imager) we pre-authorize the
/// "sys.openfile" rights for the target disk and its partitions once — one password dialog — and
/// let authopen hand us file descriptors for every later open.
public final class DiskAuthorization: @unchecked Sendable {
    public static let shared = DiskAuthorization()

    private var authRef: AuthorizationRef?
    private var authorizedDisks = Set<String>()
    private let lock = NSLock()

    /// Text shown in the authorization dialog.
    public var prompt = "RufusAdvanced needs your permission to write to the selected drive."

    private init() {}

    deinit {
        if let a = authRef { AuthorizationFree(a, []) }
    }

    /// "disk9" for "/dev/rdisk9s1".
    static func wholeDisk(of path: String) -> String? {
        let name = (path as NSString).lastPathComponent.replacingOccurrences(of: "rdisk", with: "disk")
        guard let r = name.range(of: "^disk[0-9]+", options: .regularExpression) else { return nil }
        return String(name[r])
    }

    static func rightNames(for disk: String) -> [String] {
        var paths: [String] = []
        for prefix in ["/dev/r", "/dev/"] {
            paths.append(prefix + disk)
            for s in 1...8 { paths.append("\(prefix)\(disk)s\(s)") }
        }
        return paths.flatMap { ["sys.openfile.readwrite.\($0)", "sys.openfile.readonly.\($0)"] }
    }

    /// Ask once for read/write access to a disk and all its partitions.
    public func authorize(disk: String) throws {
        lock.lock(); defer { lock.unlock() }
        if authorizedDisks.contains(disk) { return }
        logDebug("Authorization: requesting sys.openfile rights for /dev/\(disk), /dev/r\(disk) and partitions s1–s8 (uid \(getuid()), euid \(geteuid()))")
        if let w = AppLocation.warning { logWarning(w) }
        if authRef == nil {
            var ref: AuthorizationRef?
            let st = AuthorizationCreate(nil, nil, [], &ref)
            logDebug("AuthorizationCreate → \(st)")
            guard st == errAuthorizationSuccess, let ref else {
                if st == errAuthorizationInternal {
                    throw BootKitError.permissionDenied(path: "/dev/r\(disk)", errno: EPERM, detail: "AuthorizationCreate failed (\(st))")
                }
                throw BootKitError.generic("Could not create an authorization (OSStatus \(st)).")
            }
            authRef = ref
        }
        let names = Self.rightNames(for: disk).map { strdup($0)! }
        defer { names.forEach { free($0) } }
        var items = names.map { AuthorizationItem(name: UnsafePointer($0), valueLength: 0, value: nil, flags: 0) }
        let promptC = strdup(prompt)!
        defer { free(promptC) }
        let iconPath = BootResources.root.deletingLastPathComponent().appendingPathComponent("AppIcon.icns").path
        let iconC = strdup(iconPath)!
        defer { free(iconC) }
        // The item names must outlive AuthorizationCopyRights: keep our own C copies
        // (passing the Swift String constants directly would leave dangling pointers).
        let promptKey = strdup(kAuthorizationEnvironmentPrompt)!
        let iconKey = strdup(kAuthorizationEnvironmentIcon)!
        defer { free(promptKey); free(iconKey) }
        var envItems = [AuthorizationItem(name: UnsafePointer(promptKey), valueLength: strlen(promptC), value: promptC, flags: 0)]
        if FileManager.default.fileExists(atPath: iconPath) {
            envItems.append(AuthorizationItem(name: UnsafePointer(iconKey), valueLength: strlen(iconC), value: iconC, flags: 0))
        }
        logInfo("Asking for permission to write to \(disk) (password dialog)…")
        let status: OSStatus = items.withUnsafeMutableBufferPointer { ib in
            envItems.withUnsafeMutableBufferPointer { eb in
                var rights = AuthorizationRights(count: UInt32(ib.count), items: ib.baseAddress)
                var env = AuthorizationEnvironment(count: UInt32(eb.count), items: eb.baseAddress)
                return AuthorizationCopyRights(authRef!, &rights, &env, [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        logDebug("AuthorizationCopyRights(\(names.count) rights) → OSStatus \(status)")
        switch status {
        case errAuthorizationSuccess:
            authorizedDisks.insert(disk)
            logInfo("Access to \(disk) authorized")
        case errAuthorizationCanceled:
            throw BootKitError.cancelled
        case errAuthorizationDenied, errAuthorizationInteractionNotAllowed, errAuthorizationInternal:
            throw BootKitError.permissionDenied(path: "/dev/r\(disk)", errno: EPERM,
                                                detail: "authorization \(status == errAuthorizationDenied ? "denied" : "failed") (OSStatus \(status))")
        default:
            throw BootKitError.generic("Authorization for \(disk) failed (OSStatus \(status)).")
        }
    }

    /// Open a disk device through authopen.
    public func open(_ path: String, flags: Int32) throws -> Int32 {
        guard let disk = Self.wholeDisk(of: path) else { throw BootKitError.openFailed(path, EPERM) }
        try authorize(disk: disk)
        lock.lock()
        var ext = AuthorizationExternalForm()
        let st = authRef.map { AuthorizationMakeExternalForm($0, &ext) } ?? errAuthorizationInvalidRef
        lock.unlock()
        guard st == errAuthorizationSuccess else { throw BootKitError.generic("Authorization export failed (OSStatus \(st)).") }
        var err = [CChar](repeating: 0, count: 512)
        var exitStatus: Int32 = 0
        let mode = (flags & O_ACCMODE) == O_RDONLY ? "read-only" : "read/write"
        logDebug("$ /usr/libexec/authopen -stdoutpipe -extauth -o \(flags) \(path)   (\(mode))")
        let fd: Int32 = withUnsafeBytes(of: &ext) { raw in
            cbk_authopen(path, flags, raw.baseAddress, raw.count, &err, err.count, &exitStatus)
        }
        logDebug("authopen exit status \(exitStatus)\(exitStatus > 0 ? " (\(String(cString: strerror(exitStatus))))" : ""), fd \(fd)")
        if fd < 0 {
            let message = String(cString: err)
            switch exitStatus {
            case EPERM, EACCES, 0, -1:
                throw BootKitError.permissionDenied(path: path, errno: exitStatus > 0 ? exitStatus : EPERM, detail: message)
            case EBUSY:
                throw BootKitError.generic("\(path) is busy. Close any app using the drive (Finder windows, Disk Utility, backup or antivirus software) and try again.")
            default:
                throw BootKitError.openFailed(path, exitStatus)
            }
        }
        logDebug("Opened \(path) through authopen (fd \(fd))")
        return fd
    }
}

import Foundation
import AppKit
import BootKit

/// Checks everything RufusAdvanced needs from macOS at launch (and whenever the app becomes active
/// again, e.g. after returning from System Settings) and lists what is missing with a one-click fix.
@MainActor
final class PermissionManager: ObservableObject {
    enum Status: Equatable {
        case ok
        case missing          // something will fail without it
        case recommended      // optional, but some features need it
        case unknown
    }

    struct Item: Identifiable, Equatable {
        enum Action: Equatable {
            case openURL(URL, String)            // (destination, button title)
            case revealApp
            case requestDownloads
            case copy(String, String)            // (text, button title)
        }
        var id: String
        var title: String
        var detail: String
        var symbol: String
        var status: Status
        var actions: [Action] = []
    }

    @Published private(set) var items: [Item] = []
    @Published var showSheet = false
    private var observer: NSObjectProtocol?
    private var checkedDownloads = false

    static let filesAndFoldersURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!
    static let loginItemsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    var problems: [Item] { items.filter { $0.status == .missing } }
    var suggestions: [Item] { items.filter { $0.status == .recommended } }
    var needsAttention: Bool { !problems.isEmpty || !suggestions.isEmpty }

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// At launch: check, and show the list when something needs attention.
    func checkAtLaunch() {
        checkedDownloads = true      // macOS may ask once for the download folder
        refresh()
        logPermissionSummary()
        if needsAttention && AppSettings.shared.showPermissionsAtLaunch { showSheet = true }
    }

    func refresh() {
        var list: [Item] = []

        // 1. Where the app runs from.
        let bundle = AppLocation.bundlePath
        let inApplications = bundle.map { $0.hasPrefix("/Applications/") || $0.hasPrefix(NSHomeDirectory() + "/Applications/") } ?? false
        if AppLocation.isTranslocated || AppLocation.isProtectedLocation {
            list.append(Item(id: "location", title: "Run RufusAdvanced from Applications",
                             detail: "It is running from \(AppLocation.isTranslocated ? "a quarantined download location" : ((bundle ?? "?") as NSString).deletingLastPathComponent). macOS doesn't reliably give drive and folder access to apps there. Quit, move RufusAdvanced.app to Applications and open it from there.",
                             symbol: "folder.badge.questionmark", status: .missing, actions: [.revealApp]))
        } else {
            list.append(Item(id: "location", title: "Installed in Applications",
                             detail: inApplications ? "RufusAdvanced runs from \(((bundle ?? "") as NSString).deletingLastPathComponent)." : "RufusAdvanced runs from a regular folder.",
                             symbol: "checkmark.app", status: inApplications ? .ok : .recommended, actions: inApplications ? [] : [.revealApp]))
        }

        // 2. Administrator account (writing to drives asks for an administrator password).
        let admin = Self.isAdministrator()
        list.append(Item(id: "admin", title: admin ? "Administrator account" : "An administrator password is needed",
                         detail: admin ? "Writing to a drive asks for your password once per operation."
                                       : "Your account is not an administrator: writing to a drive will ask for the name and password of an administrator of this Mac.",
                         symbol: "person.badge.key", status: admin ? .ok : .recommended))

        // 3. Full Disk Access: lets the administrator steps (macOS installers) reach the USB drive and your folders.
        let fda = Privacy.hasFullDiskAccess()
        list.append(Item(id: "fda", title: "Full Disk Access",
                         detail: fda == true ? "Granted. macOS installers can write to the USB drive and read files in Downloads, Desktop and Documents."
                            : "Needed to create macOS installers (createinstallmedia otherwise fails with “The bless of the installer disk failed”) and to read images in protected folders. Turn on RufusAdvanced in the list (use + to add it from Applications), then reopen the app.",
                         symbol: "lock.shield", status: fda == true ? .ok : (fda == false ? .missing : .unknown),
                         actions: fda == true ? [] : [.openURL(Privacy.fullDiskAccessSettingsURL, "Open Full Disk Access")]))

        // 4. Download folder (only relevant without Full Disk Access).
        let folder = AppSettings.shared.downloadFolder
        if fda != true, Privacy.isProtectedLocation(folder + "/x") {
            let state = checkedDownloads ? Self.canAccess(folder) : nil
            list.append(Item(id: "downloads", title: "Access to the download folder",
                             detail: state == true ? "RufusAdvanced can save and read downloads in \(folder)."
                                : state == false ? "macOS blocked access to \(folder). Allow RufusAdvanced under Files and Folders (Downloads Folder), or choose another download folder in Settings."
                                : "Downloads are saved in \(folder). macOS asks once for permission to use it.",
                             symbol: "arrow.down.circle", status: state == true ? .ok : (state == false ? .missing : .unknown),
                             actions: state == false ? [.openURL(Self.filesAndFoldersURL, "Open Files and Folders")] : (state == nil ? [.requestDownloads] : [])))
        }

        // 5. wimlib: FAT32 Windows drives with an install.wim larger than 4 GB (the default) need it.
        let wimlib = ExternalTool.wimlib.isAvailable
        list.append(Item(id: "wimlib", title: wimlib ? "wimlib installed" : "wimlib (recommended)",
                         detail: wimlib ? "Large Windows images can be written to FAT32 (boots everywhere)."
                                        : "Without it, Windows images with an install.wim larger than 4 GB use NTFS + UEFI:NTFS instead of FAT32. Install it with Homebrew: brew install wimlib",
                         symbol: "shippingbox", status: wimlib ? .ok : .recommended,
                         actions: wimlib ? [] : [.copy("brew install wimlib", "Copy command")]))

        if list != items { items = list }
    }

    func perform(_ action: Item.Action) {
        switch action {
        case .openURL(let url, _):
            NSWorkspace.shared.open(url)
        case .revealApp:
            if let p = AppLocation.bundlePath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
        case .requestDownloads:
            // Touching the folder makes macOS ask (once) for permission.
            _ = AppSettings.shared.ensureDownloadFolder()
            checkedDownloads = true
            refresh()
        case .copy(let text, _):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    private func logPermissionSummary() {
        for i in items where i.status != .ok {
            let tag = i.status == .missing ? "missing" : (i.status == .recommended ? "recommended" : "unknown")
            logInfo("Permission check: \(i.title) — \(tag)")
        }
        if !needsAttention { logDebug("Permission check: everything RufusAdvanced needs is in place") }
    }

    static func isAdministrator() -> Bool {
        guard let r = try? Shell.run("/usr/bin/id", ["-Gn"], logCommand: false), r.ok else { return true }
        return r.stdout.split(whereSeparator: { $0 == " " || $0 == "\n" }).contains("admin")
    }

    /// Can this app list `folder`? (May show macOS's one-time permission prompt.)
    static func canAccess(_ folder: String) -> Bool {
        (try? FileManager.default.contentsOfDirectory(atPath: folder)) != nil
    }
}

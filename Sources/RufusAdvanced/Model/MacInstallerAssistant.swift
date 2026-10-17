import Foundation
import AppKit
import BootKit

/// One-click macOS installers: download Apple's InstallAssistant.pkg → install it into /Applications
/// (administrator prompt) → verify the "Install macOS …" app → select it as the source.
/// Also lists installers already on this Mac and picks up installs done with Apple's Installer app.
@MainActor
final class MacInstallerAssistant: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloading
        case authorizing
        case installing
        case verifying
        case done(app: String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .downloading, .authorizing, .installing, .verifying: return true
            default: return false
            }
        }
    }

    @Published private(set) var installed: [MacInstallerLibrary.Found] = []
    @Published private(set) var scanning = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress: JobProgress?
    @Published private(set) var title = ""
    @Published private(set) var checks: [MacInstallerLibrary.Check] = []
    /// The package the current installer came from (offered for deletion once installed).
    @Published private(set) var sourcePackage: String?
    /// Waiting for Apple's Installer app (opened by the user) to put the installer in Applications.
    @Published private(set) var watchingInstallerApp = false
    @Published var showSheet = false

    weak var model: AppModel?
    private var runner: PrivilegedRunner?
    private var download: DownloadManager.Item?
    private var downloadObserver: Timer?
    private var watchTimer: Timer?
    private var watchBaseline: [String: Date] = [:]
    private var watchSizes: [String: UInt64] = [:]
    private var useWhenDone = true

    init() { refresh() }

    // MARK: Installers on this Mac

    func refresh() {
        guard !scanning else { return }
        scanning = true
        Task.detached {
            let found = MacInstallerLibrary.scan()
            await MainActor.run {
                self.installed = found
                self.scanning = false
            }
        }
    }

    /// Quick list without inspection (for the main window hint).
    var installedNames: [String] { installed.map { ($0.path as NSString).lastPathComponent } }

    func use(_ f: MacInstallerLibrary.Found) {
        model?.selectImage(path: f.path)
        showSheet = false
    }

    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }

    // MARK: One click: download + install + verify + use

    func getAndInstall(_ release: MacOSRelease) {
        guard !phase.isBusy, let model else { return }
        guard case .installAssistant = release.payload else {
            // Pre-Big Sur releases are not InstallAssistant packages: download and use them directly.
            model.downloads.download(mac: release, useWhenDone: true)
            return
        }
        title = release.title
        checks = []
        useWhenDone = true
        showSheet = true
        phase = .downloading
        progress = JobProgress(phase: "Downloading from Apple", detail: release.title)
        let item = model.downloads.download(mac: release, useWhenDone: false) { [weak self] path in
            self?.install(package: path, title: release.title)
        }
        download = item
        if let item { observe(item) }
    }

    private func observe(_ item: DownloadManager.Item) {
        downloadObserver?.invalidate()
        downloadObserver = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self, self.phase == .downloading else { t.invalidate(); return }
                switch item.state {
                case .failed(let m):
                    t.invalidate()
                    self.phase = .failed("Download failed: \(m)")
                case .paused:
                    self.progress = JobProgress(phase: "Download paused", detail: "Resume it in the Download Center", fraction: item.fraction)
                default:
                    let p = item.progress
                    self.progress = JobProgress(phase: item.state == .verifying ? "Verifying download (SHA-1)" : "Downloading from Apple",
                                                detail: p.map { "\(Units.human($0.bytes, decimal: true))\($0.total.map { " of " + Units.human($0, decimal: true) } ?? "")" },
                                                fraction: item.fraction, bytesPerSecond: p?.bytesPerSecond)
                }
            }
        }
    }

    /// Install a downloaded InstallAssistant.pkg into /Applications (administrator prompt), verify, then use it.
    func install(package pkg: String, title: String? = nil, use: Bool = true) {
        guard runner == nil, let model else { return }
        downloadObserver?.invalidate()
        self.title = title ?? (pkg as NSString).lastPathComponent
        sourcePackage = pkg
        useWhenDone = use
        checks = []
        showSheet = true
        phase = .authorizing
        progress = JobProgress(phase: "Waiting for the administrator password")
        var spec = JobSpec(disk: "", diskSize: 0, diskMediaName: "")
        spec.operation = .installMacPackage
        spec.imagePath = pkg
        let r = PrivilegedRunner { [weak self] e in self?.handle(e) }
        runner = r
        let modelRef = model
        Task.detached {
            do {
                try r.start(spec)
                await MainActor.run { if self.phase == .authorizing { self.phase = .installing } }
            } catch {
                await MainActor.run {
                    self.runner = nil
                    if case PrivilegedRunner.RunError.authorizationCancelled = error {
                        self.phase = .idle
                        self.progress = nil
                    } else {
                        self.phase = .failed(error.localizedDescription)
                    }
                    _ = modelRef
                }
            }
        }
    }

    private func handle(_ e: JobEvent) {
        switch e {
        case .log(let entry):
            model?.ingest(entry)
        case .progress(let p):
            if phase == .authorizing { phase = .installing }
            if p.phase.hasPrefix("Verifying") { phase = .verifying }
            progress = p
        case .finished(let ok, let err, let notices):
            runner = nil
            progress = nil
            if ok, let app = MacInstallerLibrary.installedPath(fromNotices: notices) {
                finishInstall(app)
            } else if (err ?? "").lowercased().contains("cancel") {
                phase = .idle
            } else {
                phase = .failed(err ?? "The installation failed. See the log for details.")
            }
        default:
            break
        }
    }

    private func finishInstall(_ app: String) {
        phase = .verifying
        Task.detached {
            let found = MacInstallerLibrary.verify(app: app)
            await MainActor.run {
                self.checks = found.checks
                if found.isUsable {
                    self.phase = .done(app: app)
                    logInfo("macOS installer ready: \(app)")
                    NSSound(named: "Glass")?.play()
                    if self.useWhenDone { self.model?.selectImage(path: app) }
                } else {
                    self.phase = .failed(found.problem ?? "The installer did not pass verification.")
                }
                self.refresh()
            }
        }
    }

    func cancel() {
        if let runner { runner.cancel(); return }
        if phase == .downloading, let item = download { model?.downloads.cancel(item) }
        downloadObserver?.invalidate()
        stopWatching()
        phase = .idle
        progress = nil
    }

    /// Size of the source package if it still exists.
    var sourcePackageSize: UInt64? {
        guard let p = sourcePackage else { return nil }
        return try? FileManager.default.attributesOfItem(atPath: p)[.size] as? UInt64
    }

    /// The installer app is in Applications: the package is no longer needed.
    func deleteSourcePackage() {
        guard let p = sourcePackage, let model else { return }
        if model.image?.path == p { return }
        model.downloads.delete(p)
        logInfo("Deleted \(p)")
        sourcePackage = nil
    }

    func reset() {
        guard !phase.isBusy else { return }
        phase = .idle
        progress = nil
        checks = []
    }

    // MARK: Apple's Installer app

    /// Open the package in Apple's Installer and watch /Applications for the result.
    func openInInstaller(_ pkg: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: pkg))
        watchBaseline = Dictionary(uniqueKeysWithValues: MacInstallerLibrary.installerApps().map { ($0, modDate($0)) })
        watchSizes = [:]
        watchingInstallerApp = true
        showSheet = true
        title = (pkg as NSString).lastPathComponent
        logInfo("Opened \(pkg) in Installer; waiting for the installer app to appear in Applications")
        watchTimer?.invalidate()
        watchTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollApplications() }
        }
    }

    func stopWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
        watchingInstallerApp = false
    }

    private func pollApplications() {
        for app in MacInstallerLibrary.installerApps() {
            let changed = watchBaseline[app] == nil || modDate(app) > watchBaseline[app]!
            guard changed else { continue }
            // Wait until the payload stops growing (Installer may still be moving it into place).
            let payload = app + "/Contents/SharedSupport/SharedSupport.dmg"
            let size = (try? FileManager.default.attributesOfItem(atPath: payload)[.size] as? UInt64) ?? 0
            if size > 0, watchSizes[app] == size {
                stopWatching()
                useWhenDone = true
                finishInstall(app)
                return
            }
            watchSizes[app] = size
        }
    }

    private func modDate(_ p: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate] as? Date) ?? .distantPast
    }
}

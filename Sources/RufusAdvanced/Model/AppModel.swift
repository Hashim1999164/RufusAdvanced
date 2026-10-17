import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BootKit

@MainActor
final class AppModel: ObservableObject {
    enum JobState: Equatable { case ready, preparing, running, succeeded, failed(String), cancelled }

    struct Alert: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    // MARK: Devices
    @Published var disks: [DiskInfo] = []
    @Published var selectedDiskID: String? { didSet { if oldValue != selectedDiskID { onDiskChanged() } } }
    var selectedDisk: DiskInfo? { disks.first { $0.id == selectedDiskID } }

    // MARK: Boot selection
    @Published var bootSelection: BootSelection = .image { didSet { if oldValue != bootSelection { applyRecommendation() } } }
    @Published var image: ImageReport?
    @Published var scanning = false
    @Published var recommendationNotes: [String] = []

    // MARK: Options
    @Published var writeMode: WriteMode = .iso { didSet { if oldValue != writeMode { normalizeOptions() } } }
    @Published var scheme: PartitionScheme = .mbr { didSet { if oldValue != scheme { normalizeOptions() } } }
    @Published var target: TargetSystem = .biosOrUefi
    @Published var fileSystem: FileSystemType = .fat32 { didSet { if oldValue != fileSystem { clusterSize = 0 } } }
    @Published var clusterSize: UInt32 = 0
    @Published var label: String = ""
    @Published var quickFormat = true
    @Published var extendedLabel = false
    @Published var badBlocksEnabled = false
    @Published var badBlocksPattern: BadBlocksOptions.PatternSet = .onePass
    @Published var oldBIOSFixes = false
    @Published var uefiValidation = false
    @Published var persistenceMB: Double = 0
    @Published var largeWIMStrategy: LargeWIMStrategy = .splitWIM
    @Published var verifyWrite = false
    @Published var freeDOSKeyboard = FormatWriter.defaultKeyboard()
    @Published var windows: WindowsCustomization = AppSettings.shared.windowsCustomization

    // MARK: Job
    @Published var state: JobState = .ready
    @Published var progress: JobProgress?
    @Published var log: [LogEntry] = []
    @Published var notices: [String] = []

    // MARK: UI
    @Published var alert: Alert?
    @Published var showWindowsSheet = false
    @Published var showConfirm = false
    @Published var showHash = false
    @Published var showSaveImage = false
    @Published var updateAvailable: String?

    let downloads = DownloadManager()
    let settings = AppSettings.shared
    private var watcher: DiskWatcher?
    private var runner: PrivilegedRunner?
    private var activity: NSObjectProtocol?
    private var jobStarted = Date()

    init() {
        Log.shared.verbose = settings.verboseLog
        Log.shared.addSink { [weak self] entry in
            DispatchQueue.main.async { self?.appendLog(entry) }
        }
        downloads.onUse = { [weak self] path in self?.selectImage(path: path) }
        watcher = DiskWatcher { [weak self] in Task { @MainActor in self?.refreshDisks() } }
        watcher?.start()
        refreshDisks()
        logInfo("RufusAdvanced \(BootKit.version) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        applyRecommendation()
        checkForUpdates()
    }

    var isBusy: Bool { state == .running || state == .preparing }

    private func appendLog(_ e: LogEntry) {
        log.append(e)
        if log.count > 20_000 { log.removeFirst(2_000) }
    }

    // MARK: - Devices

    func refreshDisks() {
        guard !isBusy else { return }
        let opts = DiskEnumerator.Options(includeUSBHardDrives: settings.listUSBHardDrives, includeDiskImages: settings.showDiskImages)
        Task.detached {
            let list = DiskEnumerator.list(opts)
            await MainActor.run {
                let old = Set(self.disks.map(\.id))
                self.disks = list
                if let sel = self.selectedDiskID, !list.contains(where: { $0.id == sel }) { self.selectedDiskID = nil }
                if self.selectedDiskID == nil { self.selectedDiskID = list.first?.id }
                let new = Set(list.map(\.id))
                if old != new { logInfo(list.isEmpty ? "No device found" : "\(list.count) device\(list.count == 1 ? "" : "s") found") }
            }
        }
    }

    private func onDiskChanged() {
        if bootSelection != .image && bootSelection != .macInstaller { applyRecommendation() }
        if image == nil && label.isEmpty { applyRecommendation() }
    }

    // MARK: - Image

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "Select a bootable image"
        panel.message = "ISO, IMG, DMG, compressed image (.gz .xz .zip .zst .bz2), VHD, or a macOS installer (app / pkg)"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [] // any file
        if panel.runModal() == .OK, let url = panel.url { selectImage(path: url.path) }
    }

    func selectImage(path: String) {
        guard !isBusy else { return }
        scanning = true
        image = nil
        logInfo("Scanning image: \(path)")
        Task.detached {
            do {
                let report = try ImageInspector.inspect(path: path)
                await MainActor.run {
                    self.scanning = false
                    self.image = report
                    self.bootSelection = report.family == .macOS ? .macInstaller : .image
                    self.applyRecommendation()
                    logInfo("\(report.displayName.isEmpty ? report.fileName : report.displayName) — \(report.summary)")
                    for w in report.warnings { logWarning(w) }
                }
            } catch {
                await MainActor.run {
                    self.scanning = false
                    self.alert = Alert(title: "Unsupported image", message: error.userMessage)
                    logError(error.userMessage)
                }
            }
        }
    }

    func clearImage() {
        image = nil
        applyRecommendation()
    }

    // MARK: - Smart defaults

    func applyRecommendation() {
        let rec: MediaRecommendation
        switch bootSelection {
        case .image, .macInstaller:
            if let image {
                rec = MediaPlanner.recommend(image: image, disk: selectedDisk)
            } else {
                rec = MediaRecommendation(writeMode: .iso, scheme: .gpt, target: .uefi, fileSystem: .fat32, label: "")
            }
        default:
            rec = MediaPlanner.recommend(boot: bootSelection, disk: selectedDisk)
        }
        writeMode = rec.writeMode
        scheme = rec.scheme
        target = rec.target
        fileSystem = rec.fileSystem
        clusterSize = 0
        label = rec.label
        largeWIMStrategy = rec.largeWIMStrategy
        recommendationNotes = rec.notes
        if !(image?.supportsPersistence ?? false) { persistenceMB = 0 }
        normalizeOptions()
    }

    /// Keep the option set coherent when the user changes something.
    func normalizeOptions() {
        let fss = availableFileSystems
        if !fss.isEmpty && !fss.contains(fileSystem) { fileSystem = fss.first! }
        let ts = availableTargets
        if !ts.contains(target) { target = ts.first ?? .uefi }
        if writeMode == .dd { persistenceMB = 0 }
    }

    var availableFileSystems: [FileSystemType] { MediaPlanner.fileSystems(boot: bootSelection, image: image, writeMode: writeMode) }
    var availableTargets: [TargetSystem] { MediaPlanner.targets(boot: bootSelection, image: image, scheme: scheme) }
    var availableSchemes: [PartitionScheme] {
        switch bootSelection {
        case .freeDOS, .syslinux4, .syslinux6, .grub2: return [.mbr]
        case .macInstaller: return [.gpt]
        default: return [.mbr, .gpt]
        }
    }
    var availableClusterSizes: [UInt32] {
        fileSystem.clusterSizes(volumeSize: selectedDisk?.size ?? 16 * Units.GB)
    }
    var availableBootSelections: [BootSelection] {
        BootSelection.allCases.filter { $0 != .macInstaller && (!$0.isAdvanced || settings.showAdvancedDrive) }
    }

    /// Options are irrelevant (DD / macOS installers write their own layout).
    var layoutLocked: Bool {
        (bootSelection == .image && writeMode == .dd) || bootSelection == .macInstaller
    }

    var canUseISOMode: Bool { image?.canUseISOMode ?? false }
    var canUseDDMode: Bool { image?.canUseDDMode ?? false }
    var persistenceAvailable: Bool {
        bootSelection == .image && writeMode == .iso && (image?.supportsPersistence ?? false)
    }
    var maxPersistenceMB: Double {
        guard let disk = selectedDisk, let image else { return 0 }
        let free = Double(disk.size) - Double(image.projectedSize) - Double(256 * Units.MB)
        return max(0, (free / Double(Units.MB)).rounded(.down))
    }

    // MARK: - Start

    var startDisabledReason: String? {
        if isBusy { return "An operation is running." }
        guard selectedDisk != nil else { return "Plug in a USB drive (or SD card)." }
        if (bootSelection == .image || bootSelection == .macInstaller) && image == nil { return "Select an image first." }
        if scanning { return "Scanning image…" }
        if let image, let disk = selectedDisk {
            let needed = writeMode == .dd ? image.size : image.projectedSize
            if image.kind != .compressedDisk && needed > disk.size && image.family != .macOS {
                return "The image is too big for the selected drive."
            }
            if let mac = image.mac, mac.minimumUSBSize > disk.size + Units.GB {
                return "macOS installers need a drive of at least \(Units.human(mac.minimumUSBSize, decimal: true))."
            }
        }
        return nil
    }

    func requestStart() {
        if let r = startDisabledReason { alert = Alert(title: "Cannot start", message: r); return }
        if image?.family == .windows && bootSelection == .image && writeMode == .iso && settings.askWindowsCustomization {
            showWindowsSheet = true
        } else {
            showConfirm = true
        }
    }

    func windowsSheetDone(proceed: Bool) {
        showWindowsSheet = false
        settings.windowsCustomization = windows
        if proceed { showConfirm = true }
    }

    func buildSpec() -> JobSpec? {
        guard let disk = selectedDisk else { return nil }
        var s = JobSpec(disk: disk.identifier, diskSize: disk.size, diskMediaName: disk.mediaName)
        s.allowVirtualDisks = disk.kind == .diskImage && settings.showDiskImages
        s.bootSelection = bootSelection
        s.imagePath = image?.path
        s.image = (bootSelection == .image || bootSelection == .macInstaller) ? image : nil
        s.writeMode = bootSelection == .macInstaller ? (image?.mac?.isLegacyRestore == true ? .asrRestore : .createInstallMedia) : writeMode
        s.partitionScheme = scheme
        s.targetSystem = target
        s.fileSystem = fileSystem
        s.clusterSize = clusterSize
        s.label = label
        s.quickFormat = quickFormat
        s.extendedLabel = extendedLabel
        s.badBlocks = badBlocksEnabled ? BadBlocksOptions(patternSet: badBlocksPattern) : nil
        s.oldBIOSFixes = oldBIOSFixes
        s.useRufusMBR = settings.useRufusMBR
        s.persistenceSize = persistenceAvailable ? UInt64(persistenceMB) * Units.MB : 0
        s.uefiMediaValidation = uefiValidation
        s.largeWIMStrategy = largeWIMStrategy
        s.verifyWrite = verifyWrite
        s.ejectWhenDone = settings.ejectWhenDone
        s.freeDOSKeyboard = freeDOSKeyboard
        s.macInstallToApplications = settings.macInstallToApplications
        if image?.family == .windows {
            var w = windows
            if w.duplicateRegionalSettings {
                let host = WindowsSetup.hostRegionalSettings()
                w.timeZone = host.timeZone
                w.inputLocale = host.inputLocale
                w.systemLocale = host.systemLocale
                w.uiLanguage = host.uiLanguage
            }
            s.windows = w.isEmpty ? nil : w
        }
        return s
    }

    /// Confirmation accepted: fetch extra files if needed, then launch the helper.
    func start() {
        guard var spec = buildSpec() else { return }
        state = .preparing
        notices = []
        progress = JobProgress(phase: "Preparing")
        jobStarted = Date()
        Task {
            // Version matched boot files (signed, from rufus.ie) for Linux ISOs in ISO mode.
            if spec.bootSelection == .image, spec.writeMode == .iso, let img = spec.image, img.family != .windows {
                if spec.targetSystem != .uefi, let v = img.syslinuxVersion, !img.syslinuxConfigs.isEmpty, !SyslinuxInstaller.isBundled(v) {
                    do {
                        spec.syslinuxFilesDir = try await SignedFiles.syslinux(version: v)
                    } catch { logWarning("Could not get Syslinux \(v) files (\(error.userMessage)); using the embedded version.") }
                }
                if spec.targetSystem != .uefi, img.hasGrub2BIOS, let v = img.grub2Version, !v.hasPrefix("2.14") {
                    spec.grubCoreImagePath = try? await SignedFiles.grubCore(version: v)
                }
            }
            if spec.bootSelection == .syslinux6 {
                // ldlinux.c32 is required by Syslinux 5+; the .sys/.bss are also embedded.
                if (try? await SignedFiles.fetch("syslinux-6.04/ldlinux.c32")) != nil {
                    spec.syslinuxFilesDir = try? await SignedFiles.syslinux(version: "6.04")
                }
            }
            launch(spec)
        }
    }

    private func launch(_ spec: JobSpec) {
        let runner = PrivilegedRunner { [weak self] event in self?.handle(event) }
        self.runner = runner
        do {
            state = .running
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Writing to USB drive")
            try runner.start(spec)
        } catch {
            endActivity()
            state = .ready
            progress = nil
            if case PrivilegedRunner.RunError.authorizationCancelled = error {
                logWarning(error.localizedDescription)
            } else {
                alert = Alert(title: "Could not start", message: error.localizedDescription)
            }
        }
    }

    func cancel() {
        guard isBusy else { return }
        logWarning("Cancelling — please wait…")
        progress?.detail = "Cancelling — please wait…"
        runner?.cancel()
    }

    private func handle(_ event: JobEvent) {
        switch event {
        case .started(let pid):
            logDebug("Helper started (pid \(pid))")
        case .log(let entry):
            appendLog(entry)
        case .progress(let p):
            progress = p
            if let f = p.overall ?? p.fraction {
                NSApp.dockTile.badgeLabel = "\(Int(f * 100))%"
            }
        case .finished(let ok, let err, let n):
            endActivity()
            NSApp.dockTile.badgeLabel = nil
            notices = n
            runner = nil
            if ok {
                state = .succeeded
                progress = JobProgress(phase: "Done", fraction: 1, overall: 1)
                NSSound(named: "Glass")?.play()
                cleanupDownloadIfNeeded()
            } else if (err ?? "").lowercased().contains("cancel") {
                state = .cancelled
                progress = nil
            } else {
                state = .failed(err ?? "Unknown error")
                progress = nil
                NSSound(named: "Basso")?.play()
            }
            NSApp.requestUserAttention(.informationalRequest)
            refreshDisks()
        }
    }

    private func endActivity() {
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        activity = nil
    }

    /// "Keep downloaded files" off: remove the image we downloaded once it has been written.
    private func cleanupDownloadIfNeeded() {
        guard !settings.keepDownloads, let path = image?.path, path.hasPrefix(settings.downloadFolder),
              DownloadMetadata.load(for: path) != nil else { return }
        downloads.delete(path)
        logInfo("Deleted downloaded file \(path) (keep downloads is off)")
        image = nil
    }

    func resetAfterJob() {
        if case .running = state { return }
        state = .ready
        progress = nil
    }

    // MARK: - Save drive image

    func saveDriveImage(format: JobSpec.SaveFormat) {
        guard let disk = selectedDisk else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(disk.mediaName.replacingOccurrences(of: " ", with: "_")).\(format.fileExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var spec = JobSpec(disk: disk.identifier, diskSize: disk.size, diskMediaName: disk.mediaName)
        spec.operation = .saveImage
        spec.saveImagePath = url.path
        spec.saveFormat = format
        spec.allowVirtualDisks = disk.kind == .diskImage
        spec.ejectWhenDone = false
        state = .preparing
        notices = []
        launch(spec)
    }

    // MARK: - Updates

    static let repository = "Hashim1999164/RufusAdvanced"

    func checkForUpdates(force: Bool = false) {
        guard settings.checkForUpdates || force else { return }
        guard force || Date().timeIntervalSince1970 - settings.lastUpdateCheck > 24 * 3600 else { return }
        Task {
            settings.lastUpdateCheck = Date().timeIntervalSince1970
            guard let json = try? await HTTP.getJSON("https://api.github.com/repos/\(Self.repository)/releases/latest") as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                if force { logInfo("Updates: unable to check for a new version") }
                return
            }
            let latest = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            if latest.compare(BootKit.version, options: .numeric) == .orderedDescending {
                updateAvailable = latest
                logNotice("A new version of RufusAdvanced is available: \(latest)")
            } else if force {
                logInfo("You are running the latest version (\(BootKit.version)).")
            }
        }
    }

    // MARK: - Status line

    var statusLine: String {
        switch state {
        case .ready: return scanning ? "Scanning image…" : "READY"
        case .preparing: return "Preparing…"
        case .running:
            guard let p = progress else { return "Working…" }
            return p.phase + (p.detail.map { " — \($0)" } ?? "")
        case .succeeded: return "Done. The drive is ready."
        case .failed(let e): return "Failed: \(e)"
        case .cancelled: return "Cancelled"
        }
    }

    var etaText: String? {
        guard state == .running, let p = progress, let rate = p.bytesPerSecond, rate > 0,
              let done = p.bytesDone, let total = p.bytesTotal, total > done else { return nil }
        return "\(Units.rate(rate)) · \(Units.duration(Double(total - done) / rate)) left"
    }

    var elapsedText: String { Units.duration(Date().timeIntervalSince(jobStarted)) }
}

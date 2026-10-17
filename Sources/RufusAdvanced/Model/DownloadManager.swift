import Foundation
import AppKit
import BootKit

/// Downloads OS images into the user's download folder, with resume and verification.
@MainActor
final class DownloadManager: ObservableObject {
    enum State: Equatable {
        case queued, downloading, paused, verifying, completed, failed(String)
        var isActive: Bool { self == .queued || self == .downloading || self == .verifying }
    }

    final class Item: ObservableObject, Identifiable {
        let id = UUID()
        let title: String
        let category: String
        let destination: String            // final file (or folder for multi-package products)
        @Published var state: State = .queued
        @Published var progress: TransferProgress?
        @Published var currentPart: String = ""
        var useWhenDone: Bool
        /// Called with the destination once the download completed (and was verified).
        var completions: [(String) -> Void] = []
        var parts: [(url: String, file: String, expected: (HashAlgorithm, String)?)]
        var metadata: DownloadMetadata
        fileprivate var task: HTTPDownload?
        fileprivate var partIndex = 0
        fileprivate var bytesBefore: UInt64 = 0
        let totalSize: UInt64?

        init(title: String, category: String, destination: String, parts: [(String, String, (HashAlgorithm, String)?)],
             metadata: DownloadMetadata, totalSize: UInt64?, useWhenDone: Bool) {
            self.title = title
            self.category = category
            self.destination = destination
            self.parts = parts.map { (url: $0.0, file: $0.1, expected: $0.2) }
            self.metadata = metadata
            self.totalSize = totalSize
            self.useWhenDone = useWhenDone
        }

        var fraction: Double? {
            guard let p = progress else { return nil }
            if let total = totalSize, total > 0, parts.count > 1 { return min(1, Double(bytesBefore + p.bytes) / Double(total)) }
            return p.fraction
        }
    }

    @Published var items: [Item] = []
    @Published var library: [(path: String, meta: DownloadMetadata)] = []
    var onUse: ((String) -> Void)?

    private let settings = AppSettings.shared

    init() { rescanLibrary() }

    func rescanLibrary() {
        let folder = settings.downloadFolder
        Task.detached {
            let found = DownloadMetadata.scan(folder: folder)
            await MainActor.run { self.library = found }
        }
    }

    /// Already downloaded and complete?
    func existing(url: String) -> String? {
        library.first { $0.meta.url == url && FileManager.default.fileExists(atPath: $0.path) }?.path
    }

    var activeCount: Int { items.filter { $0.state.isActive }.count }

    // MARK: Enqueue

    @discardableResult
    func download(url: String, fileName: String, title: String, source: DownloadMetadata.Source, category: String,
                  sha256: String? = nil, sha1: String? = nil, size: UInt64? = nil, macInstaller: MacInstallerInfo? = nil,
                  subfolder: String? = nil, useWhenDone: Bool = false, then: ((String) -> Void)? = nil) -> Item? {
        if let path = existing(url: url) {
            logInfo("Re-using previous download: \(path)")
            if useWhenDone { onUse?(path) }
            then?(path)
            return nil
        }
        if let running = items.first(where: { $0.parts.first?.url == url && ($0.state.isActive || $0.state == .paused) }) {
            running.useWhenDone = running.useWhenDone || useWhenDone
            if let then { running.completions.append(then) }
            if running.state == .paused { resume(running) }
            return running
        }
        let folder = settings.ensureDownloadFolder() + "/" + category + (subfolder.map { "/" + $0 } ?? "")
        let dest = folder + "/" + fileName
        let expected: (HashAlgorithm, String)? = settings.verifyDownloads ? (sha256.map { (.sha256, $0) } ?? sha1.map { (.sha1, $0) }) : nil
        let meta = DownloadMetadata(source: source, title: title, url: url, fileName: fileName, size: size,
                                    checksum: sha256 ?? sha1, checksumAlgorithm: sha256 != nil ? .sha256 : (sha1 != nil ? .sha1 : nil),
                                    macInstaller: macInstaller)
        let item = Item(title: title, category: category, destination: dest, parts: [(url, dest, expected)], metadata: meta,
                        totalSize: size, useWhenDone: useWhenDone)
        if let then { item.completions.append(then) }
        items.insert(item, at: 0)
        startPart(item)
        return item
    }

    /// macOS release from Apple's catalog / legacy links.
    @discardableResult
    func download(mac r: MacOSRelease, useWhenDone: Bool, then: ((String) -> Void)? = nil) -> Item? {
        let folderName = "\(r.name) \(r.version) \(r.build)".trimmingCharacters(in: .whitespaces)
        switch r.payload {
        case .installAssistant(let url, let size, let sha1):
            return download(url: url, fileName: "InstallAssistant.pkg", title: r.title, source: .apple, category: "macOS",
                            sha1: sha1, size: size, macInstaller: r.installerInfo, subfolder: folderName, useWhenDone: useWhenDone, then: then)
        case .legacyDMG(let url, let size):
            return download(url: url, fileName: (url as NSString).lastPathComponent, title: r.title, source: .appleLegacy, category: "macOS",
                            size: size, macInstaller: r.installerInfo, subfolder: folderName, useWhenDone: useWhenDone, then: then)
        case .distribution(let dist, let packages):
            let folder = settings.ensureDownloadFolder() + "/macOS/" + folderName
            if FileManager.default.fileExists(atPath: folder + "/.complete") {
                if useWhenDone { onUse?(folder) }
                then?(folder)
                return nil
            }
            var parts: [(String, String, (HashAlgorithm, String)?)] = [(dist, folder + "/" + (dist as NSString).lastPathComponent, nil)]
            for p in packages {
                let exp: (HashAlgorithm, String)? = settings.verifyDownloads ? p.sha1.map { (.sha1, $0) } : nil
                parts.append((p.url, folder + "/" + (p.url as NSString).lastPathComponent, exp))
            }
            let meta = DownloadMetadata(source: .apple, title: r.title, url: dist, fileName: folderName, size: r.totalSize,
                                        macInstaller: r.installerInfo, productID: r.id)
            let item = Item(title: r.title, category: "macOS", destination: folder, parts: parts, metadata: meta,
                            totalSize: r.totalSize, useWhenDone: useWhenDone)
            if let then { item.completions.append(then) }
            items.insert(item, at: 0)
            startPart(item)
            return item
        }
    }

    // MARK: Control

    private func startPart(_ item: Item) {
        guard item.partIndex < item.parts.count, let url = URL(string: item.parts[item.partIndex].url) else { return }
        let part = item.parts[item.partIndex]
        item.state = .downloading
        item.currentPart = (part.file as NSString).lastPathComponent
        let task = HTTPDownload(url: url, destination: part.file, expected: part.expected)
        item.task = task
        task.start(progress: { [weak item] p in
            DispatchQueue.main.async {
                item?.progress = p
                if p.phase == "Verifying" { item?.state = .verifying }
            }
        }, completion: { [weak self, weak item] result in
            DispatchQueue.main.async {
                guard let self, let item else { return }
                switch result {
                case .success(let path):
                    item.bytesBefore += (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
                    item.partIndex += 1
                    if item.partIndex < item.parts.count {
                        self.startPart(item)
                    } else {
                        self.complete(item)
                    }
                case .failure(let error):
                    if case BootKitError.cancelled = error {
                        if item.state != .failed("Cancelled") { item.state = .paused }
                    } else {
                        item.state = .failed(error.userMessage)
                        logError("Download of \(item.title) failed: \(error.userMessage)")
                    }
                }
            }
        })
    }

    private func complete(_ item: Item) {
        var meta = item.metadata
        meta.verified = item.parts.contains { $0.expected != nil }
        meta.downloadedAt = Date()
        meta.save(for: item.destination)
        if item.parts.count > 1 {
            FileManager.default.createFile(atPath: item.destination + "/.complete", contents: Data())
        }
        item.state = .completed
        logInfo("Downloaded \(item.title) → \(item.destination)\(meta.verified ? " (verified)" : "")")
        rescanLibrary()
        NSApp.requestUserAttention(.informationalRequest)
        if item.useWhenDone { onUse?(item.destination) }
        let done = item.completions
        item.completions = []
        for c in done { c(item.destination) }
    }

    func pause(_ item: Item) { item.task?.pause(); item.state = .paused }

    func resume(_ item: Item) { startPart(item) }

    func cancel(_ item: Item) {
        item.state = .failed("Cancelled")
        item.task?.cancel()
        items.removeAll { $0.id == item.id }
    }

    func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }

    func delete(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: DownloadMetadata.sidecarPath(for: path))
        rescanLibrary()
    }
}

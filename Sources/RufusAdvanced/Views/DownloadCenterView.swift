import SwiftUI
import AppKit
import BootKit

final class DownloadCenterState: ObservableObject {
    static let shared = DownloadCenterState()
    enum Tab: String, CaseIterable, Identifiable { case macOS = "macOS", windows = "Windows", linux = "Linux", custom = "From URL", library = "Downloaded"; var id: String { rawValue } }
    @Published var tab: Tab = .macOS
}

/// Download macOS / Windows / Linux from official sources, store or use them right away.
struct DownloadCenterView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var state = DownloadCenterState.shared
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $state.tab) {
                ForEach(DownloadCenterState.Tab.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(14)
            Divider()
            Group {
                switch state.tab {
                case .macOS: MacDownloadsView()
                case .windows: WindowsDownloadView()
                case .linux: LinuxDownloadView()
                case .custom: CustomURLView()
                case .library: LibraryView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ActiveDownloadsView()
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(settings.downloadFolder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Change…") { chooseFolder() }.controlSize(.small)
                Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: settings.ensureDownloadFolder())) }.controlSize(.small)
                Spacer()
                Toggle("Keep files after writing", isOn: $settings.keepDownloads).controlSize(.small)
                Toggle("Verify checksums", isOn: $settings.verifyDownloads).controlSize(.small)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.bar)
        }
        .frame(minWidth: 720, minHeight: 560)
    }

    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Use This Folder"
        if p.runModal() == .OK, let u = p.url {
            settings.downloadFolder = u.path
            model.downloads.rescanLibrary()
        }
    }
}

// MARK: - macOS

struct MacDownloadsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared
    @State private var releases: [MacOSRelease] = []
    @State private var loading = false
    @State private var error: String?
    @State private var selection: MacOSRelease.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Full macOS installers from Apple").font(.headline)
                    Text("Downloaded directly from Apple's software update servers (swcdn.apple.com / updates.cdn-apple.com).").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Include betas", isOn: $settings.includeMacBetas).onChange(of: settings.includeMacBetas) { _ in load() }
                Button { load() } label: { Image(systemName: "arrow.clockwise") }.disabled(loading)
            }
            .padding(14)
            if loading {
                ProgressView("Loading Apple's catalog…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                InfoLine(text: error, systemImage: "wifi.exclamationmark", color: .red).padding()
                Spacer()
            } else {
                Table(releases, selection: $selection) {
                    TableColumn("Release") { r in
                        HStack(spacing: 6) {
                            Image(systemName: "apple.logo").foregroundStyle(.secondary)
                            Text(r.name)
                            if r.isBeta { Chip(text: "Beta", color: .orange) }
                        }
                    }.width(min: 180)
                    TableColumn("Version") { r in Text(r.version) }.width(70)
                    TableColumn("Build") { r in Text(r.build).foregroundStyle(.secondary) }.width(70)
                    TableColumn("Date") { r in Text(r.postDate.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—").foregroundStyle(.secondary) }.width(90)
                    TableColumn("Size") { r in Text(Units.human(r.totalSize, decimal: true)) }.width(70)
                    TableColumn("") { r in
                        HStack(spacing: 6) {
                            if let path = existing(r) {
                                Button("Use") { model.selectImage(path: path) }.controlSize(.small)
                            } else {
                                Button("Download") { model.downloads.download(mac: r, useWhenDone: false) }.controlSize(.small)
                                Button("& Use") { model.downloads.download(mac: r, useWhenDone: true) }.controlSize(.small)
                                    .help("Download, then select it as the source automatically")
                            }
                        }
                    }.width(150)
                }
                .contextMenu(forSelectionType: MacOSRelease.ID.self) { ids in
                    if let id = ids.first, let r = releases.first(where: { $0.id == id }) {
                        Button("Copy download link") { copy(link(r)) }
                    }
                }
                Text("macOS 11 and later: InstallAssistant.pkg (SHA-1 verified). 10.13–10.15: package set assembled with installer. 10.7–10.12: Apple's InstallMacOSX/InstallOS images. Writing a macOS installer needs administrator rights.")
                    .font(.caption).foregroundStyle(.secondary).padding(14)
            }
        }
        .onAppear { if releases.isEmpty { load() } }
    }

    func existing(_ r: MacOSRelease) -> String? {
        switch r.payload {
        case .installAssistant(let url, _, _), .legacyDMG(let url, _): return model.downloads.existing(url: url)
        case .distribution(let dist, _): return model.downloads.existing(url: dist)
        }
    }

    func link(_ r: MacOSRelease) -> String {
        switch r.payload {
        case .installAssistant(let url, _, _), .legacyDMG(let url, _): return url
        case .distribution(let dist, _): return dist
        }
    }

    func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }

    func load() {
        loading = true
        error = nil
        Task {
            do {
                releases = try await AppleCatalog.fetchReleases(includeBetas: settings.includeMacBetas)
            } catch {
                self.error = error.userMessage
            }
            loading = false
        }
    }
}

// MARK: - Windows

struct WindowsDownloadView: View {
    @EnvironmentObject var model: AppModel
    @State private var ms = MicrosoftISO()
    @State private var products: [MicrosoftISO.Product] = []
    @State private var productIndex = 0
    @State private var releaseIndex = 0
    @State private var editionIndex = 0
    @State private var languages: [MicrosoftISO.Language] = []
    @State private var languageIndex = 0
    @State private var links: [MicrosoftISO.Link] = []
    @State private var busy = false
    @State private var error: String?

    var product: MicrosoftISO.Product? { products.indices.contains(productIndex) ? products[productIndex] : nil }
    var release: MicrosoftISO.Release? { product.flatMap { $0.releases.indices.contains(releaseIndex) ? $0.releases[releaseIndex] : nil } }
    var edition: MicrosoftISO.Edition? { release.flatMap { $0.editions.indices.contains(editionIndex) ? $0.editions[editionIndex] : nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Official Windows ISOs from Microsoft").font(.headline)
                Text("Same method as Rufus' Fido script: the links are generated by Microsoft's own download service and are valid for 24 hours.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Version").foregroundStyle(.secondary)
                    Picker("", selection: $productIndex) {
                        ForEach(products.indices, id: \.self) { i in Text(products[i].name).tag(i) }
                    }.labelsHidden().onChange(of: productIndex) { _ in releaseIndex = 0; editionIndex = 0; resetLanguages() }
                }
                GridRow {
                    Text("Release").foregroundStyle(.secondary)
                    Picker("", selection: $releaseIndex) {
                        ForEach(product?.releases.indices ?? 0..<0, id: \.self) { i in Text(product!.releases[i].name).tag(i) }
                    }.labelsHidden().onChange(of: releaseIndex) { _ in editionIndex = 0; resetLanguages() }
                }
                GridRow {
                    Text("Edition").foregroundStyle(.secondary)
                    Picker("", selection: $editionIndex) {
                        ForEach(release?.editions.indices ?? 0..<0, id: \.self) { i in Text(release!.editions[i].name).tag(i) }
                    }.labelsHidden().onChange(of: editionIndex) { _ in resetLanguages() }
                }
                GridRow {
                    Text("Language").foregroundStyle(.secondary)
                    HStack {
                        if languages.isEmpty {
                            Button("Get languages") { fetchLanguages() }.disabled(busy || edition == nil)
                        } else {
                            Picker("", selection: $languageIndex) {
                                ForEach(languages.indices, id: \.self) { i in Text(languages[i].displayName).tag(i) }
                            }.labelsHidden().onChange(of: languageIndex) { _ in links = [] }
                            Button("Get download links") { fetchLinks() }.disabled(busy)
                        }
                    }
                }
            }
            .frame(maxWidth: 520)
            if busy { ProgressView().controlSize(.small) }
            if let error { InfoLine(text: error, systemImage: "exclamationmark.triangle.fill", color: .red) }
            if !links.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(links) { l in
                        HStack {
                            Chip(text: l.arch, color: .blue)
                            Text(l.fileName).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Download") { start(l, use: false) }
                            Button("Download & Use") { start(l, use: true) }.buttonStyle(.borderedProminent)
                            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(l.url, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                                .help("Copy the download link")
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            }
            HStack {
                if let p = product, !p.isUEFIShell {
                    Link("Download using a browser instead", destination: MicrosoftISO.browserURL(for: p)).font(.caption)
                }
                Spacer()
            }
            Spacer()
        }
        .padding(16)
        .task {
            if products.isEmpty {
                products = ms.products
                await ms.refreshCatalog()
                products = ms.products
            }
        }
    }

    func resetLanguages() { languages = []; languageIndex = 0; links = []; error = nil }

    func fetchLanguages() {
        guard let p = product, let e = edition else { return }
        busy = true; error = nil
        Task {
            do {
                languages = try await ms.languages(product: p, edition: e)
                let preferred = Locale.current.language.languageCode?.identifier ?? "en"
                languageIndex = languages.firstIndex { $0.name.lowercased().hasPrefix(Locale(identifier: "en").localizedString(forLanguageCode: preferred)?.lowercased() ?? "english") }
                    ?? languages.firstIndex { $0.name == "English" } ?? 0
            } catch { self.error = error.userMessage }
            busy = false
        }
    }

    func fetchLinks() {
        guard let p = product, let r = release, let e = edition, languages.indices.contains(languageIndex) else { return }
        busy = true; error = nil
        Task {
            do { links = try await ms.links(product: p, release: r, edition: e, language: languages[languageIndex]) }
            catch { self.error = error.userMessage }
            busy = false
        }
    }

    func start(_ l: MicrosoftISO.Link, use: Bool) {
        let title = "\(product?.name ?? "Windows") \(release?.name.split(separator: " ").first ?? "") \(l.arch) (\(languages.indices.contains(languageIndex) ? languages[languageIndex].name : ""))"
        model.downloads.download(url: l.url, fileName: l.fileName, title: title, source: product?.isUEFIShell == true ? .uefiShell : .microsoft,
                                 category: "Windows", useWhenDone: use)
    }
}

// MARK: - Linux

struct LinuxDownloadView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedDistro: String? = LinuxCatalog.distros.first?.id
    @State private var images: [String: [LinuxImage]] = [:]
    @State private var loading: Set<String> = []
    @State private var errors: [String: String] = [:]

    var distro: LinuxDistro? { LinuxCatalog.distros.first { $0.id == selectedDistro } }

    var body: some View {
        HStack(spacing: 0) {
            List(LinuxCatalog.distros, selection: $selectedDistro) { d in
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.name)
                    Text(d.summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }.tag(d.id)
            }
            .frame(width: 230)
            Divider()
            if let d = distro {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(d.name).font(.title3.weight(.semibold))
                                Text(d.summary).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Link("Website", destination: URL(string: d.homepage)!).font(.callout)
                        }
                        ForEach(d.editions) { e in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(e.name).font(.headline)
                                    Chip(text: e.arch, color: .gray)
                                    Spacer()
                                    if loading.contains(e.id) { ProgressView().controlSize(.small) }
                                }
                                if let err = errors[e.id] { InfoLine(text: err, systemImage: "exclamationmark.triangle", color: .red) }
                                ForEach(images[e.id] ?? []) { img in
                                    HStack {
                                        Text(img.title).font(.callout)
                                        if img.sha256 != nil { Image(systemName: "checkmark.shield").foregroundStyle(.green).help("SHA-256 verified download") }
                                        Spacer()
                                        if let path = model.downloads.existing(url: img.url) {
                                            Button("Use") { model.selectImage(path: path) }.controlSize(.small)
                                        } else {
                                            Button("Download") { start(img, d, use: false) }.controlSize(.small)
                                            Button("Download & Use") { start(img, d, use: true) }.controlSize(.small).buttonStyle(.borderedProminent)
                                        }
                                    }
                                }
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                            .task { await resolve(e) }
                        }
                        if d.supportsPersistence {
                            InfoLine(text: "Supports persistence: choose a persistent partition size in the main window (ISO mode).", systemImage: "externaldrive.badge.plus")
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    func resolve(_ e: LinuxEdition) async {
        guard images[e.id] == nil, !loading.contains(e.id) else { return }
        loading.insert(e.id)
        do { images[e.id] = try await LinuxCatalog.resolve(e) }
        catch { errors[e.id] = error.userMessage }
        loading.remove(e.id)
    }

    func start(_ img: LinuxImage, _ d: LinuxDistro, use: Bool) {
        model.downloads.download(url: img.url, fileName: img.fileName, title: img.title, source: .linux, category: "Linux",
                                 sha256: img.sha256, size: img.size, useWhenDone: use)
    }
}

// MARK: - Custom URL

struct CustomURLView: View {
    @EnvironmentObject var model: AppModel
    @State private var url = ""
    @State private var sha = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download any image from a direct link").font(.headline)
            TextField("https://example.org/image.iso", text: $url).textFieldStyle(.roundedBorder)
            TextField("Expected SHA-256 (optional, recommended)", text: $sha).textFieldStyle(.roundedBorder)
            HStack {
                Button("Download") { start(false) }.disabled(URL(string: url)?.scheme?.hasPrefix("http") != true)
                Button("Download & Use") { start(true) }.buttonStyle(.borderedProminent).disabled(URL(string: url)?.scheme?.hasPrefix("http") != true)
            }
            InfoLine(text: "Only HTTPS/HTTP links to the file itself are supported. Downloads resume automatically if interrupted.")
            Spacer()
        }
        .padding(16)
    }

    func start(_ use: Bool) {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespaces)) else { return }
        let name = u.lastPathComponent.isEmpty ? "download.iso" : u.lastPathComponent
        let hash = sha.trimmingCharacters(in: .whitespaces).lowercased()
        model.downloads.download(url: u.absoluteString, fileName: name, title: name, source: .custom, category: "Other",
                                 sha256: hash.count == 64 ? hash : nil, useWhenDone: use)
    }
}

// MARK: - Library

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if model.downloads.library.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(.secondary)
                Text("No downloads yet").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.downloads.library, id: \.path) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.meta.title)
                            if entry.meta.verified { Image(systemName: "checkmark.shield.fill").foregroundStyle(.green).help("Checksum verified") }
                        }
                        Text("\(entry.meta.source.rawValue) · \(entry.meta.downloadedAt.formatted(date: .abbreviated, time: .shortened)) · \(entry.path)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Use") { model.selectImage(path: entry.path) }
                    Button { model.downloads.reveal(entry.path) } label: { Image(systemName: "magnifyingglass") }.help("Show in Finder")
                    Button(role: .destructive) { model.downloads.delete(entry.path) } label: { Image(systemName: "trash") }.help("Delete")
                }
            }
        }
    }
}

// MARK: - Active downloads

struct ActiveDownloadsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { DownloadsList(downloads: model.downloads) }
}

struct DownloadsList: View {
    @ObservedObject var downloads: DownloadManager
    var body: some View {
        if !downloads.items.isEmpty {
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(downloads.items) { item in DownloadRow(item: item, downloads: downloads) }
                }.padding(12)
            }
            .frame(maxHeight: 180)
            Divider()
        }
    }
}

struct DownloadRow: View {
    @ObservedObject var item: DownloadManager.Item
    let downloads: DownloadManager

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(item.title).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer()
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                if item.state.isActive || item.state == .paused {
                    ProgressView(value: item.fraction ?? 0).progressViewStyle(.linear)
                }
            }
            switch item.state {
            case .downloading, .queued:
                Button { downloads.pause(item) } label: { Image(systemName: "pause.fill") }.buttonStyle(.borderless).help("Pause")
            case .paused, .failed:
                Button { downloads.resume(item) } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Resume")
            case .completed:
                Button { downloads.onUse?(item.destination) } label: { Text("Use") }.controlSize(.small)
                Button { downloads.reveal(item.destination) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless)
            default: EmptyView()
            }
            if item.state != .completed {
                Button { downloads.cancel(item) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Cancel and delete partial data")
            }
        }
    }

    var icon: String {
        switch item.state {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .paused: return "pause.circle"
        case .verifying: return "checkmark.shield"
        default: return "arrow.down.circle"
        }
    }
    var color: Color {
        switch item.state {
        case .completed: return .green
        case .failed: return .red
        default: return .accentColor
        }
    }
    var detail: String {
        switch item.state {
        case .failed(let e): return e
        case .completed: return "Done"
        case .paused: return "Paused"
        case .verifying: return "Verifying…"
        default:
            guard let p = item.progress else { return "Starting…" }
            var s = Units.human(p.bytes)
            if let t = p.total { s += " of \(Units.human(t))" }
            if p.bytesPerSecond > 0 { s += " · \(Units.rate(p.bytesPerSecond))" }
            if let eta = p.eta { s += " · \(Units.duration(eta)) left" }
            if item.parts.count > 1 { s += " · \(item.currentPart)" }
            return s
        }
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BootKit

// MARK: - Log

/// Shared rendering for the log window and the inline log pane.
struct LogLines: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared
    var filter: String = ""
    var maxLines: Int = 5_000
    var fontSize: CGFloat = 11.5

    var entries: [LogEntry] {
        var list = model.log
        if !settings.verboseLog { list = list.filter { $0.level != .debug } }
        if !filter.isEmpty { list = list.filter { $0.message.localizedCaseInsensitiveContains(filter) } }
        return Array(list.suffix(maxLines))
    }

    var body: some View {
        let shown = entries
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(shown) { e in
                        Text(e.formatted)
                            .font(.system(size: fontSize, design: .monospaced))
                            .foregroundStyle(LogLines.color(e.level))
                            .lineLimit(nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(e.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.log.count) { _ in
                if let last = shown.last { proxy.scrollTo(last.id, anchor: .bottomLeading) }
            }
            .onChange(of: settings.verboseLog) { _ in
                if let last = shown.last { proxy.scrollTo(last.id, anchor: .bottomLeading) }
            }
            .onAppear {
                if let last = shown.last { proxy.scrollTo(last.id, anchor: .bottomLeading) }
            }
        }
    }

    static func color(_ l: LogLevel) -> Color {
        switch l {
        case .error: return .red
        case .warning: return .orange
        case .notice: return .accentColor
        case .debug: return .secondary
        case .info: return .primary
        }
    }
}

/// Copy / Save / Reveal buttons shared by both log views.
struct LogButtons: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button("Copy") { model.copyLog() }
            .help("Copy the whole log (including verbose lines) to the clipboard")
        Button("Save…") { model.saveLog() }
            .help("Save the whole log (including verbose lines) to a file")
        Button { model.revealLogFile() } label: { Image(systemName: "folder") }
            .help("Show the log file in ~/Library/Logs/RufusAdvanced")
    }
}

struct LogView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Toggle("Verbose log", isOn: $settings.verboseLog)
                    .help("Show every detailed step: devices, diskutil/authopen commands and exit codes, errno values, progress and helper output")
                Spacer()
                LogButtons()
                Button("Clear") { model.log.removeAll() }
            }.padding(10)
            Divider()
            LogLines(filter: filter, maxLines: 20_000)
        }
        .frame(minWidth: 640, minHeight: 380)
    }
}

/// Collapsible live log at the bottom of the main window.
struct LogPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { settings.showLogPane.toggle() }
                } label: {
                    Label("Log", systemImage: settings.showLogPane ? "chevron.down" : "chevron.right")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.borderless)
                .help(settings.showLogPane ? "Hide the log" : "Show the log")
                Toggle("Verbose", isOn: $settings.verboseLog)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Show every detailed step: devices, diskutil/authopen commands and exit codes, errno values, progress and helper output")
                Spacer()
                if settings.showLogPane {
                    LogButtons()
                        .controlSize(.small)
                    Button { openWindow(id: "log") } label: { Image(systemName: "macwindow") }
                        .controlSize(.small)
                        .help("Open the log in its own window")
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
            if settings.showLogPane {
                LogLines(maxLines: 3_000, fontSize: 11)
                    .frame(minHeight: 120, idealHeight: 180, maxHeight: 260)
                    .background(Color(nsColor: .textBackgroundColor))
            }
        }
    }
}

/// Shown when the app runs from a location where macOS won't let it get drive access.
struct LocationBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let p = AppLocation.bundlePath {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            DownloadSettings().tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            ToolsSettings().tabItem { Label("Optional tools", systemImage: "hammer") }
        }
        .frame(width: 560, height: 430)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Drives") {
                Toggle("List USB hard drives (use at your own risk)", isOn: $settings.listUSBHardDrives)
                Toggle("Show attached disk images as targets", isOn: $settings.showDiskImages)
                Toggle("Eject the drive when finished", isOn: $settings.ejectWhenDone)
            }
            Section("Behaviour") {
                Toggle("Show advanced drive properties (also unlocks Syslinux, GRUB, UEFI:NTFS)", isOn: $settings.showAdvancedDrive)
                Toggle("Show advanced format options", isOn: $settings.showAdvancedFormat)
                Toggle("Use Rufus MBR for BIOS boot", isOn: $settings.useRufusMBR)
                Toggle("Ask for Windows customization when writing Windows", isOn: $settings.askWindowsCustomization)
                Toggle("Keep macOS installer apps in /Applications", isOn: $settings.macInstallToApplications)
            }
            Section("Updates") {
                Toggle("Check for updates automatically (GitHub releases)", isOn: $settings.checkForUpdates)
                Button("Check now") { model.checkForUpdates(force: true) }
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.listUSBHardDrives) { _ in model.refreshDisks() }
        .onChange(of: settings.showDiskImages) { _ in model.refreshDisks() }
    }
}

struct DownloadSettings: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Storage") {
                LabeledContent("Download folder") {
                    HStack {
                        Text(settings.downloadFolder).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Change…") {
                            let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                            if p.runModal() == .OK, let u = p.url { settings.downloadFolder = u.path; model.downloads.rescanLibrary() }
                        }
                    }
                }
                Toggle("Keep downloaded files after a successful write", isOn: $settings.keepDownloads)
                Toggle("Verify checksums (SHA-256 / Apple SHA-1)", isOn: $settings.verifyDownloads)
            }
            Section("macOS") {
                Toggle("Include beta releases from Apple's seed catalog", isOn: $settings.includeMacBetas)
            }
            Section {
                Text("Previously downloaded images are detected automatically and re-used instead of being downloaded again. Interrupted downloads resume where they stopped.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ToolsSettings: View {
    @State private var refresh = 0

    var body: some View {
        Form {
            Section {
                Text("Everything works out of the box. These optional open source tools unlock extra features; install them with Homebrew (https://brew.sh).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Tools") {
                ForEach(ExternalTool.allCases, id: \.self) { tool in
                    HStack(alignment: .top) {
                        Image(systemName: tool.isAvailable ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(tool.isAvailable ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tool.rawValue).font(.callout.weight(.medium))
                            Text(tool.purpose).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !tool.isAvailable {
                            Button("Copy install command") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("brew install \(tool.brewFormula)", forType: .string)
                            }.controlSize(.small)
                        }
                    }
                }
            }
            Button("Re-check") { refresh += 1 }
        }
        .formStyle(.grouped)
        .id(refresh)
    }
}

// MARK: - About

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("RufusAdvanced").font(.title.weight(.semibold))
            Text("Version \(BootKit.version)").foregroundStyle(.secondary)
            Text("Create bootable USB drives for macOS, Windows and Linux on your Mac.").multilineTextAlignment(.center)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Credits").font(.headline)
                    Text("• Inspired by and partially derived from Rufus by Pete Batard (GPLv3) — https://rufus.ie. RufusAdvanced is an independent project and is not affiliated with or endorsed by the Rufus project.")
                    Text("• Boot records from ms-sys (GPLv2+). Syslinux by H. Peter Anvin et al. (GPLv2+). GRUB 2 (GPLv3+). FreeDOS (GPLv2).")
                    Text("• UEFI:NTFS by Pete Batard (GPLv2+), with ntfs-3g and EfiFs drivers. uefi-md5sum by Pete Batard (GPLv2+).")
                    Text("• Windows ISO download method from Fido by Pete Batard (GPLv3).")
                    Text("• NTFS support: embedded ntfs-3g library and mkntfs by Tuxera and contributors (GPLv2+).")
                    Text("• Optional: wimlib (GPLv3/LGPLv3), e2fsprogs, zstd, xz, 7-Zip, QEMU.")
                    Text("License: GNU General Public License v3.0").padding(.top, 4)
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Link("GitHub", destination: URL(string: "https://github.com/\(AppModel.repository)")!)
                Link("Report an issue", destination: URL(string: "https://github.com/\(AppModel.repository)/issues")!)
            }
        }
        .padding(24)
        .frame(width: 460, height: 460)
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BootKit

// MARK: - Log

struct LogView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared
    @State private var filter = ""

    var entries: [LogEntry] {
        filter.isEmpty ? model.log : model.log.filter { $0.message.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                Toggle("Debug messages", isOn: $settings.verboseLog).onChange(of: settings.verboseLog) { v in Log.shared.verbose = v }
                Spacer()
                Button("Copy") { copy() }
                Button("Save…") { save() }
                Button("Clear") { model.log.removeAll() }
            }.padding(10)
            Divider()
            ScrollViewReader { proxy in
                List(entries) { e in
                    Text(e.formatted)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(color(e.level))
                        .textSelection(.enabled)
                        .id(e.id)
                        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                }
                .onChange(of: model.log.count) { _ in
                    if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 380)
    }

    func color(_ l: LogLevel) -> Color {
        switch l {
        case .error: return .red
        case .warning: return .orange
        case .notice: return .accentColor
        case .debug: return .secondary
        case .info: return .primary
        }
    }

    var text: String { model.log.map(\.formatted).joined(separator: "\n") }

    func copy() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }

    func save() {
        let p = NSSavePanel()
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        p.nameFieldStringValue = "rufusadvanced-\(f.string(from: Date())).log"
        p.allowedContentTypes = [.plainText, .log]
        if p.runModal() == .OK, let u = p.url { try? text.write(to: u, atomically: true, encoding: .utf8) }
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
                ForEach(ExternalTool.allCases.filter { $0 != .ntfs3g }, id: \.self) { tool in
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
                    Text("• Optional: wimlib (GPLv3/LGPLv3), ntfs-3g, e2fsprogs, zstd, xz, 7-Zip, QEMU.")
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

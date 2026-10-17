import SwiftUI
import BootKit

// MARK: - Assistant sheet

/// "macOS installer assistant": installers on this Mac, the running download/install, and tips.
struct MacInstallerAssistantSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var assistant: MacInstallerAssistant
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 22, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.gray.gradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text("macOS installer assistant").font(.title3.weight(.semibold))
                    Text("Download from Apple, install into Applications, verify, use — in one click.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if assistant.phase != .idle || assistant.watchingInstallerApp {
                MacInstallerProgressPanel(assistant: assistant)
            }
            InstalledMacInstallersList(assistant: assistant, compact: false)
            MacInstallerTips()
            HStack {
                Button {
                    DownloadCenterState.shared.tab = .macOS
                    openWindow(id: "downloads")
                } label: { Label("Get another version…", systemImage: "arrow.down.circle") }
                Spacer()
                if assistant.phase.isBusy {
                    Button("Cancel", role: .cancel) { assistant.cancel() }
                }
                Button("Close") { assistant.showSheet = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { assistant.refresh() }
    }
}

/// Presents the assistant sheet (observes the assistant, which AppModel only owns).
struct MacAssistantSheetHost: View {
    @ObservedObject var assistant: MacInstallerAssistant
    var body: some View {
        Color.clear.sheet(isPresented: $assistant.showSheet) { MacInstallerAssistantSheet(assistant: assistant) }
    }
}

// MARK: - Progress

/// Steps of the running operation: Download → Install → Verify → Ready.
struct MacInstallerProgressPanel: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var assistant: MacInstallerAssistant

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(assistant.title).font(.headline).lineLimit(1)
            if assistant.watchingInstallerApp {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Apple's Installer to finish — the installer app is picked up automatically when it appears in Applications.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Button("Stop waiting") { assistant.stopWatching() }.controlSize(.small)
            } else {
                HStack(spacing: 0) {
                    step("Download", index: 0)
                    connector
                    step("Install", index: 1)
                    connector
                    step("Verify", index: 2)
                    connector
                    step("Ready", index: 3)
                }
                switch assistant.phase {
                case .failed(let m):
                    InfoLine(text: m, systemImage: "xmark.octagon.fill", color: .red)
                    Button("Dismiss") { assistant.reset() }.controlSize(.small)
                case .done(let app):
                    ForEach(assistant.checks) { c in CheckRow(check: c) }
                    HStack {
                        InfoLine(text: "Ready: \((app as NSString).lastPathComponent) is selected as the source. Pick your USB drive and click Start.",
                                 systemImage: "checkmark.seal.fill", color: .green)
                        Spacer()
                        Button("Show in Finder") { assistant.reveal(app) }.controlSize(.small)
                    }
                    if let size = assistant.sourcePackageSize {
                        HStack {
                            Text("The downloaded package is no longer needed.").font(.caption).foregroundStyle(.secondary)
                            Button("Delete \((assistant.sourcePackage.map { ($0 as NSString).lastPathComponent }) ?? "package") (\(Units.human(size, decimal: true)))") {
                                assistant.deleteSourcePackage()
                            }
                            .controlSize(.small)
                        }
                    }
                default:
                    if let p = assistant.progress {
                        VStack(alignment: .leading, spacing: 4) {
                            if let f = p.fraction { ProgressView(value: f) } else { ProgressView().progressViewStyle(.linear) }
                            HStack {
                                Text(p.phase).font(.caption.weight(.medium))
                                if let d = p.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                                Spacer()
                                if let bps = p.bytesPerSecond, bps > 0 { Text(Units.human(UInt64(bps), decimal: true) + "/s").font(.caption).foregroundStyle(.secondary) }
                                if let f = p.fraction { Text("\(Int(f * 100))%").font(.caption.monospacedDigit()) }
                            }
                        }
                    }
                    if assistant.phase == .authorizing {
                        InfoLine(text: "Enter your administrator password to let macOS install the package into Applications.", systemImage: "lock.fill")
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }

    var current: Int {
        switch assistant.phase {
        case .idle, .downloading: return 0
        case .authorizing, .installing: return 1
        case .verifying: return 2
        case .done: return 4
        case .failed: return -1
        }
    }

    var connector: some View {
        Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1).frame(maxWidth: .infinity)
    }

    func step(_ name: String, index: Int) -> some View {
        let done = current > index
        let active = current == index
        return HStack(spacing: 4) {
            ZStack {
                Circle().fill(done ? Color.green : (active ? Color.accentColor : Color.secondary.opacity(0.25))).frame(width: 18, height: 18)
                if done { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
                else { Text("\(index + 1)").font(.system(size: 9, weight: .bold)).foregroundStyle(active ? .white : .secondary) }
            }
            Text(name).font(.caption.weight(active ? .semibold : .regular)).foregroundStyle(active || done ? .primary : .secondary)
        }
        .fixedSize()
    }
}

struct CheckRow: View {
    let check: MacInstallerLibrary.Check
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: check.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(check.ok ? .green : .orange)
            Text(check.title).font(.caption.weight(.medium))
            Text(check.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
    }
}

// MARK: - Installers on this Mac

struct InstalledMacInstallersList: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var assistant: MacInstallerAssistant
    var compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Installers on this Mac").font(.subheadline.weight(.semibold))
                if assistant.scanning { ProgressView().controlSize(.mini) }
                Spacer()
                Button { assistant.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Look for installers in Applications again")
                    .disabled(assistant.scanning)
            }
            if assistant.installed.isEmpty {
                Text(assistant.scanning ? "Looking in Applications…" : "No “Install macOS” app in Applications yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(assistant.installed) { f in
                HStack(spacing: 10) {
                    Image(systemName: f.isUsable ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(f.isUsable ? .green : .orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(f.info?.displayName ?? (f.path as NSString).lastPathComponent).font(.callout.weight(.medium))
                        Text(f.isUsable ? "\(f.info?.build.map { "Build \($0) · " } ?? "")verified · \(f.path)" : (f.problem ?? ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if !compact { Button { assistant.reveal(f.path) } label: { Image(systemName: "folder") }.buttonStyle(.borderless).help("Show in Finder") }
                    Button("Use") { assistant.use(f) }.controlSize(.small).disabled(f.info == nil || model.isBusy)
                }
            }
        }
    }
}

// MARK: - Tips

struct MacInstallerTips: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tips").font(.subheadline.weight(.semibold))
            InfoLine(text: "“Get Installer” downloads Apple's InstallAssistant.pkg (SHA-1 checked), installs it into Applications with your password, checks Apple's signatures and the payload, then selects it — nothing else to do.", systemImage: "1.circle")
            InfoLine(text: "Already opened the .pkg yourself? Let Apple's Installer finish; the new “Install macOS” app shows up here automatically.", systemImage: "2.circle")
            InfoLine(text: "The installer app takes 13–18 GB. Keep it to make more USB drives later, or drag it to the Trash when you're done.", systemImage: "3.circle")
            InfoLine(text: "macOS installers need a USB drive of at least 16 GB (8 GB for 10.15 and older). The drive is erased as Mac OS Extended, GUID.", systemImage: "4.circle")
        }
    }
}

// MARK: - Tip in the main window for a selected .pkg

struct MacPackageTip: View {
    @EnvironmentObject var model: AppModel
    let image: ImageReport

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 6) {
                Text("Tip: install this package into Applications once — it's verified, reusable for more drives, and every later write is faster.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Install to Applications") {
                        model.macInstallers.install(package: image.path, title: image.displayName)
                    }
                    .disabled(model.macInstallers.phase.isBusy || model.isBusy)
                    Button("Open in Installer") { model.macInstallers.openInInstaller(image.path) }
                        .help("Install it with Apple's Installer; RufusAdvanced picks the result up automatically")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.08)))
    }
}

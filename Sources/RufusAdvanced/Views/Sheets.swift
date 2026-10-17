import SwiftUI
import AppKit
import BootKit

// MARK: - Windows User Experience

struct WindowsCustomizationSheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared
    @State private var userName = ""
    @State private var useLocalAccount = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "squareshape.split.2x2").font(.system(size: 26)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Customize Windows installation?").font(.title3.weight(.semibold))
                    Text(model.image?.displayName ?? "").font(.callout).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    option("Remove requirement for 4GB+ RAM, Secure Boot and TPM 2.0", $model.windows.bypassRequirements,
                           "Only bypasses setup's checks — Windows still uses all the hardware available.")
                    option("Remove requirement for an online Microsoft account", $model.windows.noOnlineAccount,
                           "For this to work, network/Internet must be disconnected during installation (or create a local account below).")
                    HStack(alignment: .firstTextBaseline) {
                        Toggle("Create a local account with username:", isOn: $useLocalAccount)
                        TextField("username", text: $userName).textFieldStyle(.roundedBorder).frame(width: 160).disabled(!useLocalAccount)
                    }
                    Text("The account gets an empty password that must be changed at first logon.").font(.caption).foregroundStyle(.secondary).padding(.leading, 20)
                    option("Set regional options to the same values as this Mac's", $model.windows.duplicateRegionalSettings,
                           "Keyboard, time zone (\(TimeZone.current.identifier)) and language are copied instead of prompting.")
                    option("Disable data collection (Skip privacy questions)", $model.windows.disableDataCollection,
                           "Automatically answer 'no' to the setup questions about sharing data with Microsoft.")
                    option("Disable BitLocker automatic device encryption", $model.windows.disableBitLocker,
                           "Don't encrypt the system disk unless explicitly requested.")
                    option("QoL improvements (Don't force Copilot, OneDrive, Outlook, Fast Startup, etc.)", $model.windows.qualityOfLife,
                           "Removes OneDrive/Outlook/Teams auto install, disables Copilot, ads and Fast Startup, restores the classic context menu.")
                    option("Apply SkuSiPolicy.p7b on installation (See KB5042562)", $model.windows.applySkuSiPolicy,
                           "Applies Microsoft's Secure Boot revocation policy at first logon.")
                    option("Use 'Windows CA 2023' signed bootloaders (Requires a compatible target PC)", $model.windows.useCA2023Bootloaders,
                           ExternalTool.wimlib.isAvailable ? "The target PC must have the Windows UEFI CA 2023 certificate installed." : "Needs wimlib (brew install wimlib).")
                    option("Restrict Windows to S-Mode (INCOMPATIBLE with online account bypass)", $model.windows.forceSMode,
                           "Your system may stay locked into S-Mode even after a full reinstall.")
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        option("⚠ SILENTLY ⚠ erase disk and install:", $model.windows.silentInstall,
                               "Fully unattended: the first internal disk of the target PC is WIPED without any confirmation. Requires the exFAT/NTFS + UEFI:NTFS layout.")
                        if model.windows.silentInstall, let wim = model.image?.wim, !wim.images.isEmpty {
                            Picker("Edition", selection: $model.windows.editionIndex) {
                                ForEach(wim.images) { img in Text("\(img.index). \(img.title)").tag(img.index) }
                            }.frame(maxWidth: 360).padding(.leading, 20)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 360)
            Toggle("Ask every time a Windows image is written", isOn: $settings.askWindowsCustomization).font(.callout)
            HStack {
                Spacer()
                Button("Cancel") { model.windowsSheetDone(proceed: false) }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    model.windows.localAccountName = useLocalAccount && !userName.isEmpty ? userName : nil
                    if model.windows.forceSMode { model.windows.noOnlineAccount = false }
                    model.windowsSheetDone(proceed: !model.isBusy && model.state != .running)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear {
            userName = model.windows.localAccountName ?? NSUserName()
            useLocalAccount = model.windows.localAccountName != nil
        }
    }

    func option(_ title: String, _ binding: Binding<Bool>, _ help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: binding)
            Text(help).font(.caption).foregroundStyle(.secondary).padding(.leading, 20).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Confirmation

struct ConfirmSheet: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 32)).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("All data on this drive will be destroyed").font(.title3.weight(.semibold))
                    Text(model.selectedDisk?.displayName ?? "").font(.callout.weight(.medium))
                    Text(model.selectedDisk?.subtitle ?? "").font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(summary, id: \.0) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.0).foregroundStyle(.secondary).frame(width: 120, alignment: .trailing)
                        Text(row.1).fixedSize(horizontal: false, vertical: true)
                    }.font(.callout)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            if let d = model.selectedDisk, !d.partitions.isEmpty {
                Text("Volumes that will be erased: " + d.partitions.map { ($0.volumeName ?? $0.identifier) + " (\(Units.human($0.size)))" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("You will be asked for your password: writing to a drive requires administrator rights.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.showConfirm = false }.keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    model.showConfirm = false
                    model.start()
                } label: { Text("Erase and Write").fontWeight(.semibold) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    var summary: [(String, String)] {
        var rows: [(String, String)] = []
        switch model.bootSelection {
        case .image, .macInstaller:
            if let img = model.image {
                rows.append(("Image", img.displayName.isEmpty ? img.fileName : img.displayName))
                if model.bootSelection == .macInstaller {
                    rows.append(("Method", img.mac?.isLegacyRestore == true ? "Apple Software Restore" : "createinstallmedia (GUID, Mac OS Extended)"))
                } else {
                    rows.append(("Write mode", model.writeMode.rawValue))
                }
            }
        default:
            rows.append(("Boot selection", model.bootSelection.rawValue))
        }
        if !model.layoutLocked {
            rows.append(("Layout", "\(model.scheme.rawValue) · \(model.target.rawValue)"))
            rows.append(("File system", "\(model.fileSystem.rawValue)\(model.label.isEmpty ? "" : " · \"\(model.label)\"")"))
        }
        if model.persistenceAvailable && model.persistenceMB > 0 {
            rows.append(("Persistence", Units.human(UInt64(model.persistenceMB) * Units.MB)))
        }
        if model.image?.family == .windows && model.writeMode == .iso && !model.windows.isEmpty {
            rows.append(("Windows", "Customized (see Windows setup)"))
        }
        if model.badBlocksEnabled { rows.append(("Bad blocks", model.badBlocksPattern.rawValue + " (slow)")) }
        if !model.quickFormat && !model.layoutLocked { rows.append(("Format", "Slow (zero fill)")) }
        if model.verifyWrite && model.writeMode == .dd { rows.append(("Verify", "Read back and compare")) }
        return rows
    }
}

// MARK: - Checksums

struct HashSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var hashes: [HashAlgorithm: String] = [:]
    @State private var progress: Double = 0
    @State private var running = false
    @State private var expected = ""
    @State private var cancel = CancellationToken()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Image checksums").font(.title3.weight(.semibold))
            Text(model.image?.fileName ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if running {
                ProgressView(value: progress) { Text("Computing…").font(.caption) }
            }
            ForEach(HashAlgorithm.allCases) { alg in
                HStack(alignment: .firstTextBaseline) {
                    Text(alg.rawValue).frame(width: 70, alignment: .trailing).foregroundStyle(.secondary)
                    Text(hashes[alg] ?? "—").font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2)
                    Spacer()
                    if let h = hashes[alg] {
                        if !expected.isEmpty && h.lowercased() == expected.lowercased().trimmingCharacters(in: .whitespaces) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        }
                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(h, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copy")
                    }
                }
            }
            TextField("Paste an expected checksum to compare", text: $expected).textFieldStyle(.roundedBorder)
            if !expected.isEmpty && !hashes.isEmpty {
                let match = hashes.values.contains { $0.lowercased() == expected.lowercased().trimmingCharacters(in: .whitespaces) }
                InfoLine(text: match ? "Checksum matches." : "No checksum matches the expected value!",
                         systemImage: match ? "checkmark.circle.fill" : "xmark.octagon.fill", color: match ? .green : .red)
            }
            HStack {
                Spacer()
                Button("Close") { cancel.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(22)
        .frame(width: 600)
        .onAppear(perform: compute)
    }

    func compute() {
        guard let path = model.image?.path else { return }
        running = true
        let token = cancel
        Task.detached {
            let result = try? MultiHasher.hashFile(at: path, cancel: token) { f in
                Task { @MainActor in progress = f }
            }
            await MainActor.run {
                running = false
                hashes = result ?? [:]
                if let r = result { for (k, v) in r.sorted(by: { $0.key.rawValue < $1.key.rawValue }) { logInfo("\(k.rawValue): \(v)") } }
            }
        }
    }
}

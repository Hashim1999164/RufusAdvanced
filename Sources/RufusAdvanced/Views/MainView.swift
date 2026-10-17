import SwiftUI
import UniformTypeIdentifiers
import BootKit

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if let v = model.updateAvailable {
                UpdateBanner(version: v)
            }
            if let w = AppLocation.warning {
                LocationBanner(message: w)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DriveSection()
                    BootSection()
                    if !model.layoutLocked {
                        PropertiesSection()
                        FormatSection()
                    } else {
                        LockedLayoutNote()
                    }
                }
                .padding(18)
                .disabled(model.isBusy)
            }
            Divider()
            LogPane()
            Divider()
            StatusBar()
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 640, idealHeight: 820)
        .overlay(dropOverlay)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { DispatchQueue.main.async { model.selectImage(path: url.path) } }
            }
            return true
        }
        .toolbar { toolbar }
        .sheet(isPresented: $model.showWindowsSheet) { WindowsCustomizationSheet() }
        .sheet(isPresented: $model.showConfirm) { ConfirmSheet() }
        .sheet(isPresented: $model.showHash) { HashSheet() }
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
    }

    @ViewBuilder var dropOverlay: some View {
        if dropTargeted {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                .background(Color.accentColor.opacity(0.06))
                .overlay(Label("Drop the image to use it", systemImage: "arrow.down.doc").font(.title2.weight(.semibold)))
                .padding(8)
                .allowsHitTesting(false)
        }
    }

    @ToolbarContentBuilder var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { openWindow(id: "downloads") } label: { Label("Download Center", systemImage: "arrow.down.circle") }
                .help("Download macOS, Windows and Linux directly from their official servers")
            Button { model.showHash = true } label: { Label("Checksums", systemImage: "number.square") }
                .disabled(model.image == nil || model.image?.kind == .macInstallerApp)
                .help("Compute MD5 / SHA-1 / SHA-256 / SHA-512 of the selected image")
            Menu {
                ForEach(JobSpec.SaveFormat.allCases) { f in
                    Button(f.rawValue) { model.saveDriveImage(format: f) }
                }
            } label: { Label("Save drive image", systemImage: "square.and.arrow.down.on.square") }
                .disabled(model.selectedDisk == nil || model.isBusy)
                .help("Create a disk image (backup) of the selected drive")
            Button { openWindow(id: "log") } label: { Label("Log", systemImage: "doc.text.magnifyingglass") }
                .help("Show the log")
        }
    }
}

// MARK: - Drive

struct DriveSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Card(title: "Drive", systemImage: "externaldrive", trailing: AnyView(
            Button { model.refreshDisks() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh the device list")
        )) {
            if model.disks.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "mediastick").font(.system(size: 26)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No USB drive detected").font(.headline)
                        Text("Plug in a USB flash drive or memory card. \(settings.listUSBHardDrives ? "" : "USB hard drives are hidden (see Advanced drive properties).")")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: model.selectedDisk?.kind.symbol ?? "mediastick")
                        .font(.system(size: 24)).foregroundStyle(Color.accentColor).frame(width: 32)
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $model.selectedDiskID) {
                            ForEach(model.disks) { d in Text(d.displayName).tag(Optional(d.id)) }
                        }
                        .labelsHidden()
                        if let d = model.selectedDisk {
                            Text(d.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let d = model.selectedDisk, d.kind == .usbHardDrive || d.size > 128 * Units.GB {
                    InfoLine(text: "This is a large drive (\(Units.human(d.size, decimal: true))). Make sure it is the one you want to erase.",
                             systemImage: "exclamationmark.triangle.fill", color: .orange)
                }
            }
        }
    }
}

// MARK: - Boot selection

struct BootSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Card(title: "Boot selection", systemImage: "opticaldisc") {
            HStack(spacing: 8) {
                Picker("", selection: $model.bootSelection) {
                    ForEach(model.availableBootSelections) { b in Text(b.rawValue).tag(b) }
                    if model.bootSelection == .macInstaller { Text(BootSelection.macInstaller.rawValue).tag(BootSelection.macInstaller) }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
                .help("Method that will be used to make the drive bootable")
                Button("Select…") { model.chooseImage() }
                    .disabled(model.bootSelection != .image && model.bootSelection != .macInstaller)
                    .help("Select an ISO, disk image or macOS installer")
                DownloadMenu()
                Spacer(minLength: 0)
            }

            if model.bootSelection == .image || model.bootSelection == .macInstaller {
                if model.scanning {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Scanning image…").foregroundStyle(.secondary) }
                } else if let image = model.image {
                    ImageSummary(image: image)
                    ImageOptions(image: image)
                } else {
                    DropHint()
                }
            } else if model.bootSelection == .freeDOS {
                FormRow(label: "Keyboard") {
                    Picker("", selection: $model.freeDOSKeyboard) {
                        ForEach(FormatWriter.keyboards, id: \.code) { k in Text(k.name).tag(k.code) }
                    }.labelsHidden().frame(maxWidth: 220)
                }
            } else if model.bootSelection == .uefiNTFS {
                InfoLine(text: "Creates an NTFS/exFAT data partition plus the UEFI:NTFS boot partition, so UEFI PCs can boot files you copy onto it.")
            } else if model.bootSelection == .nonBootable {
                InfoLine(text: "Formats the drive for storing files.")
            }
            ForEach(model.recommendationNotes, id: \.self) { n in InfoLine(text: n, systemImage: "lightbulb", color: .secondary) }
        }
    }
}

struct DropHint: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Button { model.chooseImage() } label: {
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.doc").font(.system(size: 26)).foregroundStyle(Color.accentColor)
                Text("Drop an ISO, IMG, DMG or macOS installer here").font(.callout.weight(.medium))
                Text("or click to browse — or use Download to fetch one").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.2, dash: [6])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct DownloadMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            Button { openWindow(id: "downloads"); DownloadCenterState.shared.tab = .macOS } label: { Label("macOS…", systemImage: "apple.logo") }
            Button { openWindow(id: "downloads"); DownloadCenterState.shared.tab = .windows } label: { Label("Windows…", systemImage: "squareshape.split.2x2") }
            Button { openWindow(id: "downloads"); DownloadCenterState.shared.tab = .linux } label: { Label("Linux…", systemImage: "terminal") }
            Button { openWindow(id: "downloads"); DownloadCenterState.shared.tab = .custom } label: { Label("From URL…", systemImage: "link") }
            if !model.downloads.library.isEmpty {
                Divider()
                Section("Downloaded") {
                    ForEach(model.downloads.library.prefix(10), id: \.path) { entry in
                        Button(entry.meta.title) { model.selectImage(path: entry.path) }
                    }
                }
            }
        } label: {
            Label("Download", systemImage: "arrow.down.circle")
        }
        .fixedSize()
        .help("Download an operating system image")
    }
}

struct ImageSummary: View {
    @EnvironmentObject var model: AppModel
    let image: ImageReport

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: image.symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 9).fill(image.tint.gradient))
            VStack(alignment: .leading, spacing: 5) {
                Text(image.displayName.isEmpty ? image.fileName : image.displayName)
                    .font(.headline).lineLimit(2)
                Text(image.fileName).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                FlowLayout {
                    Chip(text: Units.human(image.size), color: .secondary)
                    if image.isHybrid { Chip(text: "ISOHybrid", color: .purple) }
                    if image.hasElToritoBIOS || image.hasBootmgr || !image.syslinuxConfigs.isEmpty { Chip(text: "BIOS", color: .brown) }
                    if image.hasEFI { Chip(text: "UEFI", color: .green) }
                    if let v = image.syslinuxVersion, !image.syslinuxConfigs.isEmpty { Chip(text: "Syslinux \(v)", color: .gray) }
                    if image.hasGrub2BIOS { Chip(text: "GRUB\(image.grub2Version.map { " " + $0 } ?? "")", color: .gray) }
                    if image.supportsPersistence { Chip(text: "Persistence", color: .teal) }
                    if image.has4GBFile { Chip(text: ">4 GB file", color: .orange) }
                    if let wim = image.wim, wim.images.count > 1 { Chip(text: "\(wim.images.count) editions", color: .blue) }
                    if image.compression != .none { Chip(text: image.compression.rawValue, color: .gray) }
                    if let mac = image.mac { Chip(text: mac.hasCreateInstallMedia ? "createinstallmedia" : "asr restore", color: .gray) }
                }
                ForEach(image.warnings, id: \.self) { w in InfoLine(text: w, systemImage: "exclamationmark.triangle.fill", color: .orange) }
            }
            Spacer(minLength: 0)
            Button { model.clearImage() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless).help("Clear the selected image")
        }
    }
}

struct ImageOptions: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared
    let image: ImageReport

    var body: some View {
        if image.family == .windows {
            FormRow(label: "Image option", help: "Install Windows to another disk, or run it from this drive") {
                Picker("", selection: .constant(0)) {
                    Text("Standard Windows installation").tag(0)
                    Text("Windows To Go (not available on macOS)").tag(1)
                }.labelsHidden().frame(maxWidth: 300)
            }
            if model.writeMode == .iso {
                FormRow(label: "Windows setup") {
                    HStack {
                        Text(customizationSummary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        Button("Customize…") { model.showWindowsSheet = true }
                    }
                }
                if image.has4GBFile {
                    FormRow(label: "Large install.wim", help: "install.wim is bigger than 4 GB, the FAT32 file size limit") {
                        Picker("", selection: $model.largeWIMStrategy) {
                            ForEach(LargeWIMStrategy.allCases) { s in Text(s.rawValue).tag(s) }
                        }
                        .labelsHidden()
                        .onChange(of: model.largeWIMStrategy) { s in
                            switch s {
                            case .splitWIM: model.fileSystem = .fat32
                            case .exfatUEFINTFS: model.fileSystem = .exfat
                            case .ntfsUEFINTFS: model.fileSystem = .ntfs
                            }
                        }
                    }
                    if model.largeWIMStrategy == .splitWIM && !ExternalTool.wimlib.isAvailable {
                        InfoLine(text: "Splitting needs wimlib: run 'brew install wimlib' in Terminal, then try again.", systemImage: "exclamationmark.triangle.fill", color: .orange)
                    }
                }
            }
        }
        if image.family != .macOS && model.canUseISOMode && model.canUseDDMode {
            FormRow(label: "Write mode", help: "ISO mode extracts the files to a new file system (allows persistence and customization). DD mode copies the image sector by sector.") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $model.writeMode) {
                        Text("ISO Image mode").tag(WriteMode.iso)
                        Text("DD Image mode").tag(WriteMode.dd)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
                    Text(image.recommendedWriteMode == .dd ? "DD mode is recommended for this ISOHybrid image." : "ISO mode is recommended for this image.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if model.persistenceAvailable {
            FormRow(label: "Persistence", help: "Size of the partition that keeps your changes across reboots of the live system") {
                VStack(alignment: .leading, spacing: 2) {
                    let step = 256.0
                    let upper = (model.maxPersistenceMB / step).rounded(.down) * step
                    if upper >= step {
                        Slider(value: $model.persistenceMB, in: 0...upper, step: step)
                        Text(model.persistenceMB < 1 ? "No persistence" : "\(Units.human(UInt64(model.persistenceMB) * Units.MB)) persistent partition")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(model.selectedDisk == nil ? "Select a drive to set a persistent partition size" : "Not enough free space on the drive for persistence")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        if let mac = image.mac {
            FormRow(label: "Installer") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mac.isLegacyRestore ? "Restored with Apple Software Restore (asr)" : "Created with Apple's createinstallmedia")
                        .font(.callout)
                    Text("Needs a drive of at least \(Units.human(mac.minimumUSBSize, decimal: true)). The drive is erased as Mac OS Extended (Journaled), GUID.")
                        .font(.caption).foregroundStyle(.secondary)
                    if image.kind == .macInstallerPackage {
                        Toggle("Also install the installer app in /Applications", isOn: $settings.macInstallToApplications)
                            .font(.callout)
                    }
                    if mac.requiresRosetta {
                        InfoLine(text: "This older installer needs Rosetta 2 on Apple silicon.", systemImage: "exclamationmark.triangle.fill", color: .orange)
                    }
                }
            }
        }
    }

    var customizationSummary: String {
        let w = model.windows
        var parts: [String] = []
        if w.bypassRequirements { parts.append("No TPM/Secure Boot/RAM checks") }
        if w.noOnlineAccount { parts.append("No Microsoft account") }
        if let u = w.localAccountName, !u.isEmpty { parts.append("Local user '\(u)'") }
        if w.disableDataCollection { parts.append("No data collection") }
        if w.disableBitLocker { parts.append("No BitLocker") }
        if w.duplicateRegionalSettings { parts.append("Mac's regional settings") }
        if w.qualityOfLife { parts.append("QoL tweaks") }
        if w.useCA2023Bootloaders { parts.append("CA 2023 boot loaders") }
        if w.silentInstall { parts.append("⚠ Silent install") }
        return parts.isEmpty ? "Standard (no customization)" : parts.joined(separator: " · ")
    }
}

// MARK: - Drive properties

struct PropertiesSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Card(title: "Drive properties", systemImage: "slider.horizontal.3") {
            FormRow(label: "Partition scheme", help: "Method that will be used to create partitions") {
                Picker("", selection: $model.scheme) {
                    ForEach(model.availableSchemes) { s in Text(s.rawValue).tag(s) }
                }.labelsHidden().frame(maxWidth: 200)
            }
            FormRow(label: "Target system", help: "Type of computer you plan to use this bootable drive with. 'UEFI-CSM' means legacy BIOS emulation; 'non CSM' means native UEFI only.") {
                Picker("", selection: $model.target) {
                    ForEach(model.availableTargets) { t in Text(t.rawValue).tag(t) }
                }.labelsHidden().frame(maxWidth: 200)
            }
            DisclosureGroup(isExpanded: $settings.showAdvancedDrive) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("List USB Hard Drives", isOn: $settings.listUSBHardDrives)
                        .help("Enable the listing of USB hard drive enclosures. Use at your own risk!")
                        .onChange(of: settings.listUSBHardDrives) { _ in model.refreshDisks() }
                    Toggle("Show disk images as targets", isOn: $settings.showDiskImages)
                        .help("List attached disk images (e.g. created with Disk Utility) so you can write to an image file")
                        .onChange(of: settings.showDiskImages) { _ in model.refreshDisks() }
                    Toggle("Add fixes for old BIOSes (extra partition, align, etc.)", isOn: $model.oldBIOSFixes)
                        .disabled(model.scheme != .mbr)
                        .help("Create an extra hidden partition and try to align partition boundaries. This can improve boot detection for older BIOSes.")
                    Toggle("Use Rufus MBR", isOn: $settings.useRufusMBR)
                        .disabled(model.scheme != .mbr)
                        .help("Use Rufus' master boot record (it can boot the internal disk if USB boot fails) instead of the Windows 7 one")
                    Toggle("Enable runtime UEFI media validation", isOn: $model.uefiValidation)
                        .disabled(!(model.image?.hasEFI ?? false) || model.writeMode == .dd)
                        .help("Install a UEFI bootloader that validates the MD5 checksums of all files before booting")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
                .padding(.leading, 4)
            } label: {
                Text("Advanced drive properties").font(.callout.weight(.medium))
            }
        }
    }
}

// MARK: - Format options

struct FormatSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Card(title: "Format options", systemImage: "internaldrive") {
            FormRow(label: "Volume label", help: "Name of the drive. FAT labels are limited to 11 uppercase characters.") {
                TextField("Label", text: $model.label).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
            }
            if !model.availableFileSystems.isEmpty {
                FormRow(label: "File system", help: "Sets the target file system") {
                    HStack(spacing: 12) {
                        Picker("", selection: $model.fileSystem) {
                            ForEach(model.availableFileSystems) { f in Text(f.rawValue).tag(f) }
                        }.labelsHidden().frame(maxWidth: 200)
                        Picker("Cluster size", selection: $model.clusterSize) {
                            ForEach(Array(model.availableClusterSizes.enumerated()), id: \.offset) { i, c in
                                Text(i == 0 ? "\(clusterName(c)) (Default)" : clusterName(c)).tag(i == 0 ? UInt32(0) : c)
                            }
                        }
                        .frame(maxWidth: 220)
                        .help("Minimum size that a block of data will occupy in the file system")
                    }
                }
            }
            DisclosureGroup(isExpanded: $settings.showAdvancedFormat) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Quick format", isOn: $model.quickFormat)
                        .help("Uncheck this box to use the \"slow\" format method (zeroes the partition first)")
                    Toggle("Create extended label and icon files", isOn: $model.extendedLabel)
                        .help("Create autorun.inf / autorun.ico so Windows shows a nice label and icon")
                    HStack {
                        Toggle("Check device for bad blocks", isOn: $model.badBlocksEnabled)
                            .help("Check the device for bad blocks using a test pattern (destructive, slow). Also detects fake capacity drives.")
                        Picker("", selection: $model.badBlocksPattern) {
                            ForEach(BadBlocksOptions.PatternSet.allCases) { p in Text(p.rawValue).tag(p) }
                        }.labelsHidden().frame(maxWidth: 190).disabled(!model.badBlocksEnabled)
                    }
                    Toggle("Verify after writing (DD mode)", isOn: $model.verifyWrite)
                        .disabled(model.writeMode != .dd || model.bootSelection != .image)
                        .help("Read the whole drive back and compare it with the image")
                    Toggle("Eject the drive when finished", isOn: $settings.ejectWhenDone)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
                .padding(.leading, 4)
            } label: {
                Text("Advanced format options").font(.callout.weight(.medium))
            }
        }
    }

    func clusterName(_ c: UInt32) -> String {
        c >= 1024 ? "\(c / 1024) KB" : "\(c) bytes"
    }
}

struct LockedLayoutNote: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Card(title: "Drive layout", systemImage: "lock") {
            if model.bootSelection == .macInstaller {
                InfoLine(text: "macOS installers always use a GUID partition map with a Mac OS Extended (Journaled) volume.")
            } else {
                InfoLine(text: "In DD mode the image is copied sector by sector: its own partition layout and file systems are used.")
            }
            Toggle("Verify after writing", isOn: $model.verifyWrite)
                .disabled(model.writeMode != .dd)
            Toggle("Check device for bad blocks first", isOn: $model.badBlocksEnabled)
        }
    }
}

// MARK: - Status bar

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: progressValue)
                .progressViewStyle(.linear)
                .tint(tint)
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: statusSymbol).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.statusLine).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if let eta = model.etaText { Text(eta).font(.caption).foregroundStyle(.secondary) }
                    else if !model.extraNotices.isEmpty, model.state == .succeeded {
                        Text(model.extraNotices.joined(separator: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                if model.state == .succeeded, !model.finishedMountPoints.isEmpty {
                    Button("Show in Finder") { model.showDriveInFinder() }
                        .controlSize(.large)
                        .help("Open \(model.finishedMountPoints.joined(separator: ", ")) in Finder")
                }
                if model.isBusy {
                    Button(role: .cancel) { model.cancel() } label: { Text("Cancel").frame(minWidth: 70) }
                        .controlSize(.large)
                } else {
                    Button { model.requestStart() } label: {
                        Text("START").fontWeight(.semibold).frame(minWidth: 90)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.startDisabledReason != nil)
                    .help(model.startDisabledReason ?? "Start the operation. This will DESTROY all data on the selected drive!")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    var progressValue: Double {
        switch model.state {
        case .succeeded: return 1
        case .running, .preparing: return model.progress?.overall ?? model.progress?.fraction ?? 0
        default: return 0
        }
    }

    var tint: Color {
        switch model.state {
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .orange
        default: return .accentColor
        }
    }

    var statusSymbol: String {
        switch model.state {
        case .ready: return "checkmark.circle"
        case .preparing, .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.seal.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle"
        }
    }
}

struct UpdateBanner: View {
    let version: String
    var body: some View {
        HStack {
            Image(systemName: "sparkles")
            Text("RufusAdvanced \(version) is available.")
            Spacer()
            Link("Download", destination: URL(string: "https://github.com/\(AppModel.repository)/releases/latest")!)
        }
        .font(.callout)
        .padding(.horizontal, 18).padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12))
    }
}

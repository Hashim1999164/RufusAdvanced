import SwiftUI
import AppKit
import BootKit

/// Simple mode: a guided, animated flow — choose a system, choose the USB drive, create, done.
/// Everything technical is decided automatically (the same recommendations Advanced mode starts from).
struct SimpleFlowView: View {
    @EnvironmentObject var model: AppModel

    enum Step: Int { case source, target, working, done }

    var step: Step {
        switch model.state {
        case .running, .preparing: return .working
        case .succeeded, .failed, .cancelled: return .done
        case .ready: return model.image == nil ? .source : .target
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SimpleHeader(step: step)
                .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 12)
            ZStack {
                switch step {
                case .source: SimpleSourceStep(assistant: model.macInstallers, downloads: model.downloads).transition(stepTransition)
                case .target: SimpleTargetStep().transition(stepTransition)
                case .working: SimpleProgressStep().transition(stepTransition)
                case .done: SimpleDoneStep().transition(stepTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.spring(response: 0.45, dampingFraction: 0.86), value: step)
        }
        .frame(minWidth: 540, idealWidth: 560, maxWidth: 680, minHeight: 540, idealHeight: 620, maxHeight: 760)
    }

    var stepTransition: AnyTransition {
        .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity))
    }
}

/// ScrollView, except while rendering developer snapshots (ImageRenderer can't draw scroll views).
struct SimpleScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if ProcessInfo.processInfo.environment["RUFUSADV_SNAPSHOT"] != nil {
            VStack { content; Spacer(minLength: 0) }
        } else {
            ScrollView { content }
        }
    }
}

// MARK: - Header with step dots

struct SimpleHeader: View {
    let step: SimpleFlowView.Step
    private let titles = ["System", "USB drive", "Create"]

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text("RufusAdvanced").font(.title3.weight(.semibold))
                Text("Bootable USB drives for macOS, Windows and Linux").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    let active = min(step.rawValue, 2) == i
                    let done = step.rawValue > i || step == .done
                    HStack(spacing: 4) {
                        ZStack {
                            Circle().fill(done ? Color.green : (active ? Color.accentColor : Color.secondary.opacity(0.2)))
                                .frame(width: 18, height: 18)
                            if done {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                            } else {
                                Text("\(i + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(active ? .white : .secondary)
                            }
                        }
                        if active && step != .done {
                            Text(titles[i]).font(.caption.weight(.semibold)).transition(.opacity.combined(with: .scale(scale: 0.85)))
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.24), value: step)
        }
    }
}

// MARK: - Logo

/// OS logo: fetched/installer icon when available, otherwise a tinted symbol tile.
struct OSLogoView: View {
    @ObservedObject var logos = LogoProvider.shared
    let key: String?
    var symbol: String = "opticaldisc"
    var tint: Color = .accentColor
    var size: CGFloat = 64

    var body: some View {
        Group {
            if let key, let img = logos.image(key) {
                if key.hasPrefix("/") {
                    Image(nsImage: img).resizable().scaledToFit()
                } else {
                    Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                        .padding(size * 0.14)
                        .frame(width: size, height: size)
                        .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(Color.black.opacity(0.08)))
                        .shadow(color: .black.opacity(0.12), radius: size * 0.08, y: size * 0.03)
                }
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(tint.gradient))
                    .shadow(color: tint.opacity(0.35), radius: size * 0.1, y: size * 0.04)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Step 1: choose a system

struct SimpleSourceStep: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var assistant: MacInstallerAssistant
    @ObservedObject var downloads: DownloadManager
    @Environment(\.openWindow) private var openWindow
    @State private var bob = false
    @State private var hovering: String?

    var body: some View {
        SimpleScroll {
            VStack(alignment: .leading, spacing: 22) {
                if model.scanning {
                    HStack(spacing: 14) {
                        ProgressView().controlSize(.large)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Analyzing…").font(.headline)
                            Text("Detecting the system and the best settings").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 170)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
                    .transition(.opacity)
                } else {
                    dropZone
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Or download a system").font(.headline)
                    HStack(spacing: 12) {
                        downloadTile("macos", title: "macOS", subtitle: "From Apple", symbol: "apple.logo", tint: .gray, tab: .macOS)
                        downloadTile("windows11", title: "Windows", subtitle: "From Microsoft", symbol: "squareshape.split.2x2", tint: .blue, tab: .windows)
                        downloadTile("linux", title: "Linux", subtitle: "Ubuntu, Mint, Fedora…", symbol: "terminal", tint: .orange, tab: .linux)
                    }
                }

                if !readyItems.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Ready on this Mac").font(.headline)
                        ForEach(readyItems, id: \.path) { item in
                            Button { model.selectImage(path: item.path) } label: {
                                HStack(spacing: 12) {
                                    OSLogoView(key: item.logo, symbol: item.symbol, tint: item.tint, size: 36)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.title).font(.callout.weight(.medium)).foregroundStyle(.primary)
                                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.easeInOut(duration: 0.24), value: readyItems.map(\.path))
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 24)
        }
        .animation(.easeInOut(duration: 0.24), value: model.scanning)
        .onAppear { assistant.refresh() }
    }

    var dropZone: some View {
        Button { model.chooseImage() } label: {
            VStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 46, weight: .regular))
                    .foregroundStyle(Color.accentColor.gradient)
                    .offset(y: bob ? -4 : 3)
                    .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: bob)
                Text("Drop a system here").font(.title3.weight(.semibold))
                Text("ISO, DMG, IMG or a macOS installer — or click to choose a file").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 170)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.accentColor.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.accentColor.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onAppear { bob = true }
    }

    func downloadTile(_ logo: String, title: String, subtitle: String, symbol: String, tint: Color, tab: DownloadCenterState.Tab) -> some View {
        Button {
            DownloadCenterState.shared.tab = tab
            openWindow(id: "downloads")
        } label: {
            VStack(spacing: 8) {
                OSLogoView(key: logo, symbol: symbol, tint: tint, size: 52)
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hovering == title ? tint.opacity(0.6) : Color.primary.opacity(0.06), lineWidth: 1.2))
            .scaleEffect(hovering == title ? 1.03 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h ? title : (hovering == title ? nil : hovering) } }
    }

    struct ReadyItem { var path, title, subtitle, symbol: String; var logo: String?; var tint: Color }

    var readyItems: [ReadyItem] {
        var out: [ReadyItem] = []
        for f in assistant.installed where f.isUsable {
            out.append(ReadyItem(path: f.path, title: f.info?.displayName ?? (f.path as NSString).lastPathComponent,
                                 subtitle: "Installer in Applications · verified", symbol: "apple.logo", logo: f.path, tint: .gray))
        }
        for entry in downloads.library.prefix(4) where !out.contains(where: { $0.path == entry.path }) {
            let lower = entry.meta.title.lowercased()
            let isMac = entry.meta.macInstaller != nil
            let logo: String? = isMac ? LogoProvider.macOSKey(entry.meta.title)
                : (lower.contains("windows") ? (lower.contains("10") ? "windows10" : "windows11") : (LogoProvider.linuxKey(lower) ?? "linux"))
            out.append(ReadyItem(path: entry.path, title: entry.meta.title, subtitle: "Downloaded · \((entry.path as NSString).lastPathComponent)",
                                 symbol: isMac ? "apple.logo" : "opticaldisc", logo: logo, tint: isMac ? .gray : .blue))
        }
        return out
    }
}

// MARK: - Step 2: choose the drive

struct SimpleTargetStep: View {
    @EnvironmentObject var model: AppModel
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            SimpleScroll {
                VStack(alignment: .leading, spacing: 22) {
                    if let image = model.image { systemCard(image) }
                    driveList
                    if let image = model.image, image.family == .windows, model.writeMode == .iso {
                        windowsOptions
                    }
                    ForEach(model.recommendationNotes, id: \.self) { n in
                        Label(n, systemImage: "lightbulb").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 16)
            }
            bottomBar
        }
        .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.05)) { appeared = true } }
    }

    func systemCard(_ image: ImageReport) -> some View {
        HStack(spacing: 16) {
            OSLogoView(key: LogoProvider.key(for: image), symbol: image.symbol, tint: image.tint, size: 84)
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)
            VStack(alignment: .leading, spacing: 4) {
                Text(image.displayName.isEmpty ? image.fileName : image.displayName)
                    .font(.title3.weight(.semibold)).lineLimit(2)
                Text("\(image.fileName) · \(Units.human(image.size))").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                FlowLayout {
                    if image.hasEFI || image.mac != nil { Chip(text: "UEFI", color: .green) }
                    if image.hasElToritoBIOS || image.hasBootmgr || !image.syslinuxConfigs.isEmpty { Chip(text: "BIOS", color: .brown) }
                    Chip(text: model.bootSelection == .macInstaller ? "Mac OS Extended" : model.fileSystem.shortName, color: .secondary)
                    if image.supportsPersistence { Chip(text: "Live", color: .teal) }
                }
                ForEach(image.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
            Button { withAnimation { model.clearImage() } } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Choose another system")
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .controlBackgroundColor)))
    }

    var driveList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Choose the USB drive").font(.headline)
                Spacer()
                Button { model.refreshDisks() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Refresh")
            }
            if model.disks.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "mediastick").font(.system(size: 28)).foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                        .opacity(appeared ? 1 : 0.35)
                        .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: appeared)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Plug in a USB drive").font(.callout.weight(.semibold))
                        Text("It appears here automatically. Everything on it will be erased.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            }
            ForEach(model.disks) { d in
                let selected = model.selectedDiskID == d.id
                Button { withAnimation(.easeInOut(duration: 0.2)) { model.selectedDiskID = d.id } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: d.kind.symbol).font(.system(size: 22)).foregroundStyle(selected ? Color.accentColor : .secondary).frame(width: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.displayName).font(.callout.weight(.medium)).foregroundStyle(.primary)
                            Text(d.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title3).foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Color.accentColor.opacity(0.09) : Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor.opacity(0.7) : .clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .animation(.easeInOut(duration: 0.24), value: model.disks.map(\.id))
    }

    var windowsOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Windows setup").font(.headline)
            Toggle("Remove the TPM, Secure Boot and RAM requirements", isOn: $model.windows.bypassRequirements)
            Toggle("Allow setup without a Microsoft account", isOn: $model.windows.noOnlineAccount)
            if model.image?.has4GBFile == true {
                Picker("File system", selection: $model.largeWIMStrategy) {
                    ForEach(LargeWIMStrategy.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .onChange(of: model.largeWIMStrategy) { s in
                    switch s {
                    case .splitWIM: model.fileSystem = .fat32
                    case .exfatUEFINTFS: model.fileSystem = .exfat
                    case .ntfsUEFINTFS: model.fileSystem = .ntfs
                    }
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }

    var bottomBar: some View {
        VStack(spacing: 6) {
            Divider()
            HStack {
                Button("Back") { withAnimation { model.clearImage() } }
                Spacer()
                if let r = model.startDisabledReason {
                    Text(r).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Button { model.requestStart(skipCustomization: true) } label: {
                    Label("Create USB", systemImage: "bolt.fill").font(.body.weight(.semibold)).padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.startDisabledReason != nil)
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
        }
        .background(.bar)
    }
}

// MARK: - Step 3: progress

struct SimpleProgressStep: View {
    @EnvironmentObject var model: AppModel
    @State private var spin = false
    @State private var pulse = false
    @State private var phases: [String] = []

    var fraction: Double { model.progress?.overall ?? model.progress?.fraction ?? 0 }

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 8)
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 10).frame(width: 190, height: 190)
                Circle()
                    .trim(from: 0, to: max(0.02, fraction))
                    .stroke(AngularGradient(colors: [.accentColor.opacity(0.4), .accentColor, .purple], center: .center),
                            style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 190, height: 190)
                    .animation(.easeInOut(duration: 0.4), value: fraction)
                Circle()
                    .trim(from: 0, to: 0.12)
                    .stroke(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 214, height: 214)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 2.2).repeatForever(autoreverses: false), value: spin)
                VStack(spacing: 6) {
                    if let image = model.image {
                        OSLogoView(key: LogoProvider.key(for: image), symbol: image.symbol, tint: image.tint, size: 70)
                            .scaleEffect(pulse ? 1.04 : 0.97)
                            .animation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true), value: pulse)
                    }
                    Text("\(Int(fraction * 100))%").font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.3), value: Int(fraction * 100))
                }
            }
            VStack(spacing: 4) {
                Text(model.progress?.phase ?? "Preparing…").font(.title3.weight(.semibold))
                    .contentTransition(.opacity)
                if let d = model.progress?.detail {
                    Text(d).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                if let eta = model.etaText {
                    Text(eta).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 30)
            .animation(.easeInOut(duration: 0.24), value: model.progress?.phase)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(phases.enumerated()), id: \.element) { i, p in
                    let current = i == phases.count - 1
                    HStack(spacing: 8) {
                        if current { ProgressView().controlSize(.small).frame(width: 16) }
                        else { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 16) }
                        Text(p).font(.callout.weight(current ? .semibold : .regular)).foregroundStyle(current ? .primary : .secondary)
                    }
                    .scaleEffect(current ? 1 : 0.98, anchor: .leading)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .frame(maxWidth: 320, alignment: .leading)
            .animation(.easeInOut(duration: 0.24), value: phases)

            Spacer()
            Button(role: .cancel) { model.cancel() } label: { Text("Cancel").padding(.horizontal, 10) }
                .controlSize(.large)
                .padding(.bottom, 20)
        }
        .onAppear { spin = true; pulse = true; note(model.progress?.phase) }
        .onChange(of: model.progress?.phase) { p in note(p) }
    }

    func note(_ phase: String?) {
        guard let p = phase, !p.isEmpty, phases.last != p, !p.hasPrefix("Waiting") else { return }
        phases.removeAll { $0 == p }
        phases.append(p)
        if phases.count > 6 { phases.removeFirst(phases.count - 6) }
    }
}

// MARK: - Step 4: done

struct SimpleDoneStep: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var drawn = false

    var success: Bool { model.state == .succeeded }

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle().fill((success ? Color.green : (model.state == .cancelled ? Color.orange : Color.red)).opacity(0.13))
                    .frame(width: 150, height: 150)
                    .scaleEffect(drawn ? 1 : 0.5)
                Circle().trim(from: 0, to: drawn ? 1 : 0)
                    .stroke(success ? Color.green : (model.state == .cancelled ? Color.orange : Color.red), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 120, height: 120)
                Image(systemName: success ? "checkmark" : (model.state == .cancelled ? "stop.fill" : "xmark"))
                    .font(.system(size: 50, weight: .bold))
                    .foregroundStyle(success ? Color.green : (model.state == .cancelled ? Color.orange : Color.red))
                    .scaleEffect(drawn ? 1 : 0.2)
                    .opacity(drawn ? 1 : 0)
            }
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
                .lineLimit(6)
            ForEach(model.extraNotices, id: \.self) { n in
                Label(n, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 40)
            }
            HStack(spacing: 10) {
                if success && !model.finishedMountPoints.isEmpty {
                    Button { model.showDriveInFinder() } label: { Label("Show in Finder", systemImage: "folder") }
                    Button { model.ejectFinishedDrive() } label: { Label("Eject", systemImage: "eject") }
                }
                if !success {
                    Button { openWindow(id: "log") } label: { Label("Show Log", systemImage: "doc.text.magnifyingglass") }
                }
                Button {
                    withAnimation {
                        model.resetAfterJob()
                        if success { model.clearImage() }
                    }
                } label: { Text(success ? "Make another" : "Try again").fontWeight(.semibold) }
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
            .padding(.top, 6)
            Spacer()
        }
        .onAppear { withAnimation(.spring(response: 0.6, dampingFraction: 0.6).delay(0.1)) { drawn = true } }
    }

    var title: String {
        switch model.state {
        case .succeeded: return "Your USB drive is ready"
        case .cancelled: return "Cancelled"
        default: return "Something went wrong"
        }
    }

    var subtitle: String {
        switch model.state {
        case .succeeded:
            if model.driveEjected { return "The drive was ejected. You can unplug it and boot from it." }
            if let mp = model.finishedMountPoints.first { return "It's mounted at \(mp). Eject it before unplugging, then boot from it." }
            return "You can now boot from it."
        case .failed(let e): return e
        case .cancelled: return "Nothing more was written. Write the drive again before using it."
        default: return ""
        }
    }
}

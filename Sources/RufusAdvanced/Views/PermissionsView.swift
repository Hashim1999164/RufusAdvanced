import SwiftUI
import BootKit

/// The permission check: what RufusAdvanced needs from macOS, what is missing, and the fix.
struct PermissionsSheet: View {
    @ObservedObject var manager: PermissionManager
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: manager.problems.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 34)).foregroundStyle(manager.problems.isEmpty ? Color.green : Color.orange)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 2) {
                    Text(manager.problems.isEmpty ? "Ready to go" : "A few permissions need your attention").font(.title3.weight(.semibold))
                    Text("RufusAdvanced checks what it needs from macOS every time it starts. This list updates when you come back from System Settings.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(manager.items) { item in PermissionRow(item: item, manager: manager) }
                }
            }
            .frame(maxHeight: 380)
            HStack {
                Toggle("Check at every launch", isOn: $settings.showPermissionsAtLaunch).controlSize(.small)
                Spacer()
                Button("Check again") { withAnimation { manager.refresh() } }
                Button("Done") { manager.showSheet = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .animation(.easeInOut(duration: 0.24), value: manager.items)
    }
}

struct PermissionRow: View {
    let item: PermissionManager.Item
    let manager: PermissionManager

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.symbol).font(.title3).foregroundStyle(tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title).font(.callout.weight(.semibold))
                    Chip(text: label, color: tint)
                }
                Text(item.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !item.actions.isEmpty {
                    HStack {
                        ForEach(Array(item.actions.enumerated()), id: \.offset) { _, a in
                            Button(title(a)) { manager.perform(a) }.controlSize(.small)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(item.status == .missing ? Color.orange.opacity(0.5) : Color.primary.opacity(0.06)))
    }

    var tint: Color {
        switch item.status {
        case .ok: return .green
        case .missing: return .orange
        case .recommended: return .blue
        case .unknown: return .secondary
        }
    }

    var label: String {
        switch item.status {
        case .ok: return "OK"
        case .missing: return "Needed"
        case .recommended: return "Recommended"
        case .unknown: return "Not checked"
        }
    }

    func title(_ a: PermissionManager.Item.Action) -> String {
        switch a {
        case .openURL(_, let t): return t
        case .revealApp: return "Show in Finder"
        case .requestDownloads: return "Allow access"
        case .copy(_, let t): return t
        }
    }
}

/// Thin banner in the main window while something is missing.
struct PermissionBanner: View {
    @ObservedObject var manager: PermissionManager

    var body: some View {
        if !manager.problems.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
                Text(manager.problems.count == 1 ? "\(manager.problems[0].title) — needs your attention."
                                                 : "\(manager.problems.count) permissions need your attention.")
                    .font(.callout)
                Spacer(minLength: 0)
                Button("Review") { manager.showSheet = true }.controlSize(.small)
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(Color.orange.opacity(0.12))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Presents the sheet (observes the manager, which AppModel owns).
struct PermissionsSheetHost: View {
    @ObservedObject var manager: PermissionManager
    var body: some View {
        Color.clear.sheet(isPresented: $manager.showSheet) { PermissionsSheet(manager: manager) }
    }
}

/// Toolbar shortcut to the permission check (orange while something is missing).
struct PermissionsToolbarButton: View {
    @ObservedObject var manager: PermissionManager
    var body: some View {
        Button { manager.refresh(); manager.showSheet = true } label: {
            Label("Permissions", systemImage: manager.problems.isEmpty ? "checkmark.shield" : "exclamationmark.shield.fill")
        }
        .foregroundStyle(manager.problems.isEmpty ? Color.secondary : Color.orange)
        .help(manager.problems.isEmpty ? "Permissions: everything needed is in place" : "Some permissions need your attention")
    }
}

import SwiftUI
import AppKit
import BootKit

@main
struct RufusAdvancedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("RufusAdvanced", id: "main") {
            MainView()
                .environmentObject(model)
                .onAppear {
                    AppDelegate.openHandler = { [weak model] path in model?.selectImage(path: path) }
                    if let first = AppDelegate.pendingOpen.first { model.selectImage(path: first); AppDelegate.pendingOpen.removeAll() }
                    Snapshot.scheduleIfRequested(model: model)
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About RufusAdvanced") { delegate.showAbout() }
                Button("Permissions…") { model.permissions.refresh(); model.permissions.showSheet = true }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Image…") { model.chooseImage() }.keyboardShortcut("o")
            }
            CommandMenu("Drive") {
                Button("Refresh Devices") { model.refreshDisks() }.keyboardShortcut("r")
                Button("Start") { model.requestStart() }.keyboardShortcut(.return, modifiers: [.command])
                    .disabled(model.startDisabledReason != nil)
                Button("Cancel") { model.cancel() }.keyboardShortcut(".")
                    .disabled(!model.isBusy)
                Divider()
                Button("Compute Image Checksums…") { model.showHash = true }.keyboardShortcut("h", modifiers: [.command, .shift])
                    .disabled(model.image == nil)
            }
            CommandGroup(after: .help) {
                Button("RufusAdvanced on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/\(AppModel.repository)")!) }
            }
        }

        Window("Download Center", id: "downloads") {
            DownloadCenterView().environmentObject(model)
        }
        .defaultSize(width: 860, height: 640)

        Window("Log", id: "log") {
            LogView().environmentObject(model)
        }
        .defaultSize(width: 760, height: 460)

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var aboutWindow: NSWindow?
    /// Files opened through Finder / the Dock before the model existed.
    static var pendingOpen: [String] = []
    static var openHandler: ((String) -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls where u.isFileURL {
            if let h = AppDelegate.openHandler { h(u.path) } else { AppDelegate.pendingOpen.append(u.path) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func showAbout() {
        if aboutWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 460), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "About RufusAdvanced"
            w.contentView = NSHostingView(rootView: AboutView())
            w.isReleasedWhenClosed = false
            w.center()
            aboutWindow = w
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
    }
}

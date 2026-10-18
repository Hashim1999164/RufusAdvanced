import Foundation
import SwiftUI
import BootKit

/// Persisted user preferences.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("downloadFolder") var downloadFolder: String = {
        let dl = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!.path
        return dl + "/RufusAdvanced"
    }()
    @AppStorage("keepDownloads") var keepDownloads = true
    /// Off by default: a checksum check never deletes a download, it only warns.
    @AppStorage("verifyDownloads") var verifyDownloads = false
    @AppStorage("listUSBHardDrives") var listUSBHardDrives = false
    @AppStorage("showDiskImages") var showDiskImages = false
    @AppStorage("showAdvancedDrive") var showAdvancedDrive = false
    @AppStorage("showAdvancedFormat") var showAdvancedFormat = false
    @AppStorage("ejectWhenDone") var ejectWhenDone = false
    @AppStorage("useRufusMBR") var useRufusMBR = true
    @AppStorage("askWindowsCustomization") var askWindowsCustomization = true
    @AppStorage("macInstallToApplications") var macInstallToApplications = false
    @AppStorage("includeMacBetas") var includeMacBetas = false
    @AppStorage("checkForUpdates") var checkForUpdates = true
    @AppStorage("lastUpdateCheck") var lastUpdateCheck: Double = 0
    @AppStorage("windowsCustomization") var windowsCustomizationData: Data = Data()
    @AppStorage("verboseLog") var verboseLog = false
    @AppStorage("showLogPane") var showLogPane = false
    /// Simple (guided, default) or Advanced (every Rufus option) main window.
    @AppStorage("simpleMode") var simpleMode = true
    /// Show the permission check at launch when something needs attention.
    @AppStorage("showPermissionsAtLaunch") var showPermissionsAtLaunch = true

    private init() {
        // 1.0.x defaulted to ejecting the drive (and stored that value once the toggle was shown).
        // Since the eject-off default, reset it once so the finished drive shows up in Finder.
        let d = UserDefaults.standard
        if !d.bool(forKey: "ejectDefaultOffMigrated") {
            d.set(false, forKey: "ejectWhenDone")
            d.set(true, forKey: "ejectDefaultOffMigrated")
        }
        // 1.1.0 and older verified downloads by default; turn it off once (users can turn it back on).
        if !d.bool(forKey: "verifyDefaultOffMigrated") {
            d.set(false, forKey: "verifyDownloads")
            d.set(true, forKey: "verifyDefaultOffMigrated")
        }
    }

    var windowsCustomization: WindowsCustomization {
        get { (try? JSONDecoder().decode(WindowsCustomization.self, from: windowsCustomizationData)) ?? WindowsCustomization() }
        set { windowsCustomizationData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    func ensureDownloadFolder() -> String {
        try? FileManager.default.createDirectory(atPath: downloadFolder, withIntermediateDirectories: true)
        return downloadFolder
    }
}

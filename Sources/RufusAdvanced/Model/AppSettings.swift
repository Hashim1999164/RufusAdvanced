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
    @AppStorage("verifyDownloads") var verifyDownloads = true
    @AppStorage("listUSBHardDrives") var listUSBHardDrives = false
    @AppStorage("showDiskImages") var showDiskImages = false
    @AppStorage("showAdvancedDrive") var showAdvancedDrive = false
    @AppStorage("showAdvancedFormat") var showAdvancedFormat = false
    @AppStorage("ejectWhenDone") var ejectWhenDone = true
    @AppStorage("useRufusMBR") var useRufusMBR = true
    @AppStorage("askWindowsCustomization") var askWindowsCustomization = true
    @AppStorage("macInstallToApplications") var macInstallToApplications = false
    @AppStorage("includeMacBetas") var includeMacBetas = false
    @AppStorage("checkForUpdates") var checkForUpdates = true
    @AppStorage("lastUpdateCheck") var lastUpdateCheck: Double = 0
    @AppStorage("windowsCustomization") var windowsCustomizationData: Data = Data()
    @AppStorage("verboseLog") var verboseLog = false
    @AppStorage("showLogPane") var showLogPane = false

    var windowsCustomization: WindowsCustomization {
        get { (try? JSONDecoder().decode(WindowsCustomization.self, from: windowsCustomizationData)) ?? WindowsCustomization() }
        set { windowsCustomizationData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    func ensureDownloadFolder() -> String {
        try? FileManager.default.createDirectory(atPath: downloadFolder, withIntermediateDirectories: true)
        return downloadFolder
    }
}

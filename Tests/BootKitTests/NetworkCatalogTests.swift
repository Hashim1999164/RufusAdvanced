import Foundation
import Testing
@testable import BootKit

/// Live network checks of the download catalogs. Enable with RUFUSADV_NETWORK_TESTS=1.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RUFUSADV_NETWORK_TESTS"] == "1"))
struct NetworkCatalogTests {

    @Test func appleCatalogListsFullInstallers() async throws {
        let releases = try await AppleCatalog.fetchReleases()
        let modern = releases.filter { if case .installAssistant = $0.payload { return true }; return false }
        #expect(modern.count > 10)
        #expect(releases.contains { $0.name.contains("Sonoma") })
        #expect(releases.contains { $0.name.contains("Catalina") })
        for r in releases.prefix(8) { print(r.title, Units.human(r.totalSize)) }
    }

    @Test func microsoftLanguagesAndLinks() async throws {
        let ms = MicrosoftISO()
        await ms.refreshCatalog()
        let win11 = try #require(ms.products.first { $0.name == "Windows 11" })
        let release = try #require(win11.releases.first)
        let edition = try #require(release.editions.first)
        let langs = try await ms.languages(product: win11, edition: edition)
        let english = try #require(langs.first { $0.name == "English" })
        let links = try await ms.links(product: win11, release: release, edition: edition, language: english)
        print(links.map { "\($0.arch): \($0.fileName)" })
        #expect(links.contains { $0.arch == "x64" && $0.url.contains("microsoft.com") })
    }

    @Test(arguments: ["ubuntu-desktop-amd64", "mint-cinnamon", "debian-netinst-amd64", "debian-live-gnome", "fedora-Workstation-x86_64",
                      "arch-x86_64", "kali-installer-amd64", "rocky-10-dvd", "alma-9-minimal", "tumbleweed-dvd", "tails-img",
                      "alpine-virt-x86_64", "proxmox-ve", "popos-intel", "flavor-kubuntu-desktop", "ubuntu-desktop-arm64"])
    func linuxResolver(_ id: String) async throws {
        let edition = try #require(LinuxCatalog.distros.flatMap(\.editions).first { $0.id == id })
        let images = try await LinuxCatalog.resolve(edition)
        #expect(!images.isEmpty)
        for i in images { print(id, "→", i.title, i.url, i.sha256?.prefix(12) ?? "-") }
        #expect(images.allSatisfy { $0.sha256?.count == 64 })
    }
}

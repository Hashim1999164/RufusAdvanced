import Foundation

/// Generates the Windows answer file for Rufus' "Windows User Experience" options.
/// Faithful port of CreateUnattendXml() from Rufus' wue.c.
public enum Unattend {
    static let bypassNames = ["BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck"]
    static let disallowedAccounts: Set<String> = ["administrator", "järjestelmänvalvoja", "administrateur", "rendszergazda",
        "administrador", "администратор", "administratör", "guest", "defaultaccount", "wdagutilityaccount",
        "helpassistant", "krbtgt", "local", "none", "system"]
    static let usernameInvalid = CharacterSet(charactersIn: "/\\[]:;|=,+*?<>\"@")

    public struct Result {
        public var xml: String
        /// True when the answer file contains a windowsPE pass (must be injected into boot.wim
        /// or placed as \autounattend.xml at the media root).
        public var hasWindowsPEPass: Bool
        public var sanitizedUser: String?
    }

    public static func sanitize(user: String) -> String? {
        let trimmed = user.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !disallowedAccounts.contains(trimmed.lowercased()) else { return nil }
        let scalars = trimmed.unicodeScalars.map { usernameInvalid.contains($0) ? "_" : $0 }
        return String(String.UnicodeScalarView(scalars)).prefix(20).description
    }

    static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// - Parameters:
    ///   - arch: "x86", "amd64", "arm" or "arm64" (from the install image).
    ///   - windowsToGo: Windows To Go media (internal drives offline pass allowed).
    public static func generate(_ c: WindowsCustomization, arch: String, uiLanguage: String = "en-US", windowsToGo: Bool = false) -> Result? {
        let comp = { (name: String) -> String in
            "    <component name=\"\(name)\" processorArchitecture=\"\(arch)\" language=\"neutral\" xmlns:wcm=\"http://schemas.microsoft.com/WMIConfig/2002/State\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" publicKeyToken=\"31bf3856ad364e35\" versionScope=\"nonSxS\">\n"
        }
        let user = c.localAccountName.flatMap { sanitize(user: $0) }
        let winPE = c.bypassRequirements || c.silentInstall
        let specialize = c.noOnlineAccount || c.qualityOfLife
        let oobeShell = c.disableDataCollection || user != nil || c.duplicateRegionalSettings || c.silentInstall || c.applySkuSiPolicy || c.qualityOfLife
        let oobe = oobeShell || c.duplicateRegionalSettings || c.disableBitLocker
        let offline = (c.offlineInternalDrives && windowsToGo) || c.forceSMode
        guard winPE || specialize || oobe || offline || c.useCA2023Bootloaders else { return nil }

        var x = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<unattend xmlns=\"urn:schemas-microsoft-com:unattend\">\n"
        logInfo("Selected Windows User Experience options:")

        if winPE {
            x += "  <settings pass=\"windowsPE\">\n"
            x += comp("Microsoft-Windows-Setup")
            x += "      <UserData>\n        <AcceptEula>true</AcceptEula>\n        <ProductKey>\n          <Key />\n        </ProductKey>\n      </UserData>\n"
            if c.silentInstall {
                logInfo("• ⚠Silent Install⚠")
                x += "      <DiskConfiguration>\n        <WillShowUI>OnError</WillShowUI>\n"
                if c.disableBitLocker { x += "        <DisableEncryptedDiskProvisioning>true</DisableEncryptedDiskProvisioning>\n" }
                x += """
                        <Disk wcm:action="modify">
                          <DiskID>1</DiskID>
                          <ModifyPartitions>
                            <ModifyPartition wcm:action="modify">
                              <Order>1</Order>
                              <PartitionID>2</PartitionID>
                              <Label>RUFUS_BOOT</Label>
                            </ModifyPartition>
                          </ModifyPartitions>
                        </Disk>
                        <Disk wcm:action="add">
                          <DiskID>0</DiskID>
                          <WillWipeDisk>true</WillWipeDisk>
                          <CreatePartitions>
                            <CreatePartition wcm:action="add">
                              <Order>1</Order>
                              <Type>EFI</Type>
                              <Size>260</Size>
                            </CreatePartition>
                            <CreatePartition wcm:action="add">
                              <Order>2</Order>
                              <Type>MSR</Type>
                              <Size>16</Size>
                            </CreatePartition>
                            <CreatePartition wcm:action="add">
                              <Order>3</Order>
                              <Type>Primary</Type>
                              <Extend>true</Extend>
                            </CreatePartition>
                          </CreatePartitions>
                          <ModifyPartitions>
                            <ModifyPartition wcm:action="add">
                              <Order>1</Order>
                              <PartitionID>1</PartitionID>
                              <Label>EFI</Label>
                              <Format>FAT32</Format>
                            </ModifyPartition>
                            <ModifyPartition wcm:action="add">
                              <Order>2</Order>
                              <PartitionID>3</PartitionID>
                              <Label>Windows</Label>
                              <Letter>C</Letter>
                              <Format>NTFS</Format>
                            </ModifyPartition>
                          </ModifyPartitions>
                        </Disk>
                      </DiskConfiguration>
                      <ImageInstall>
                        <OSImage>
                          <WillShowUI>OnError</WillShowUI>
                          <InstallFrom>
                            <MetaData wcm:action="add">
                              <Key>/IMAGE/INDEX</Key>
                              <Value>\(c.editionIndex)</Value>
                            </MetaData>
                          </InstallFrom>
                          <InstallTo>
                            <DiskID>0</DiskID>
                            <PartitionID>3</PartitionID>
                          </InstallTo>
                        </OSImage>
                      </ImageInstall>

                """
            }
            if c.bypassRequirements {
                logInfo("• Bypass SB/TPM/RAM")
                x += "      <RunSynchronous>\n"
                for (i, name) in bypassNames.enumerated() {
                    x += "        <RunSynchronousCommand wcm:action=\"add\">\n          <Order>\(i + 1)</Order>\n"
                    x += "          <Path>reg add HKLM\\SYSTEM\\Setup\\LabConfig /v \(name) /t REG_DWORD /d 1 /f</Path>\n        </RunSynchronousCommand>\n"
                }
                x += "      </RunSynchronous>\n"
            }
            x += "    </component>\n"
            if c.silentInstall {
                x += comp("Microsoft-Windows-International-Core-WinPE")
                x += "      <UILanguage>\(uiLanguage)</UILanguage>\n    </component>\n"
            }
            x += "  </settings>\n"
        }

        if specialize {
            var commands: [String] = []
            if c.noOnlineAccount {
                commands.append("reg add \"HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\OOBE\" /v BypassNRO /t REG_DWORD /d 1 /f")
                logInfo("• Bypass online account requirement")
            }
            if c.qualityOfLife {
                logInfo("• QoL: Disable OneDrive and Outlook by default")
                commands += [
                    "reg add \"HKLM\\Software\\Policies\\Microsoft\\Windows\\OneDrive\" /v DisableFileSyncNGSC /t REG_DWORD /d 1 /f",
                    "PowerShell -NonInteractive -WindowStyle Hidden -Command \"Remove-Item -Path $env:SystemRoot\\System32\\OneDriveSetup.exe -Force -Confirm:$false; Remove-Item -Path $env:SystemRoot\\SysWOW64\\OneDriveSetup.exe -Force -Confirm:$false;\"",
                    "PowerShell -NonInteractive -WindowStyle Hidden -Command \"Get-AppxProvisionedPackage -Online | Where-Object {$_.PackageName -like '*Outlook*'} | Remove-AppxProvisionedPackage -Online\"",
                    "PowerShell -NonInteractive -WindowStyle Hidden -Command \"Get-AppxPackage -AllUsers *Outlook* | Remove-AppxPackage -AllUsers\"",
                    "PowerShell -NonInteractive -WindowStyle Hidden -Command \"Get-AppxProvisionedPackage -Online | Where-Object {$_.PackageName -like '*Teams*'} | Remove-AppxProvisionedPackage -Online\"",
                    "PowerShell -NonInteractive -WindowStyle Hidden -Command \"Get-AppxPackage -AllUsers *Teams* | Remove-AppxPackage -AllUsers\"",
                ]
            }
            x += "  <settings pass=\"specialize\">\n"
            x += comp("Microsoft-Windows-Deployment")
            if !commands.isEmpty {
                x += "      <RunSynchronous>\n"
                for (i, cmd) in commands.enumerated() {
                    x += "        <RunSynchronousCommand wcm:action=\"add\">\n          <Order>\(i + 1)</Order>\n          <Path>\(xmlEscape(cmd))</Path>\n        </RunSynchronousCommand>\n"
                }
                x += "      </RunSynchronous>\n"
            }
            x += "    </component>\n  </settings>\n"
        }

        if oobe {
            x += "  <settings pass=\"oobeSystem\">\n"
            if oobeShell {
                var firstLogon: [String] = []
                x += comp("Microsoft-Windows-Shell-Setup")
                if c.disableDataCollection || c.silentInstall {
                    logInfo("• Disable data collection")
                    x += "      <OOBE>\n        <HideEULAPage>true</HideEULAPage>\n        <ProtectYourPC>3</ProtectYourPC>\n"
                    if c.silentInstall {
                        x += "        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>\n        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>\n"
                    }
                    x += "      </OOBE>\n"
                }
                if c.duplicateRegionalSettings, let tz = c.timeZone {
                    x += "      <TimeZone>\(xmlEscape(tz))</TimeZone>\n"
                }
                if let user {
                    logInfo("• Use '\(user)' for local account name")
                    let u = xmlEscape(user)
                    x += """
                          <UserAccounts>
                            <LocalAccounts>
                              <LocalAccount wcm:action="add">
                                <Name>\(u)</Name>
                                <DisplayName>\(u)</DisplayName>
                                <Group>Administrators;Power Users</Group>
                                <Password>
                                  <Value>UABhAHMAcwB3AG8AcgBkAA==</Value>
                                  <PlainText>false</PlainText>
                                </Password>
                              </LocalAccount>
                            </LocalAccounts>
                          </UserAccounts>

                    """
                    firstLogon.append("net user \"\(user)\" /logonpasswordchg:yes")
                    firstLogon.append("net accounts /maxpwage:unlimited")
                }
                if c.applySkuSiPolicy {
                    logInfo("• Apply SkuSiPolicy.p7b")
                    firstLogon.append("cmd /c mountvol S: /S && copy %WINDIR%\\system32\\SecureBootUpdates\\SkuSiPolicy.p7b S:\\EFI\\Microsoft\\Boot && mountvol S: /D")
                }
                if c.qualityOfLife {
                    logInfo("• QoL: Disable Fast Startup, Copilot, Recommendations, News and Teams by default")
                    firstLogon += [
                        "reg add \"HKLM\\System\\CurrentControlSet\\Control\\Session Manager\\Power\" /v HiberbootEnabled /t REG_DWORD /d 0 /f",
                        "reg add \"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\" /v ShowCopilotButton /t REG_DWORD /d 0 /f",
                        "reg add \"HKLM\\Software\\Policies\\Microsoft\\Windows\\WindowsCopilot\" /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f",
                        "reg add \"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Search\" /v SearchboxTaskbarMode /t REG_DWORD /d 1 /f",
                        "reg add \"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Search\" /v SearchboxTaskbarModeCache /t REG_DWORD /d 1 /f",
                        "reg add \"HKLM\\Software\\Policies\\Microsoft\\Windows\\CloudContent\" /v DisableWindowsConsumerFeatures /t REG_DWORD /d 1 /f",
                        "reg add \"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager\" /v SystemPaneSuggestionsEnabled /t REG_DWORD /d 0 /f",
                        "reg add \"HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Search\" /v BingSearchEnabled /t REG_DWORD /d 0 /f",
                        "reg add \"HKLM\\Software\\Policies\\Microsoft\\Windows\\Device Metadata\" /v PreventDeviceMetadataFromNetwork /t REG_DWORD /d 1 /f",
                        "reg add \"HKLM\\Software\\Policies\\Microsoft\\Dsh\" /v AllowNewsAndInterests /t REG_DWORD /d 0 /f",
                        "reg add \"HKLM\\Software\\Policies\\Microsoft\\Windows\\Windows Feeds\" /v EnableFeeds /t REG_DWORD /d 0 /f",
                        "reg add \"HKLM\\Software\\Microsoft\\Windows\\CurrentVersion\\Communications\" /v ConfigureChatAutoInstall /t REG_DWORD /d 0 /f",
                        "reg add \"HKLM\\Software\\Policies\\Microsoft\\Windows\\CloudContent\" /v DisableCloudOptimizedContent /t REG_DWORD /d 1 /f",
                        "reg add \"HKLM\\Software\\Policies\\Microsoft\\Edge\" /v HideFirstRunExperience /t REG_DWORD /d 1 /f",
                        "reg add \"HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\" /v Start_Layout /t REG_DWORD /d 1 /f",
                        "PowerShell -NonInteractive -WindowStyle Hidden -Command \"Set-ItemProperty -Path 'Registry::HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Start' -Name 'VisiblePlaces' -Value $([convert]::FromBase64String('ztU0LVr6Q0WC8iLm6vd3PC+zZ+PeiVVDv85h83sYqTe8JIoUDNaJQqCAbtm7okiCRIF1/g0IrkKL2jTtl7ZjlEqwvXRK+WhPi9ZDmAcdqLyGCHNSqlFDQp97J3ZYRlnU')) -Type 'Binary'\"",
                        "reg add \"HKCU\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\\InprocServer32\" /ve /t REG_SZ /d \"\" /f",
                    ]
                    logInfo("• QoL: Restore classic context menu")
                }
                if !firstLogon.isEmpty {
                    x += "      <FirstLogonCommands>\n"
                    for (i, cmd) in firstLogon.enumerated() {
                        x += "        <SynchronousCommand wcm:action=\"add\">\n          <Order>\(i + 1)</Order>\n          <CommandLine>\(xmlEscape(cmd))</CommandLine>\n        </SynchronousCommand>\n"
                    }
                    x += "      </FirstLogonCommands>\n"
                }
                x += "    </component>\n"
            }
            if c.duplicateRegionalSettings {
                logInfo("• Use the same regional options as this user's")
                x += comp("Microsoft-Windows-International-Core")
                let locale = c.systemLocale ?? "en-US"
                x += "      <InputLocale>\(c.inputLocale ?? locale)</InputLocale>\n"
                x += "      <SystemLocale>\(locale)</SystemLocale>\n"
                x += "      <UserLocale>\(locale)</UserLocale>\n"
                x += "      <UILanguage>\(c.uiLanguage ?? uiLanguage)</UILanguage>\n"
                x += "      <UILanguageFallback>en-US</UILanguageFallback>\n"
                x += "    </component>\n"
            }
            if c.disableBitLocker {
                logInfo("• Disable BitLocker")
                x += comp("Microsoft-Windows-SecureStartup-FilterDriver")
                x += "      <PreventDeviceEncryption>true</PreventDeviceEncryption>\n    </component>\n"
                x += comp("Microsoft-Windows-EnhancedStorage-Adm")
                x += "      <TCGSecurityActivationDisabled>1</TCGSecurityActivationDisabled>\n    </component>\n"
            }
            x += "  </settings>\n"
        }

        if offline {
            x += "  <settings pass=\"offlineServicing\">\n"
            if c.offlineInternalDrives && windowsToGo {
                logInfo("• Set internal drives offline")
                x += comp("Microsoft-Windows-PartitionManager") + "      <SanPolicy>4</SanPolicy>\n    </component>\n"
            }
            if c.forceSMode {
                logInfo("• Enforce S Mode")
                x += comp("Microsoft-Windows-CodeIntegrity") + "      <SkuPolicyRequired>1</SkuPolicyRequired>\n    </component>\n"
            }
            x += "  </settings>\n"
        }
        if c.useCA2023Bootloaders { logInfo("• Use 'Windows CA 2023' signed bootloaders") }
        x += "</unattend>\n"
        return Result(xml: x, hasWindowsPEPass: winPE, sanitizedUser: user)
    }

    /// WIM architecture names → unattend processorArchitecture.
    public static func unattendArch(_ wimArch: String?) -> String {
        switch wimArch {
        case "x86": return "x86"
        case "arm": return "arm"
        case "arm64": return "arm64"
        default: return "amd64"
        }
    }
}

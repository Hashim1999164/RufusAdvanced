# Rufus feature parity

How every option of Rufus 4.15 maps to RufusAdvanced on macOS.
✅ = supported · 🟡 = supported with an optional tool or with limits · ❌ = not available on macOS (reason given).

## Drive properties

| Rufus option | RufusAdvanced |
|---|---|
| Device list (USB flash drives, card readers) | ✅ live hot-plug updates; built-in SD readers included |
| List USB Hard Drives | ✅ *Advanced drive properties* |
| Boot selection: Disk or ISO image | ✅ |
| Boot selection: Non bootable | ✅ |
| Boot selection: FreeDOS | ✅ with keyboard layout / codepage (FreeDOS kernel & locale files from Rufus) |
| Boot selection: Syslinux 4.07 / 6.04, GRUB 2, UEFI:NTFS | ✅ shown with advanced drive properties (like Rufus) |
| Boot selection: ReactOS, Grub4DOS | 🟡 automatic for images that need them (MBR/PBR code), not as standalone choices |
| Image option: Standard Windows installation | ✅ |
| Image option: Windows To Go | ❌ requires Windows' `bcdboot` and offline image servicing |
| Partition scheme MBR / GPT | ✅ |
| Target system BIOS / UEFI / BIOS or UEFI | ✅ |
| Add fixes for old BIOSes | ✅ cylinder alignment + extra 0xEA partition |
| Use Rufus MBR | ✅ (default on, like Rufus) |
| Enable runtime UEFI media validation | ✅ uefi-md5sum + generated md5sum.txt |
| Persistent partition size | ✅ Ubuntu (casper-rw) and Debian (persistence.conf) — native ext3 |

## Format options

| Rufus option | RufusAdvanced |
|---|---|
| Volume label (with Rufus label sanitizing) | ✅ |
| FAT / FAT32 / exFAT / UDF | ✅ built in |
| NTFS | ✅ built in (embedded ntfs-3g + mkntfs, no macFUSE) |
| ext2 / ext3 | ✅ native formatter |
| ext4 | 🟡 needs e2fsprogs (`brew install e2fsprogs`) |
| ReFS | ❌ no ReFS implementation exists for macOS |
| HFS+ / APFS | ✅ (extra, not in Rufus) |
| Cluster size | ✅ |
| Quick format | ✅ (unchecked = zero fill before formatting) |
| Create extended label and icon files | ✅ autorun.inf + autorun.ico |
| Check device for bad blocks (1/2 passes, SLC/MLC/TLC) | ✅ same patterns as Rufus, reports fake capacity |

## Images

| Rufus feature | RufusAdvanced |
|---|---|
| ISO mode / DD mode selection for ISOHybrid images | ✅ |
| Compressed images (.gz .xz .bz2 .zst .zip .lzma .7z) | ✅ (.zst/.lzma/.7z need Homebrew tools) |
| VHD / VHDX / FFU / WIM sources | 🟡 fixed VHD built in; VHDX & dynamic VHD via qemu-img; FFU/WIM application not supported |
| Windows install.wim > 4 GB | ✅ NTFS + UEFI:NTFS by default, like Rufus; also FAT32 + split .swm (wimlib) or exFAT + UEFI:NTFS |
| UEFI:NTFS for NTFS/exFAT media | ✅ |
| Windows 7 x64 UEFI fix | 🟡 needs wimlib |
| Windows XP / WinPE (masquerading, txtsetup patching) | 🟡 boot records and masquerading only |
| Syslinux version matching (download from rufus.ie) | ✅ RSA signature verified like Rufus |
| GRUB 2 version matching | ✅ RSA signature verified like Rufus |
| Linux config fixes (labels, persistence, inst.repo, FreeNAS) | ✅ |
| Revoked UEFI bootloader (DBX/SBAT) detection | ❌ not yet implemented |
| Truncated ISO detection | 🟡 size checks only |

## Windows User Experience dialog

| Rufus option | RufusAdvanced |
|---|---|
| Remove requirement for 4GB+ RAM, Secure Boot and TPM 2.0 | ✅ (answer file; plus appraiserres.dll and 24H2 setup wrapper for upgrades) |
| Remove requirement for an online Microsoft account | ✅ |
| Create a local account | ✅ |
| Set regional options to the same values as this user's | ✅ taken from macOS (time zone mapped to Windows names) |
| Disable data collection | ✅ |
| Disable BitLocker automatic device encryption | ✅ |
| QoL improvements | ✅ |
| Apply SkuSiPolicy.p7b | ✅ |
| Use 'Windows CA 2023' signed bootloaders | 🟡 needs wimlib |
| Restrict Windows to S-Mode | ✅ |
| Silent install | ✅ (with the exFAT/NTFS + UEFI:NTFS layout) |
| Prevent Windows To Go from accessing internal disks | ❌ (no Windows To Go) |

## Other

| Rufus feature | RufusAdvanced |
|---|---|
| Download ISO (Fido: Windows 11/10, UEFI Shell) | ✅ native port, catalog auto-updated from upstream Fido |
| macOS installer downloads | ✅ (extra) Apple catalog + legacy direct links; one-click *Get Installer* (download → install into Applications → verify → use) |
| Linux downloads | ✅ (extra) 17 distributions with SHA-256 verification |
| Compute image checksums (MD5/SHA-1/SHA-256/SHA-512) | ✅ |
| Save drive to VHD | ✅ .img / fixed .vhd / .dmg |
| Log window, save log | ✅ |
| Check for updates | ✅ GitHub releases |
| Localization (40 languages) | ❌ English only for now — contributions welcome |
| Cheat modes (Alt-…) | 🟡 the useful ones are regular settings (list USB HDDs, disk images, Rufus MBR) |

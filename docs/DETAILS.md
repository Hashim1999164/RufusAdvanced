# RufusAdvanced — full details

Everything the [README](../README.md) leaves out: the complete feature list, every option, the command line tool,
optional extras, building from source and technical answers. How it works inside: [ARCHITECTURE.md](ARCHITECTURE.md).

> **Not affiliated with Rufus.** RufusAdvanced is an independent, GPLv3 project inspired by — and partially
> derived from — [Rufus](https://rufus.ie) by Pete Batard. All credit for the original design, boot records and
> techniques goes to the Rufus project and the projects listed under [Credits](#credits).

## Features

### Any operating system
| | |
|---|---|
| **Windows 7 → 11** | ISO mode with **NTFS + UEFI:NTFS** (built in — like Rufus, for install.wim > 4 GB), FAT32 (install.wim split with wimlib), exFAT, MBR/GPT, BIOS + UEFI, Windows 7 UEFI fix |
| **Windows customization** | Rufus' *Windows User Experience* options: bypass TPM / Secure Boot / RAM checks, no Microsoft account, local account, regional settings copied from your Mac, no data collection, no BitLocker, QoL tweaks (Copilot/OneDrive/Outlook…), SkuSiPolicy, *Windows CA 2023* bootloaders, S-Mode, ⚠ silent install. Also the 24H2+ in-place upgrade bypass (setup wrapper + appraiserres) |
| **Linux** | ISO mode (FAT32/exFAT/NTFS, Syslinux install with signature-verified version matching, GRUB 2 BIOS, label & kernel option patching) or DD mode for ISOHybrid images |
| **Linux persistence** | Ubuntu (`casper-rw`) and Debian (`persistence` + `persistence.conf`) persistent partitions — ext3 is created natively, no extra tools |
| **macOS** | Any installer from Lion 10.7 to the latest release, using Apple's `createinstallmedia` (or `asr` for Lion / Mountain Lion). Works from an *Install macOS* app, an `InstallAssistant.pkg`, Apple's legacy `InstallMacOSX.dmg`, or a 10.13–10.15 package set. **One click** with *Get Installer*: download → install into Applications → verify → selected |
| **Raw images** | `.img`, `.iso` (hybrid), `.gz`, `.xz`, `.bz2`, `.zst`, `.zip`, `.7z`, `.lzma`, fixed `.vhd`, `.vhdx`/`.vmdk`/`.qcow2` (with qemu-img), `.dmg` — written in DD mode with optional read-back verification |
| **Other boot types** | Non bootable, FreeDOS (with keyboard layout), Syslinux 4/6, GRUB 2, UEFI:NTFS |

### Download Center — official sources only
* **macOS**: every full installer listed in Apple's software update catalog (incl. betas, optional) plus Apple's direct
  links for Lion → Sierra. Downloads come straight from `swcdn.apple.com` / `updates.cdn-apple.com` (optionally checked against Apple's package checksums).
  *Get Installer* also installs the package into Applications and checks it (full installer, payload, Apple signatures);
  installers already on your Mac are listed with a one-click *Use*.
* **Windows**: Windows 11 / 10 ISOs (all languages, x64 + ARM64) straight from Microsoft — same method as Rufus' Fido script — and UEFI Shell images.
* **Linux**: Ubuntu (+ Kubuntu, Xubuntu, Lubuntu, MATE), Linux Mint, Debian (netinst + live), Fedora, Arch, Kali, Pop!_OS,
  Rocky, AlmaLinux, openSUSE Tumbleweed, Tails, Alpine and Proxmox VE. The latest versions are resolved live from each
  project's checksum list / API (optional SHA-256 check).
* **Any URL**, with optional checksum.
* Resumable downloads, a library of previous downloads that are re-used automatically, *Download & Use*, and the choice to **keep** or **delete** images after writing.
* Optional verification (off by default): SHA-256 for Linux/Windows, Apple's package checksums for macOS. A mismatch only
  shows a warning — downloads are never deleted.

### Every Rufus option
Partition scheme (MBR/GPT) · Target system (BIOS / UEFI / both) · File system (FAT, FAT32, exFAT, NTFS, UDF, ext2/3/4, HFS+, APFS) ·
Cluster size · Volume label · Quick/slow format · Extended label & icon (`autorun.inf`) · Bad blocks check (1/2 passes, SLC/MLC/TLC patterns,
fake drive detection) · List USB hard drives · Fixes for old BIOSes · Rufus MBR · Runtime UEFI media validation (uefi-md5sum) ·
Persistence size · Image checksums (MD5/SHA-1/SHA-256/SHA-512) · Save drive to image (.img/.vhd/.dmg) · Log window.
See [docs/RUFUS-PARITY.md](RUFUS-PARITY.md) for the complete option-by-option mapping.

### Safe by design
* Internal disks and the system disk are **never** listed or accepted (built-in SD card readers are allowed).
* The drive's identity and size are re-checked right before writing; the image can't be on the target drive.
* A clear confirmation shows exactly what will be erased; one administrator prompt per operation.
* No background service or kernel extension is installed.

## Install

### Homebrew

```bash
brew install --cask hashim1999164/tap/rufusadvanced
```

The cask installs the app in */Applications*, clears the download quarantine (the app is not notarized) and links the
command line tool as `rufusadv`. Update with `brew upgrade --cask rufusadvanced`.

### Manual

1. Download `RufusAdvanced-x.y.z-macOS.dmg` from the [latest release](https://github.com/Hashim1999164/RufusAdvanced/releases/latest).
2. Drag **RufusAdvanced** to *Applications*.
3. The app is ad-hoc signed (not notarized). If macOS refuses to open it, go to **System Settings › Privacy & Security**
   and click **Open Anyway** (on macOS 13–14, right-click the app → **Open** also works), or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/RufusAdvanced.app
   ```

Requirements: macOS 13 Ventura or later, Apple silicon or Intel.

## Usage

1. **Plug in** a USB drive or SD card — it is selected automatically.
2. **Select** an ISO / image / macOS installer (or drop it on the window), or click **Download** to fetch one.
   RufusAdvanced scans it and picks the best settings for you, just like Rufus.
3. Press **START**, confirm, enter your password. Done.

Advanced options stay folded away until you need them (*Advanced drive properties*, *Advanced format options*).

### Command line

The disk engine ships as a CLI inside the app bundle:

```bash
/Applications/RufusAdvanced.app/Contents/MacOS/rufusadv-helper help
```

```bash
sudo /Applications/RufusAdvanced.app/Contents/MacOS/rufusadv-helper write --image ~/Downloads/ubuntu.iso --device disk4 --mode iso --persistence 4096
```

## Optional tools

Everything works out of the box — including NTFS, which is built in. These Homebrew packages unlock extras:

| Tool | Install | Unlocks |
|---|---|---|
| wimlib | `brew install wimlib` | FAT32 Windows media with install.wim > 4 GB, boot.wim answer-file injection, *Windows CA 2023* bootloaders, Windows 7 UEFI |
| e2fsprogs | `brew install e2fsprogs` | ext4 (ext2/ext3 are built in) |
| zstd / xz | `brew install zstd xz` | `.zst` / `.lzma` images (`.gz`, `.xz`, `.bz2`, `.zip` are built in) |
| sevenzip | `brew install sevenzip` | `.7z` archived images |
| qemu | `brew install qemu` | VHDX, dynamic VHD, VMDK, QCOW2 images |

## Building from source

```bash
git clone https://github.com/Hashim1999164/RufusAdvanced.git
cd RufusAdvanced
swift build                 # debug build
scripts/test.sh             # unit + end-to-end tests (uses disk images, no root needed)
scripts/build-app.sh        # universal RufusAdvanced.app + .dmg + .zip in ./dist
```

Only the Xcode Command Line Tools are required. See [docs/ARCHITECTURE.md](ARCHITECTURE.md) for how it works.

## Technical FAQ

**Why does it ask for my password?** macOS only lets an administrator open a USB drive for raw writing. RufusAdvanced
asks once per operation through Apple's `authopen` (the same mechanism as balenaEtcher and Raspberry Pi Imager), so no
Full Disk Access is needed.

**"Could not open /dev/rdiskN: Operation not permitted"?** Move RufusAdvanced.app to **/Applications** and open it from
there (apps started from Desktop, Documents, Downloads or a disk image can't reliably get drive access), then click
START and enter your password. If it still fails, enable RufusAdvanced in System Settings › Privacy & Security › Full
Disk Access. Turn on **Verbose** in the log pane at the bottom of the window to see every step; logs are also saved in
`~/Library/Logs/RufusAdvanced/`.

**Windows: NTFS or FAT32?** When install.wim is larger than 4 GB (the FAT32 file limit, true for most current ISOs),
RufusAdvanced uses NTFS + UEFI:NTFS like Rufus: it boots on UEFI PCs (the UEFI:NTFS loader is Secure Boot signed; a few
PCs still need Secure Boot disabled) and on BIOS PCs. FAT32 with a split install.wim (needs `brew install wimlib`)
boots everywhere, including Macs and the strictest Secure Boot setups.

**Do I need macFUSE for NTFS?** No. RufusAdvanced embeds the ntfs-3g library and writes NTFS directly.

**macOS: how do I get an installer?** Click **Download › macOS…**, then **Get Installer** next to the version you want.
RufusAdvanced downloads it from Apple, installs it into Applications (you'll be asked for your password), verifies it and
selects it. Already have a downloaded `InstallAssistant.pkg`? Drop it on the window and click **Install to Applications**.

**Linux: ISO or DD mode?** DD mode is the most faithful for ISOHybrid images. ISO mode keeps the drive usable as storage
and enables persistence.

**Can I boot a Mac from a Windows/Linux drive?** Intel Macs can boot UEFI media (hold ⌥ Option). Apple silicon Macs only boot macOS.

## Contributing

Contributions are very welcome! Please read [CONTRIBUTING.md](../CONTRIBUTING.md) and the [Code of Conduct](../CODE_OF_CONDUCT.md).
Security issues: see [SECURITY.md](../SECURITY.md).

## Credits

* [Rufus](https://github.com/pbatard/rufus) — Pete Batard (GPLv3): design, boot logic, Windows User Experience options, bundled resources.
* [Fido](https://github.com/pbatard/Fido) — Windows ISO download method (GPLv3).
* [ms-sys](https://ms-sys.sourceforge.net/) — boot records (GPLv2+). [Syslinux](https://wiki.syslinux.org) (GPLv2+). [GRUB](https://www.gnu.org/software/grub/) (GPLv3+). [FreeDOS](https://www.freedos.org) (GPLv2).
* [UEFI:NTFS](https://github.com/pbatard/uefi-ntfs) and [uefi-md5sum](https://github.com/pbatard/uefi-md5sum) — Pete Batard (GPLv2+).
* [ntfs-3g](https://github.com/tuxera/ntfs-3g) — libntfs-3g and mkntfs by Tuxera and contributors (GPLv2+), embedded for NTFS support.

## License

[GNU General Public License v3.0](../LICENSE). Bundled third-party files keep their own licenses (see [`Resources/BootKit/licenses`](../Resources/BootKit/licenses)).

# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.2.2] - 2026-10-19

### Fixed
- The main window could open extremely tall (the whole screen height), pushing the Create USB button out of reach. The
  window now has sensible bounds: Simple mode opens at 560 × 620 and never grows beyond 680 × 760; Advanced mode is
  capped at 760 × 900.

## [1.2.1] - 2026-10-18

### Added
- **Permission check at launch.** RufusAdvanced checks what it needs from macOS every time it starts — running from
  Applications, Full Disk Access (needed for macOS installers), access to the download folder, an administrator
  account, and wimlib for FAT32 Windows drives — and lists anything missing with a one-click fix (Open Settings, Show in
  Finder, Copy command). The list refreshes when you come back from System Settings; a banner and a toolbar shield show
  remaining problems, and **RufusAdvanced › Permissions…** opens it any time.

## [1.2.0] - 2026-10-18

### Added
- **Simple mode (new default):** a guided, animated flow — choose a system, choose the USB drive, create, done — with
  the operating system's logo detected and fetched automatically (macOS installers show their own icon), a progress
  ring, live stages and a finish screen with Show in Finder / Eject. Every Rufus option is still one click away in
  **Advanced** mode (toolbar switch).
- **NTFS "Finalizing: Writing NTFS metadata" took up to 15 minutes on slow USB drives** with no sign of life. Measured
  on a real 64 GB stick with a Windows 10 ISO: the final step went from 15:34 to 0:19, and it now shows progress (MB
  written, then the drive's own cache flush with the elapsed time) and logs each step.
- **Faster NTFS writes on USB flash drives.** ntfs-3g left a 16 MB gap after every file, scattering a Windows ISO over
  ~15 GB of the drive; files are now laid out next to each other, small files are batched, and each large file goes out
  in whole requests. Copying a Windows 10 ISO needs ~150 non-sequential writes instead of ~1,300 (cheap sticks spend
  up to a second on each).

### Changed
- Windows images with an install.wim larger than 4 GB default to **FAT32 + split install.wim** again when wimlib is
  installed (boots everywhere). NTFS + UEFI:NTFS stays available and is used when wimlib is missing.

### Fixed
- Installing a downloaded macOS package failed with "Could not open package": the administrator job may not read
  ~/Downloads. It now gets an instant APFS copy from a folder macOS doesn't protect (no extra disk space).
- createinstallmedia "IA app name cookie write failed / The bless of the installer disk failed" (exit code 250): macOS
  privacy protection blocked writing to the USB drive. RufusAdvanced now explains the fix (Full Disk Access) with an
  **Open Settings** button, recommends it up front for macOS installers, and logs which app macOS holds responsible.

## [1.1.2] - 2026-10-18

### Fixed
- **"NTFS: read error on the source of …: Input/output error"** while copying a Windows ISO. When an image was already
  attached (by Finder, another scan of the same file, or a second app instance), macOS handed out the same device and
  detaching it afterwards pulled the ISO out from under the running copy. ISOs now get their own private attachment,
  and images attached by someone else are never detached.
- **NTFS writes were very slow on real USB drives** (about 4 MB/s). Small metadata I/O now goes through a write-back
  cache and is written in large sorted batches, and files are allocated in one piece instead of as sparse files: about
  45,000 synchronous disk operations for a Windows 10 ISO became about 1,700, so copying runs at the drive's speed.

## [1.1.1] - 2026-10-18

### Fixed
- **macOS downloads always failed with "Checksum mismatch" and the finished download was deleted.** Apple's catalog
  `Digest` is the SHA-1 of the package's table of contents, not of the whole file. Apple packages are now verified the
  right way: the table of contents must match the catalog, then every file inside the package is checked against it.
- A checksum mismatch never deletes a download any more: the file is kept, marked *Done (unverified)* with the reason,
  and can still be used.

### Changed
- Download verification is now **off by default** (also for existing installs, once). Turn it on in the Download Center
  or in Settings › Downloads.

## [1.1.0] - 2026-10-17

### Added
- **Built-in NTFS.** The ntfs-3g library and mkntfs are embedded: NTFS is formatted and filled directly, without macFUSE,
  Homebrew or mounting. Windows images whose install.wim is larger than 4 GB now default to **NTFS + UEFI:NTFS**, exactly
  like Rufus (FAT32 + split install.wim and exFAT remain available). Windows customization, Linux config patching, UEFI
  media validation and extended labels all work on NTFS.
- **macOS installer assistant.** *Get Installer* downloads Apple's InstallAssistant.pkg, installs it into Applications
  (one password prompt, live progress), verifies the result (full installer, complete payload, Apple code signatures)
  and selects it — one click. Installers already in Applications are listed with a one-click *Use*; selecting a .pkg
  offers *Install to Applications* / *Open in Installer* (the result is detected automatically). Packages that are not
  signed by Apple are refused.
- **Homebrew:** `brew install --cask hashim1999164/tap/rufusadvanced`.
- Live log pane in the main window with a **Verbose** toggle, Copy, Save and Show-in-Finder; full detail (commands, exit
  codes, errno, authorization status, progress, helper output) is always written to `~/Library/Logs/RufusAdvanced/`.
- Millisecond timestamps in the log.

### Fixed
- "Could not open /dev/rdiskN: Operation not permitted" when writing to a real USB drive: raw disk access now goes
  through Apple's `authopen` (one password dialog per job, no Full Disk Access needed); the helper runs as you.
- FAT12/16/32 and exFAT are formatted in-process (newfs_msdos/newfs_exfat can't open authorized devices).
- Permission errors (EPERM/EACCES) now explain what to do instead of showing the raw error; the app warns when it runs
  from Desktop, Documents, Downloads, a disk image or a translocated location.
- `diskutil mount` falls back to the default mount point when a private one is refused.
- The File system picker no longer shows a blank entry and a macFUSE warning for NTFS.

### Changed
- "Eject the drive when finished" is now off by default (existing settings are reset once). The finished drive is
  remounted normally so it appears in Finder and on the Desktop; the status bar shows "Ready: mounted at /Volumes/…"
  with a **Show in Finder** button. When eject is on, the status says the drive was ejected and is safe to remove.
- CLI: `--eject` to eject (default: mount in Finder), `--no-mount` to leave it unmounted.

## [1.0.1] - 2026-10-17

### Fixed
- The app no longer freezes while the administrator password prompt is shown.
- macOS installer media: accept "16 GB" (and "8 GB" for older releases) drives, using Apple's decimal size requirements.

## [1.0.0] - 2026-10-17

First public release.

### Added
- Native SwiftUI app for macOS 13+ (universal) with Rufus-style smart defaults, drag & drop and a log window.
- Disk engine (`BootKit`): MBR/GPT writer, Rufus layout planner (UEFI:NTFS, persistence, old BIOS fixes),
  ms-sys boot records (Windows 7 / Rufus / Syslinux / GRUB 2 / protective MBRs, FAT/NTFS PBRs), FAT/exFAT/UDF/HFS+/APFS
  formatting, native ext2/ext3 formatter, Syslinux installer, bad blocks checker, save drive to image.
- Write modes: ISO extraction, DD (with gzip/xz/bz2/zstd/zip/7z/VHD/DMG sources and verification), macOS createinstallmedia / asr.
- Windows: install.wim splitting, Windows User Experience customization (answer file injected into boot.wim),
  24H2 in-place upgrade bypass, Windows CA 2023 bootloaders, Windows 7 UEFI fix, UEFI media validation.
- Linux: persistence (casper-rw / persistence), config patching (labels, persistence, Red Hat inst.repo),
  El Torito EFI image extraction, version matched Syslinux / GRUB from rufus.ie with signature verification.
- Download Center: Apple software update catalog + legacy direct links, Microsoft (Fido method), 17 Linux distributions,
  custom URLs; resumable, verified, re-usable downloads.
- `rufusadv-helper` command line tool.

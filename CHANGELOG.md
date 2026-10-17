# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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

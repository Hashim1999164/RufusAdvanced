# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed
- "Could not open /dev/rdiskN: Operation not permitted" when writing to a real USB drive: raw disk access now goes
  through Apple's `authopen` (one password dialog per job, no Full Disk Access needed); the helper runs as you.
- FAT12/16/32 and exFAT are formatted in-process (newfs_msdos/newfs_exfat can't open authorized devices).
- Permission errors (EPERM/EACCES) now explain what to do instead of showing the raw error; the app warns when it runs
  from Desktop, Documents, Downloads, a disk image or a translocated location.
- `diskutil mount` falls back to the default mount point when a private one is refused.

### Changed
- "Eject the drive when finished" is now off by default (existing settings are reset once). The finished drive is
  remounted normally so it appears in Finder and on the Desktop; the status bar shows "Ready: mounted at /Volumes/…"
  with a **Show in Finder** button. When eject is on, the status says the drive was ejected and is safe to remove.
- CLI: `--eject` to eject (default: mount in Finder), `--no-mount` to leave it unmounted.

### Added
- Live log pane in the main window with a **Verbose** toggle, Copy, Save and Show-in-Finder; full detail (commands, exit
  codes, errno, authorization status, progress, helper output) is always written to `~/Library/Logs/RufusAdvanced/`.
- Millisecond timestamps in the log.

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

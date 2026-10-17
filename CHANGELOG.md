# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

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

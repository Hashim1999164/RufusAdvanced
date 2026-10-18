# Architecture

```
RufusAdvanced.app
├── Contents/MacOS/RufusAdvanced      SwiftUI app (unprivileged)
├── Contents/MacOS/rufusadv-helper    disk worker + CLI (runs as you; as root only for macOS installers)
└── Contents/Resources/BootKit/       boot records, UEFI:NTFS, FreeDOS, Syslinux, GRUB, uefi-md5sum, setup wrappers
```

## Targets

| Target | Role |
|---|---|
| `BootKit` | UI-free engine shared by the app and the helper |
| `RufusHelper` | `rufusadv-helper`: runs `JobSpec`s, also a standalone CLI |
| `RufusAdvanced` | SwiftUI app: device list, options, Download Center, logs |
| `BootKitTests` | swift-testing unit tests and end-to-end tests on attached disk images |

## How a write works

1. The app inspects the image (`ImageInspector`): ISO9660/UDF/El Torito parsing, hybrid MBR/GPT detection,
   WIM XML (Windows editions/build), Syslinux/GRUB/casper/live markers, macOS installer metadata.
2. `MediaPlanner` proposes Rufus-style defaults; the user may change everything.
3. The app serialises a `JobSpec` and launches `rufusadv-helper run --job <base64> --events <file> --cancel <file>`:
   as the current user. Only macOS installer jobs (`installer`, `createinstallmedia`, `asr`) are launched as root through
   one `osascript … with administrator privileges` prompt. The helper's own stdout/stderr go to `helper-output.log` in
   the job folder, which the app also tails into the log.
4. The helper re-validates the device (`JobContext`), streams `JobEvent`s (log lines, progress, result) as JSON lines into
   the events file, which the app tails. Cancelling creates the cancel file.
5. `JobRunner` dispatches to `DDWriter`, `ISOWriter`, `FormatWriter`, `MacInstallerWriter` or `SaveImageJob`.

## Raw disk access (authopen)

Since macOS 10.15, `open("/dev/rdiskN")` fails with `EPERM` ("Operation not permitted") — even as root — unless the
responsible app has Full Disk Access, and with `EACCES` for normal users. `RawDevice` therefore falls back to
`DiskAuthorization`: it pre-authorizes the `sys.openfile.readwrite./dev/(r)diskN[sM]` rights once (one password dialog
per job, `AuthorizationCopyRights` with `preAuthorize`) and asks Apple's `/usr/libexec/authopen` to open each device,
receiving the descriptor over a socket (`CBootKit/authopen.c`, `SCM_RIGHTS`). This is what Etcher and Raspberry Pi
Imager do. Every whole-disk and slice open in the pipeline (partitioning, re-probe, formatting, PBR, Syslinux, bad
blocks, DD, save image) goes through `RawDevice`, so through this path.

External formatters that open the device themselves (newfs_msdos/newfs_exfat) can't use those descriptors, so FAT12/16/32
and exFAT are written in-process (`FATFormatter`), and NTFS through the embedded ntfs-3g (`CNTFS`, `NTFSVolume`).
UDF (`newfs_udf`) and `mke2fs` still open the device themselves; if macOS refuses them, the error explains the alternatives. Permission failures surface as
`BootKitError.permissionDenied` with numbered, actionable steps (move the app to /Applications, enter the password,
grant Full Disk Access). `AppLocation` detects apps run from Desktop/Documents/Downloads/a disk image or translocated.

## Logging

`Log.shared` fans entries out to sinks. The helper always logs at debug level (devices opened and their errno, every
`diskutil`/`hdiutil`/`authopen` invocation with exit status and output, authorization OSStatus values, 10 % progress
steps, job parameters) and streams them to the app as `JobEvent.log` (millisecond timestamps). The app writes every
entry to `~/Library/Logs/RufusAdvanced/RufusAdvanced-<date>.log` (last 20 launches kept) and shows them in the log pane
at the bottom of the main window and in the Log window; the **Verbose** toggle decides whether debug lines are shown.

## Disk pipeline (ISO mode)

macOS removes a disk's partition nodes while its whole-disk device is open for writing. `DiskPreparer` therefore does
all whole-disk writes in a single session — wipe, MBR/GPT (`PartitionTableWriter`), MBR boot code and secondary boot
record (`BootRecords`), UEFI:NTFS payload — closes the device, waits for the kernel to re-probe the new slices, and only
then formats each slice (`Formatter`: in-process `FATFormatter` for FAT/exFAT, embedded mkntfs for NTFS, newfs_udf, diskutil for HFS+/APFS, native `Ext2Formatter`, optional mke2fs),
writes the partition boot record through the slice device, mounts it `nobrowse`, copies files (`FileCopier`), applies
OS specific setup (`WindowsSetup`, `LinuxSetup`, `SyslinuxInstaller`) and finally removes macOS litter
(`.fseventsd`, `.Spotlight-V100`, AppleDouble `._` files created for the kernel's provenance xattr).

## NTFS

macOS can't write NTFS, so `Sources/CNTFS` vendors libntfs-3g and mkntfs (see `Sources/CNTFS/README-ntfs-3g.txt` for
the exact changes). `rufus_ntfs.c` replaces ntfs-3g's `unix_io` device with one that works on an already open
descriptor and a byte range (`rufusfd:<fd>:<offset>:<size>:<sector size>`), so it works on raw character devices,
authopen descriptors and disk images alike. Metadata I/O (file records, directory indexes, bitmaps) goes through a
write-back page cache (4 KB pages, 64 KB read-ahead, flushed on sync/close or past 32 MB dirty): USB flash drives are
very slow at the thousands of small synchronous writes libntfs-3g issues (a cheap stick needs ~250 ms per scattered
4 KB write). Flushes are sorted and merge dirty pages up to 256 KB apart into one request of up to 2 MB. File data
never waits in the cache: it is allocated in one piece (`ntfs_attr_truncate_solid`, falling back to on-demand
allocation) and written directly in 8 MB chunks, with partial first/last pages completed in memory so each piece
goes out in one request — otherwise every file's last page would end up as a scattered write in the final flush.
Closing reports progress (`rufus_ntfs_set_flush_progress`) and the app shows a heartbeat while the drive flushes.
mkntfs runs in-process (`mkntfs_main`).

Files can't be copied through a mount, so ISO mode on NTFS uses `NTFSWriter`: everything the OS-specific setup changes
(Windows customization, Linux config patches, extracted EFI files, uefi-md5sum loaders, md5sum.txt, autorun.inf) is
prepared in an *overlay* folder from copies of the image's files; the image tree and the overlay are then merged
(overlay wins, symlinks dereferenced) and written to the volume in one streaming pass with progress and cancellation.
Volumes are opened in ignore-case mode so lookups behave like Windows.

## macOS installer assistant

`MacInstallerLibrary` finds `Install macOS *.app` bundles in /Applications and ~/Applications and verifies them: full
installer (not a stub), payload present and complete, Apple code signature of the app and of `createinstallmedia`
(`SecStaticCodeCheckValidity` with `anchor apple`, resources not re-hashed), Rosetta when needed. The helper operation
`installMacPackage` (root, one administrator prompt) checks that the package is signed by Apple
(`pkgutil --check-signature`), runs `installer -pkg … -target / -verboseR` with live progress, hands the new app to the
user and verifies it. `MacInstallerAssistant` in the app chains download → install → verify → select, and watches
/Applications when the user prefers Apple's Installer.

## Ports from Rufus

| Rufus | RufusAdvanced |
|---|---|
| `drive.c` `CreatePartition()` | `LayoutPlanner` (1 MiB alignment, Rufus extra partitions) |
| `format.c` `WriteMBR/WriteSBR/WritePBR` | `BootRecords`, `DiskPreparer.mbrCode/pbrCode` |
| `ms-sys/inc/*.h` | `Resources/BootKit/bootrecords/*.bin` (byte identical) |
| `wue.c` `CreateUnattendXml/ApplyWindowsCustomization` | `Unattend`, `WindowsSetup` |
| `iso.c` `fix_config` | `LinuxSetup.patchConfigs` |
| `syslinux.c` + libinstaller `syslxmod.c` | `SyslinuxInstaller` + `FATVolume` |
| `badblocks.c` | `BadBlocks` |
| `dos_locale.c` | `FormatWriter.installFreeDOS` |
| `pki.c` signed downloads | `SignedFiles` (Security.framework RSA verification) |
| Fido.ps1 | `MicrosoftISO` |

## Testing without a USB stick

`hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount disk.img` creates a `/dev/diskN` owned by the
current user. The tests (and `rufusadv-helper --allow-images`) use such images as targets, so the whole pipeline —
partitioning, formatting, boot records, copying, Syslinux, persistence — runs in CI without root or hardware.
Set `E2FSCK=/path/to/e2fsck` to additionally validate the ext2/ext3 output.

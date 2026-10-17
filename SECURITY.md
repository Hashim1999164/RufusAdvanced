# Security Policy

RufusAdvanced runs a helper with administrator privileges to write to disks, so we take security seriously.

## Supported versions

Only the latest release receives security fixes.

## Reporting a vulnerability

Please **do not** open a public issue. Report privately through
[GitHub Security Advisories](https://github.com/Hashim1999164/RufusAdvanced/security/advisories/new).

Include a description, the affected version, reproduction steps and the potential impact. You will get an answer
within 7 days. Please give us a reasonable time to fix the issue before any public disclosure.

## Scope

Especially interesting:

* Anything that lets the privileged helper (`rufusadv-helper run`) write to a disk other than the one the user confirmed,
  or to an internal/system disk.
* Path or symlink tricks with the helper's event / cancel files.
* Download verification bypasses (checksum or signature checks in `Sources/BootKit/Download`).
* Injection into the generated Windows answer file or shell commands.

## Design notes

* The app is unprivileged; the helper is launched for one operation at a time via an administrator prompt.
* The helper re-validates the target disk (identifier, size, internal/system flags) before writing and refuses
  internal disks, the system disk and the drive containing the source image.
* The event file is opened with `O_NOFOLLOW` and must be a regular file owned by the invoking user.
* Version specific Syslinux/GRUB files downloaded from rufus.ie are only used after their RSA-2048 signature has been
  verified with the Rufus public key.

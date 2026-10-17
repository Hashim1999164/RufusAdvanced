# Contributing to RufusAdvanced

Thanks for helping! RufusAdvanced writes directly to disks, so we hold contributions to a high standard of care.
Please read these rules before opening a pull request.

## Ground rules

1. **Discuss first for big changes.** Open an issue (or a discussion) before working on a new feature, a new
   download source or any change to the disk engine (`Sources/BootKit/Disk`, `Sources/BootKit/Jobs`). Small fixes,
   docs and tests can go straight to a pull request.
2. **Never weaken disk safety.** Changes must keep internal and system disks unlisted and unwritable, keep the device
   identity re-check before writing, and keep the user confirmation. PRs that bypass these will be closed.
3. **Official sources only.** Download catalogs may only point to the operating system vendor's own servers or
   their official mirrors, with checksum verification whenever the vendor publishes one. No third-party re-hosts.
4. **No unexplained binaries.** Every binary file added under `Resources/` must state where it comes from (upstream
   project, version, license) in a `README`/`readme.txt` next to it, and must be GPLv3 compatible.
5. **One topic per PR**, with a clear description of *what* and *why*. Keep PRs reviewable (ideally < 500 lines).
6. **Sign your commits off** (Developer Certificate of Origin): `git commit -s`. By signing off you certify that you
   wrote the change or have the right to submit it under the project's GPLv3 license.
7. **Be kind.** Everyone must follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Workflow

1. Fork the repository and create a branch from `main`: `feature/<short-name>`, `fix/<short-name>` or `docs/<short-name>`.
2. Make your change, with tests.
3. Run the checks locally:
   ```bash
   swift build
   scripts/test.sh                       # unit + end-to-end tests on disk images (no root, no USB stick needed)
   RUFUSADV_NETWORK_TESTS=1 scripts/test.sh --filter NetworkCatalogTests   # if you touched a download catalog
   ```
4. If you changed how media is written, test on **real hardware** too (a USB stick on a real PC / Mac) and say so in the PR.
5. Open a pull request against `main` and fill in the template. CI must be green and a maintainer must approve
   before merging. PRs are squash-merged.

`main` is protected: direct pushes are disabled, pull requests need one approving review, passing CI and resolved
conversations.

## Code style

* Swift 6 toolchain, Swift 5 language mode, macOS 13 deployment target. Follow the surrounding code: 4-space indentation,
  descriptive names, small focused types.
* `BootKit` must stay UI-free (no SwiftUI/AppKit in `Sources/BootKit`) — it is shared by the app and the CLI helper.
* User-facing error messages go through `BootKitError` and must be actionable.
* Log what you do to disks with `logInfo` — the log is what users attach to bug reports.
* When porting logic from Rufus, keep a comment pointing to the original function.

## Reporting bugs

Use the *Bug report* issue template and attach the log (Log window → Save…). Remove personal information first.

## Security

Do **not** open public issues for vulnerabilities — see [SECURITY.md](SECURITY.md).

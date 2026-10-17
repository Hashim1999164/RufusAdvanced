import Foundation

/// "ISO Image mode": partition, format, extract the image's files and make the media bootable.
public enum ISOWriter {

    public static func write(_ ctx: JobContext) throws {
        guard let image = ctx.spec.image else { throw BootKitError.invalidOption("No image selected") }
        let spec = ctx.spec
        let r = ctx.reporter
        let fs = spec.fileSystem
        let isWindows = image.family == .windows
        let biosTarget = spec.targetSystem != .uefi

        // ---- Decide what we need ----
        var splitWIM = false
        if fs.isFAT && image.has4GBFile {
            let largestIsWim = image.windowsInstallImage != nil && image.largestFilePath == image.windowsInstallImage
            if isWindows && largestIsWim && spec.largeWIMStrategy == .splitWIM {
                guard ExternalTool.wimlib.isAvailable else {
                    throw BootKitError.toolMissing(tool: "wimlib-imagex", hint: "Splitting install.wim needs wimlib (brew install wimlib), or choose NTFS + UEFI:NTFS.")
                }
                splitWIM = true
            } else {
                throw BootKitError.unsupported("This image contains a file larger than 4 GB (\(image.largestFilePath)), which FAT32 cannot store. Choose NTFS (recommended) or exFAT.")
            }
        }
        let persistence = image.supportsPersistence && spec.persistenceSize > 0
        let uefiNTFS = (fs == .ntfs || fs == .exfat) && image.hasEFI && !(isWindows && spec.targetSystem == .bios)
        let wantSyslinux = biosTarget && fs.isFAT && !image.syslinuxConfigs.isEmpty && !isWindows
        let wantGrub2 = biosTarget && !wantSyslinux && image.hasGrub2BIOS && !isWindows
        if biosTarget && !isWindows && !wantSyslinux && !wantGrub2 && !image.hasReactOS && !image.hasKolibriOS && image.family == .linux {
            r.notice("This image has no BIOS boot loader usable in ISO mode: the media will boot in UEFI mode only. Use DD mode for legacy BIOS boot.")
        }
        if uefiNTFS {
            r.notice("The media uses the UEFI:NTFS bootloader. On some PCs you must disable Secure Boot to boot it\(fs == .exfat ? " (always required for exFAT)" : "").")
        }

        let projected = image.projectedSize + (persistence ? spec.persistenceSize : 0) + 16 * Units.MB
        if projected > ctx.disk.size { throw BootKitError.deviceTooSmall(needed: projected, available: ctx.disk.size) }

        r.plan([("Preparing drive", 1), ("Partitioning", 1), ("Formatting", 3), ("Creating persistence partition", persistence ? 2 : 0),
                ("Copying files", 80), ("Splitting install.wim for FAT32", splitWIM ? 25 : 0), ("Applying Windows customization", 3),
                ("Installing boot loader", 1), ("Computing MD5 checksums for UEFI media validation", spec.uefiMediaValidation ? 15 : 0),
                ("Finalizing", 2)])

        // ---- Partition & boot code ----
        var (mbr, sbr, driveID) = DiskPreparer.mbrCode(scheme: spec.partitionScheme, target: spec.targetSystem, bootSelection: .image,
                                                       image: image, useRufusMBR: spec.useRufusMBR, syslinuxInstalled: wantSyslinux)
        if !wantGrub2, sbr == .grub2Core { sbr = nil; mbr = spec.useRufusMBR ? .rufus : .windows7 }
        var plan = DiskPreparer.Plan(scheme: spec.partitionScheme, target: spec.targetSystem, fileSystem: fs, bootable: true)
        plan.mbrCode = mbr
        plan.sbr = sbr
        plan.activeDriveID = driveID
        plan.persistenceSize = persistence ? spec.persistenceSize : 0
        plan.uefiNTFS = uefiNTFS
        // GRUB 2: use the core.img matching the ISO's GRUB version when the app fetched one.
        if wantGrub2, let core = spec.grubCoreImagePath, let data = FileManager.default.contents(atPath: core) {
            plan.sbrOverride = [UInt8](data)
            logInfo("Using GRUB \(image.grub2Version ?? "") core.img (downloaded, signature verified)")
        } else if wantGrub2 {
            let embedded = (try? String(contentsOf: BootResources.url("grub2/grub2_version.h"), encoding: .utf8))
                .flatMap { text in text.range(of: #"\d+\.\d+"#, options: .regularExpression).map { String(text[$0]) } } ?? "2.14"
            if let v = image.grub2Version, !v.hasPrefix(embedded) {
                r.notice("This image uses GRUB \(v) but the embedded BIOS boot code is GRUB \(embedded). If BIOS boot fails, use DD mode.")
            }
        }
        let prep = DiskPreparer(ctx: ctx)
        let prepared = try prep.partition(plan)

        // ---- Format ----
        let label = Formatter.validLabel(spec.label.isEmpty ? image.label : spec.label, for: fs, fallbackSize: prepared.main.size)
        let pbr: BootRecords.PBRCode? = (biosTarget && !wantSyslinux) ? DiskPreparer.pbrCode(bootSelection: .image, image: image) : nil
        try prep.formatMain(prepared, fileSystem: fs, label: label, pbr: pbr)
        if persistence { try prep.formatPersistence(prepared, casper: image.usesCasper) }

        // ---- Copy ----
        let mount = try DiskImageMount(imagePath: image.path)
        defer { mount.detach() }
        guard let src = mount.primaryMountPoint else { throw BootKitError.mountFailed(image.fileName) }
        if fs == .ntfs {
            try writeNTFS(ctx, image: image, src: src, prepared: prepared, label: label, persistence: persistence)
            r.begin("Finalizing")
            if let ps = prepared.slice(.persistence) { DiskUtil.unmount(ps) }
            return
        }
        let target = try prep.mountMain(prepared)
        var skip = Set<String>()
        if splitWIM, let wim = image.windowsInstallImage { skip.insert(wim) }
        var opts = FileCopier.Options()
        opts.skip = skip
        opts.sanitizeForFAT = fs.isFAT || fs == .exfat
        opts.maxFileSize = fs.isFAT ? 0xFFFF_FFFF : .max
        let total = FileCopier.totalSize(of: src, skip: skip)
        r.begin("Copying files", detail: image.fileName, total: total)
        let copier = FileCopier(options: opts, cancel: ctx.cancel) { done, name in
            r.bytes(done, of: total, detail: name)
        }
        try copier.copyTree(from: src, to: target)
        logInfo("Copied \(Units.human(copier.bytesCopied)) to \(prepared.mainSlice)")

        // ---- OS specific setup ----
        if isWindows {
            if splitWIM, let wim = image.windowsInstallImage, let realSrc = SyslinuxInstaller.resolveCase(wim, root: src) {
                let sources = target + ((SyslinuxInstaller.resolveCase("/sources", root: target)) ?? "/sources")
                try WindowsSetup.splitWIM(source: src + realSrc, targetSources: sources, reporter: r, cancel: ctx.cancel)
            }
            WindowsSetup.win7EFIFix(root: target, image: image, scratch: ctx.scratch, cancel: ctx.cancel)
            if let c = spec.windows, !c.isEmpty {
                try WindowsSetup.applyCustomization(c, root: target, image: image, reporter: r, cancel: ctx.cancel, scratch: ctx.scratch)
            }
        } else {
            LinuxSetup.extractEFIImageIfNeeded(root: target, image: image, scratch: ctx.scratch)
            LinuxSetup.patchConfigs(root: target, image: image, usbLabel: label, persistence: persistence)
        }

        if wantSyslinux {
            r.begin("Installing boot loader", detail: "Syslinux \(image.syslinuxVersion ?? "")")
            let subdir = SyslinuxInstaller.prepareConfig(mountPoint: target, image: image)
            let files = try syslinuxFiles(for: image.syslinuxVersion, spec: spec, reporter: r)
            try SyslinuxInstaller.install(sys: files.sys, bss: files.bss, slice: prepared.mainSlice, mountPoint: target, subdir: subdir)
        }

        if spec.uefiMediaValidation && image.hasEFI {
            try MediaExtras.installUEFIMediaValidation(root: target, reporter: r, cancel: ctx.cancel)
        }
        if spec.extendedLabel && !image.hasAutorun { MediaExtras.writeAutorun(root: target, label: spec.label.isEmpty ? label : spec.label) }

        r.begin("Finalizing", detail: "Flushing data to the drive (this may take a while)")
        prep.unmount(target, slice: prepared.mainSlice)
        if let ps = prepared.slice(.persistence) { DiskUtil.unmount(ps) }
    }

    /// NTFS: prepare the modified files in an overlay, then write image + overlay through the embedded ntfs-3g.
    static func writeNTFS(_ ctx: JobContext, image: ImageReport, src: String, prepared: DiskPreparer.Prepared,
                          label: String, persistence: Bool) throws {
        let spec = ctx.spec
        let r = ctx.reporter
        let w = try NTFSWriter(source: src, scratch: ctx.scratch)
        if image.family == .windows {
            if let c = spec.windows, !c.isEmpty {
                r.begin("Applying Windows customization")
                w.stage("/sources/appraiserres.dll")
                w.stage("/setup.exe")
                if ExternalTool.wimlib.isAvailable && (c.bypassRequirements || c.silentInstall || c.useCA2023Bootloaders) {
                    w.stage("/sources/boot.wim")
                }
                if c.useCA2023Bootloaders {
                    for a in ["x64", "aa64", "ia32", "arm"] { w.stage("/efi/boot/boot\(a).efi") }
                    w.stage("/bootmgr.efi")
                }
                try WindowsSetup.applyCustomization(c, root: w.overlay, image: image, reporter: r, cancel: ctx.cancel, scratch: ctx.scratch)
            }
            WindowsSetup.win7EFIFix(root: w.overlay, image: image, scratch: ctx.scratch, cancel: ctx.cancel, sourceRoot: src)
        } else {
            w.stageLinuxConfigs(image)
            LinuxSetup.extractEFIImageIfNeeded(root: w.overlay, image: image, scratch: ctx.scratch, sourceRoot: src)
            LinuxSetup.patchConfigs(root: w.overlay, image: image, usbLabel: label, persistence: persistence)
        }
        if spec.extendedLabel && !image.hasAutorun { MediaExtras.writeAutorun(root: w.overlay, label: spec.label.isEmpty ? label : spec.label) }
        if spec.uefiMediaValidation && image.hasEFI { try w.installUEFIMediaValidation(reporter: r, cancel: ctx.cancel) }

        let dev = try RawDevice(path: "/dev/r\(prepared.mainSlice)", writable: true)
        defer { dev.close() }
        let vol = try NTFSVolume(device: dev)
        do {
            try w.write(to: vol, reporter: r, cancel: ctx.cancel)
        } catch {
            try? vol.close()
            throw error
        }
        r.begin("Finalizing", detail: "Writing NTFS metadata")
        try vol.close()
        dev.sync()
    }

    /// Choose ldlinux.sys / ldlinux.bss matching the ISO's Syslinux version.
    static func syslinuxFiles(for version: String?, spec: JobSpec, reporter: JobReporter) throws -> (sys: [UInt8], bss: [UInt8]) {
        if let dir = spec.syslinuxFilesDir,
           let sys = FileManager.default.contents(atPath: dir + "/ldlinux.sys"),
           let bss = FileManager.default.contents(atPath: dir + "/ldlinux.bss") {
            logInfo("Using downloaded Syslinux \(version ?? "") files")
            return ([UInt8](sys), [UInt8](bss))
        }
        let major = Int(version?.split(separator: ".").first ?? "6") ?? 6
        if let v = version, !SyslinuxInstaller.isBundled(v) {
            reporter.notice("This image uses Syslinux \(v), but only Syslinux \(major >= 5 ? "6.04" : "4.07") is embedded. If BIOS boot fails with an ldlinux.c32 error, use DD mode.")
        }
        return try SyslinuxInstaller.bundledFiles(major: major)
    }
}

import Foundation

/// Partitioning / boot code / formatting pipeline shared by every "format" style job.
///
/// macOS tears down a disk's partition slices while its whole-disk node is open for writing,
/// so all whole-disk writes (tables, MBR code, SBR, UEFI:NTFS payload) happen in one session,
/// after which the disk is re-probed and the slices are formatted individually.
public final class DiskPreparer {
    public struct Plan {
        public var scheme: PartitionScheme
        public var target: TargetSystem
        public var fileSystem: FileSystemType
        public var bootable: Bool
        public var mbrCode: BootRecords.MBRCode?
        public var sbr: BootRecords.SBR?
        public var sbrOverride: [UInt8]?
        public var activeDriveID: UInt8 = 0x80
        public var persistenceSize: UInt64 = 0
        public var uefiNTFS = false
        public var mainName = "Main Data Partition"
        public var mainSizeCap: UInt64?

        public init(scheme: PartitionScheme, target: TargetSystem, fileSystem: FileSystemType, bootable: Bool) {
            self.scheme = scheme
            self.target = target
            self.fileSystem = fileSystem
            self.bootable = bootable
        }
    }

    public struct Prepared {
        public var layout: PartitionLayout
        public var disk: String
        public func slice(_ role: PlannedPartition.Role) -> String? { layout.sliceIdentifier(disk: disk, role: role) }
        public var mainSlice: String { slice(.main)! }
        public var main: PlannedPartition { layout.partition(.main)! }
    }

    let ctx: JobContext
    public init(ctx: JobContext) { self.ctx = ctx }

    // MARK: Partitioning

    public func partition(_ plan: Plan) throws -> Prepared {
        let spec = ctx.spec
        ctx.reporter.begin("Preparing drive", detail: "Unmounting \(spec.disk)")
        try DiskUtil.unmountDisk(spec.disk)
        try ctx.cancel.check()

        let dev = try RawDevice(path: "/dev/r\(spec.disk)", writable: true)
        defer { dev.close() }
        guard dev.size == spec.diskSize || spec.allowVirtualDisks else { throw BootKitError.deviceChanged(spec.disk) }

        var uefiNTFSImage: Data?
        if plan.uefiNTFS { uefiNTFSImage = try BootResources.data("uefi/uefi-ntfs.img") }

        var req = LayoutPlanner.Request(diskSize: dev.size, sectorSize: dev.blockSize, scheme: plan.scheme,
                                        fileSystem: plan.fileSystem, bootable: plan.bootable, targetSystem: plan.target)
        req.oldBIOSFixes = spec.oldBIOSFixes && plan.scheme == .mbr
        req.clusterSize = spec.clusterSize
        req.persistenceSize = plan.persistenceSize
        req.uefiNTFSSize = UInt64(uefiNTFSImage?.count ?? 0)
        req.mainName = plan.mainName
        req.mainSizeCap = plan.mainSizeCap
        let layout = try LayoutPlanner.plan(req)

        ctx.reporter.begin("Partitioning", detail: "\(plan.scheme.rawValue), \(layout.partitions.count) partition(s)")
        try PartitionTableWriter.write(layout, to: dev)

        // Boot code (MBR) and secondary boot record.
        if let code = plan.mbrCode {
            try BootRecords.writeMBR(dev, code: code)
        }
        if plan.scheme == .mbr, plan.bootable, let i = layout.index(of: .main) {
            try BootRecords.setActive(dev, partitionIndex: i, driveID: plan.activeDriveID)
        }
        if let sbr = plan.sbr {
            try BootRecords.writeSBR(dev, kind: sbr, firstPartitionOffset: layout.partitions.first?.offset ?? Units.MB, override: plan.sbrOverride)
        }
        if let img = uefiNTFSImage, let p = layout.partition(.uefiNTFS) {
            logInfo("Writing UEFI:NTFS partition (\(Units.human(UInt64(img.count))))")
            let padded = [UInt8](img) + [UInt8](repeating: 0, count: Int(Units.alignUp(UInt64(img.count), UInt64(dev.blockSize))) - img.count)
            try dev.writeBytes(at: p.offset, padded)
        }
        dev.sync()
        dev.close()

        let prepared = Prepared(layout: layout, disk: spec.disk)
        let slices = layout.partitions.indices.map { "\(spec.disk)s\($0 + 1)" }
        ctx.reporter.update(fraction: nil, detail: "Waiting for the new partitions…", force: true)
        try DiskUtil.rescan(spec.disk, expecting: slices, cancel: ctx.cancel)
        // DiskArbitration may auto-mount the fresh (blank) partitions; release them.
        try DiskUtil.unmountDisk(spec.disk)
        return prepared
    }

    // MARK: Formatting

    public func formatMain(_ p: Prepared, fileSystem: FileSystemType, label: String, pbr: BootRecords.PBRCode?) throws {
        let main = p.main
        ctx.reporter.begin("Formatting", detail: "\(fileSystem.shortName) on \(p.mainSlice) (\(Units.human(main.size)))")
        let slice = p.mainSlice
        var r = Formatter.Request(disk: p.disk, slice: slice, fileSystem: fileSystem, label: label,
                                  clusterSize: ctx.spec.clusterSize, partitionOffset: main.offset, partitionSize: main.size)
        r.quick = ctx.spec.quickFormat
        try Formatter.format(r, cancel: ctx.cancel) { [weak self] f, detail in
            self?.ctx.reporter.update(fraction: f >= 0 ? f : nil, detail: detail)
        }
        if let pbr, [.fat16, .fat32, .ntfs].contains(fileSystem) {
            let sliceDev = try RawDevice(path: "/dev/r\(slice)", writable: true)
            defer { sliceDev.close() }
            try BootRecords.writePBR(sliceDev, partitionOffset: 0, fileSystem: fileSystem, code: pbr)
            if fileSystem == .ntfs {
                // Keep the backup boot sector (last sector of the volume) identical to the primary one.
                let bs = Int(sliceDev.blockSize)
                let primary = try sliceDev.readBytes(at: 0, count: bs)
                let sectors = LE.get64(primary, 0x28)
                let backup = sectors * UInt64(bs)
                if sectors > 0, backup + UInt64(bs) <= sliceDev.size {
                    try sliceDev.writeBytes(at: backup, primary)
                }
            }
            sliceDev.sync()
        }
    }

    public func formatPersistence(_ p: Prepared, casper: Bool) throws {
        guard let slice = p.slice(.persistence), let part = p.layout.partition(.persistence) else { return }
        let label = casper ? "casper-rw" : "persistence"
        ctx.reporter.begin("Creating persistence partition", detail: "\(label), \(Units.human(part.size))")
        var r = Formatter.Request(disk: p.disk, slice: slice, fileSystem: .ext3, label: label, clusterSize: 0,
                                  partitionOffset: part.offset, partitionSize: part.size)
        if !casper { r.extFiles = [.init(name: "persistence.conf", contents: Data("/ union\n".utf8))] }
        try Formatter.format(r, cancel: ctx.cancel)
    }

    // MARK: Mounting

    public func mountMain(_ p: Prepared) throws -> String {
        let mp = ctx.scratch + "/target"
        try DiskUtil.waitForSlices([p.mainSlice], cancel: ctx.cancel)
        var lastError: Error?
        for attempt in 0..<4 {
            do {
                let m = try DiskUtil.mount(p.mainSlice, at: mp)
                DiskUtil.preventMacMetadata(at: m)
                return m
            } catch {
                lastError = error
                logDebug("Mount attempt \(attempt + 1) failed: \(error.userMessage)")
                usleep(800_000)
            }
        }
        throw lastError ?? BootKitError.mountFailed(p.mainSlice)
    }

    public func unmount(_ mountPoint: String, slice: String) {
        DiskUtil.finalizeVolume(at: mountPoint)
        DiskUtil.unmount(slice)
        if DiskUtil.mountPointOf(slice) != nil { DiskUtil.unmount(slice, force: true) }
    }

    // MARK: Boot code selection (port of Rufus' WriteMBR / WriteSBR decision tree)

    public static func mbrCode(scheme: PartitionScheme, target: TargetSystem, bootSelection: BootSelection,
                               image: ImageReport?, useRufusMBR: Bool, syslinuxInstalled: Bool) -> (BootRecords.MBRCode?, BootRecords.SBR?, UInt8) {
        let bootable = bootSelection != .nonBootable
        if scheme == .gpt {
            return bootable ? (.rufusProtective, .protectiveMessage, 0x80) : (nil, nil, 0x80)
        }
        let img = bootSelection == .image ? image : nil
        let needsMasquerade = img?.isWinPE == true
        let driveID: UInt8 = needsMasquerade ? 0x81 : 0x80
        if !bootable || target == .uefi { return (.zero, nil, driveID) }
        if img?.family == .windows { return (useRufusMBR || needsMasquerade ? .rufus : .windows7, nil, driveID) }
        if bootSelection == .syslinux4 || bootSelection == .syslinux6 || syslinuxInstalled { return (.syslinux, nil, driveID) }
        if bootSelection == .grub2 || (img?.hasGrub2BIOS == true && img?.syslinuxConfigs.isEmpty == true) {
            return (.grub2, .grub2Core, driveID)
        }
        if img?.hasReactOS == true { return (.reactos, nil, driveID) }
        if img?.hasKolibriOS == true { return (.kolibri, nil, driveID) }
        return (useRufusMBR || needsMasquerade ? .rufus : .windows7, nil, driveID)
    }

    public static func pbrCode(bootSelection: BootSelection, image: ImageReport?) -> BootRecords.PBRCode {
        switch bootSelection {
        case .freeDOS: return .freeDOS
        case .image:
            guard let image else { return .standard }
            if image.hasKolibriOS { return .kolibri }
            if image.hasReactOS { return .reactOS }
            if image.hasBootmgr { return .windowsPE }
            if image.isWinPE { return .windowsNT }
            return .standard
        default: return .standard
        }
    }
}

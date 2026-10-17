import Foundation

/// Creates file systems on partitions.
public enum Formatter {
    public struct Request {
        public var disk: String                 // disk4
        public var slice: String                // disk4s1
        public var fileSystem: FileSystemType
        public var label: String
        public var clusterSize: UInt32          // 0 = default
        public var partitionOffset: UInt64
        public var partitionSize: UInt64
        public var quick: Bool = true
        public var extFiles: [Ext2Formatter.File] = []

        public init(disk: String, slice: String, fileSystem: FileSystemType, label: String, clusterSize: UInt32,
                    partitionOffset: UInt64, partitionSize: UInt64) {
            self.disk = disk
            self.slice = slice
            self.fileSystem = fileSystem
            self.label = label
            self.clusterSize = clusterSize
            self.partitionOffset = partitionOffset
            self.partitionSize = partitionSize
        }
    }

    /// Make a label valid for the target file system (port of Rufus' ToValidLabel).
    public static func validLabel(_ label: String, for fs: FileSystemType, fallbackSize: UInt64 = 0) -> String {
        var out = ""
        if fs.isFAT || fs == .exfat {
            let unauthorized = Set("*?,;:/\\|+=<>[]\"")
            for ch in label {
                if fs.isFAT {
                    if unauthorized.contains(ch) { continue }
                    if !ch.isASCII { out.append("_"); continue }
                }
                if ch == "\t" || ch == "." { out.append("_"); continue }
                out.append(fs.isFAT ? Character(ch.uppercased()) : ch)
            }
        } else {
            out = label
        }
        out = String(out.prefix(fs.maxLabelLength))
        if fs.isFAT {
            // Trim UTF-8 overflow is impossible here (ASCII only). Avoid labels made of underscores.
            let underscores = out.filter { $0 == "_" }.count
            if !out.isEmpty && out.count < 2 * underscores, fallbackSize > 0 {
                out = Units.driveSizeLabel(fallbackSize).replacingOccurrences(of: ".", with: "_")
            }
        }
        if fs.isExt {
            while out.utf8.count > 16 { out.removeLast() }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Format `r.slice`. The slice device is only held open for our own writes (slow format,
    /// native ext2/3) and is closed before external tools run: newfs_exfat needs exclusive access.
    public static func format(_ r: Request, cancel: CancellationToken?, progress: ((Double, String) -> Void)? = nil) throws {
        let rawSlice = "/dev/r\(r.slice)"
        let blockSlice = "/dev/\(r.slice)"
        var ss: UInt64 = 512
        if let probe = try? RawDevice(path: rawSlice, writable: false) { ss = UInt64(probe.blockSize); probe.close() }
        let hidden = r.partitionOffset / ss
        let label = validLabel(r.label, for: r.fileSystem, fallbackSize: r.partitionSize)

        if !r.quick {
            // "Slow" format: zero the whole partition first (also exposes write errors).
            let device = try RawDevice(path: rawSlice, writable: true)
            try zeroFill(device, offset: 0, size: min(r.partitionSize, device.size), cancel: cancel) { f in
                progress?(f, "Zeroing partition (slow format)")
            }
            device.close()
        }
        progress?(-1, "Creating \(r.fileSystem.shortName) file system…")
        logInfo("Formatting \(r.slice) as \(r.fileSystem.rawValue) with label '\(label)'\(r.clusterSize > 0 ? ", cluster \(r.clusterSize)" : "")")

        switch r.fileSystem {
        case .fat16, .fat32, .exfat:
            // In-process formatters: they work on authopen descriptors (newfs_* can't open the device).
            let dev = try RawDevice(path: rawSlice, writable: true)
            defer { dev.close() }
            let opts = FATFormatter.Options(label: label, clusterSize: r.clusterSize, hiddenSectors: hidden)
            if r.fileSystem == .exfat {
                try FATFormatter.formatExFAT(dev, offset: 0, size: min(r.partitionSize, dev.size), options: opts, cancel: cancel)
            } else {
                try FATFormatter.formatFAT(dev, offset: 0, size: min(r.partitionSize, dev.size), fat32: r.fileSystem == .fat32, options: opts, cancel: cancel)
            }
        case .udf:
            var args = ["-r", "2.01", "-b", String(max(UInt64(r.clusterSize), ss)), "--wipefs", "no"]
            if !label.isEmpty { args += ["-v", label] }
            args.append(rawSlice)
            try Shell.check("/sbin/newfs_udf", args, cancel: cancel)
        case .hfsPlus:
            try Shell.check("/usr/sbin/diskutil", ["eraseVolume", "JHFS+", label.isEmpty ? "Untitled" : label, r.slice], cancel: cancel)
        case .apfs:
            try Shell.check("/usr/sbin/diskutil", ["eraseVolume", "APFS", label.isEmpty ? "Untitled" : label, r.slice], cancel: cancel)
        case .ntfs:
            guard let mkntfs = ExternalTool.mkntfs.path else {
                throw BootKitError.toolMissing(tool: "mkntfs", hint: "Install it with: brew install \(ExternalTool.mkntfs.brewFormula)")
            }
            var args = ["-Q", "-F", "-p", String(hidden), "-H", "255", "-S", "63", "-s", String(ss)]
            if !label.isEmpty { args += ["-L", label] }
            if r.clusterSize > 0 { args += ["-c", String(r.clusterSize)] }
            args.append(blockSlice)
            try Shell.check(mkntfs, args, cancel: cancel)
        case .ext2, .ext3, .ext4:
            if let mke2fs = ExternalTool.mke2fs.path {
                var args = ["-F", "-t", r.fileSystem.rawValue, "-m", "0"]
                if !label.isEmpty { args += ["-L", label] }
                if r.clusterSize > 0 { args += ["-b", String(r.clusterSize)] }
                var seedDir: String?
                if !r.extFiles.isEmpty {
                    let dir = NSTemporaryDirectory() + "rufusadv-ext-\(UUID().uuidString)"
                    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                    for f in r.extFiles { try f.contents.write(to: URL(fileURLWithPath: dir + "/" + f.name)) }
                    args += ["-d", dir]
                    seedDir = dir
                }
                args.append(blockSlice)
                defer { if let seedDir { try? FileManager.default.removeItem(atPath: seedDir) } }
                try Shell.check(mke2fs, args, cancel: cancel)
            } else {
                let device = try RawDevice(path: rawSlice, writable: true)
                defer { device.close() }
                if r.fileSystem == .ext4 {
                    logWarning("mke2fs (e2fsprogs) is not installed: creating ext3 instead of ext4. Install it with: brew install e2fsprogs")
                }
                var fmt = Ext2Formatter(label: label, journal: r.fileSystem != .ext2, partitionSize: r.partitionSize,
                                        blockSize: r.clusterSize > 0 ? r.clusterSize : nil)
                fmt.files = r.extFiles
                try fmt.format(device, offset: 0, size: min(r.partitionSize, device.size), cancel: cancel)
            }
        }
        progress?(1, "Created \(r.fileSystem.shortName) file system")
    }

    /// Zero a region of the device with progress.
    public static func zeroFill(_ dev: RawDevice, offset: UInt64, size: UInt64, cancel: CancellationToken?, progress: (Double) -> Void) throws {
        let chunk = 4 * Int(Units.MB)
        let buf = RawDevice.alignedBuffer(chunk)
        defer { free(buf) }
        var done: UInt64 = 0
        var last = Date.distantPast
        while done < size {
            try cancel?.check()
            let n = Int(min(UInt64(chunk), size - done))
            let aligned = Int(Units.alignDown(UInt64(n), UInt64(dev.blockSize)))
            if aligned > 0 { try dev.write(at: offset + done, from: buf, count: aligned) }
            done += UInt64(n)
            if Date().timeIntervalSince(last) > 0.2 { last = Date(); progress(Double(done) / Double(size)) }
        }
        progress(1)
    }
}

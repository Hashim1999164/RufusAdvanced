import Foundation

/// In-process FAT12/16/32 and exFAT formatters (Microsoft "fatgen103" and exFAT specifications).
///
/// They write through a `RawDevice`, so they also work on devices opened with authopen, where
/// newfs_msdos / newfs_exfat (which open the device themselves) are refused by macOS.
public enum FATFormatter {

    public struct Options {
        public var label: String
        public var clusterSize: UInt32          // bytes, 0 = default
        public var hiddenSectors: UInt64        // partition start LBA on the whole disk
        public var volumeID: UInt32 = UInt32.random(in: 1...UInt32.max)
        public init(label: String, clusterSize: UInt32 = 0, hiddenSectors: UInt64) {
            self.label = label
            self.clusterSize = clusterSize
            self.hiddenSectors = hiddenSectors
        }
    }

    enum FATKind { case fat12, fat16, fat32 }

    // MARK: - FAT12 / FAT16 / FAT32

    /// Microsoft's default cluster sizes.
    static func defaultFATCluster(_ size: UInt64, fat32: Bool) -> UInt32 {
        let mb = size / Units.MB
        if fat32 {
            switch mb {
            case ..<260: return 512
            case ..<8192: return 4096
            case ..<16384: return 8192
            case ..<32768: return 16384
            default: return 32768
            }
        }
        switch mb {
        case ..<16: return 1024
        case ..<128: return 2048
        case ..<256: return 4096
        case ..<512: return 8192
        case ..<1024: return 16384
        case ..<2048: return 32768
        default: return 65536
        }
    }

    /// Format `size` bytes at `offset` of `dev` as FAT. `fat32 == false` picks FAT16 (or FAT12 if tiny).
    public static func formatFAT(_ dev: RawDevice, offset: UInt64, size: UInt64, fat32: Bool, options: Options, cancel: CancellationToken? = nil) throws {
        let bps = UInt64(dev.blockSize)
        let totalSectors = size / bps
        var clusterBytes = UInt64(options.clusterSize > 0 ? options.clusterSize : defaultFATCluster(size, fat32: fat32))
        clusterBytes = max(clusterBytes, bps)
        var spc = clusterBytes / bps
        guard spc <= 128, spc & (spc - 1) == 0 else { throw BootKitError.invalidOption("Unsupported FAT cluster size \(clusterBytes)") }

        let numFATs: UInt64 = 2
        var kind: FATKind = fat32 ? .fat32 : .fat16
        var rootEntries: UInt64 = kind == .fat32 ? 0 : 512
        var reserved: UInt64 = kind == .fat32 ? 32 : 1
        var fatSectors: UInt64 = 0
        var clusters: UInt64 = 0

        func compute() {
            let rootDirSectors = (rootEntries * 32 + bps - 1) / bps
            // fatgen103 FAT size computation, then align the data region to the cluster size.
            for _ in 0..<4 {
                let tmp1 = totalSectors - (reserved + rootDirSectors)
                var tmp2 = (256 * spc) + numFATs
                if kind == .fat32 { tmp2 /= 2 }
                if kind == .fat12 {
                    let entriesPerSector = bps * 2 / 3
                    fatSectors = ((tmp1 / spc) + 2 + entriesPerSector - 1) / entriesPerSector
                } else {
                    fatSectors = (tmp1 + tmp2 - 1) / tmp2
                }
                let meta = reserved + numFATs * fatSectors + rootDirSectors
                let rem = meta % spc
                if rem != 0 { reserved += spc - rem } else { break }
            }
            let dataSectors = totalSectors - (reserved + numFATs * fatSectors + rootDirSectors)
            clusters = dataSectors / spc
        }
        compute()
        if kind != .fat32 && clusters < 4085 {
            kind = .fat12
            rootEntries = 224 * max(1, min(2, bps / 512))
            reserved = 1
            compute()
        }
        // Validate the FAT type against its cluster count range.
        switch kind {
        case .fat32:
            if clusters < 65525 {
                if options.clusterSize == 0 && spc > 1 { spc = 1; reserved = 32; compute() }
                guard clusters >= 65525 else {
                    throw BootKitError.invalidOption("The partition is too small for FAT32 (\(Units.human(size))). Use FAT instead.")
                }
            }
        case .fat16:
            guard clusters <= 65524 else {
                throw BootKitError.invalidOption("The cluster size is too small for FAT16 on \(Units.human(size)). Use FAT32 or a bigger cluster size.")
            }
        case .fat12:
            guard clusters >= 1 else { throw BootKitError.deviceTooSmall(needed: 64 * Units.KB, available: size) }
        }
        let rootDirSectors = (rootEntries * 32 + bps - 1) / bps

        // Boot sector
        var bs = [UInt8](repeating: 0, count: Int(bps))
        bs[0] = 0xEB; bs[1] = kind == .fat32 ? 0x58 : 0x3C; bs[2] = 0x90
        bs.replaceSubrange(3..<11, with: Array("MSDOS5.0".utf8))
        LE.put16(&bs, 11, UInt16(bps))
        bs[13] = UInt8(spc)
        LE.put16(&bs, 14, UInt16(reserved))
        bs[16] = UInt8(numFATs)
        LE.put16(&bs, 17, UInt16(rootEntries))
        if totalSectors < 65536 && kind != .fat32 { LE.put16(&bs, 19, UInt16(totalSectors)) } else { LE.put32(&bs, 32, UInt32(min(totalSectors, UInt64(UInt32.max)))) }
        bs[21] = 0xF8
        LE.put16(&bs, 24, 63)
        LE.put16(&bs, 26, 255)
        LE.put32(&bs, 28, UInt32(truncatingIfNeeded: options.hiddenSectors))
        let label = volumeLabel11(options.label)
        if kind == .fat32 {
            LE.put32(&bs, 36, UInt32(fatSectors))
            LE.put32(&bs, 44, 2)          // root cluster
            LE.put16(&bs, 48, 1)          // FSInfo
            LE.put16(&bs, 50, 6)          // backup boot sector
            bs[64] = 0x80
            bs[66] = 0x29
            LE.put32(&bs, 67, options.volumeID)
            bs.replaceSubrange(71..<82, with: label)
            bs.replaceSubrange(82..<90, with: Array("FAT32   ".utf8))
        } else {
            LE.put16(&bs, 22, UInt16(fatSectors))
            bs[36] = 0x80
            bs[38] = 0x29
            LE.put32(&bs, 39, options.volumeID)
            bs.replaceSubrange(43..<54, with: label)
            bs.replaceSubrange(54..<62, with: Array((kind == .fat12 ? "FAT12   " : "FAT16   ").utf8))
        }
        bs[510] = 0x55; bs[511] = 0xAA

        // Zero the metadata area (reserved sectors, FATs, FAT16 root directory, FAT32 root cluster).
        let metaSectors = reserved + numFATs * fatSectors + rootDirSectors + (kind == .fat32 ? spc : 0)
        try dev.zero(at: offset, count: metaSectors * bps)
        try cancel?.check()

        // Standard (non system) boot code so the volume is valid even before a PBR is installed.
        try dev.writeBytes(at: offset, bs)
        if kind == .fat32 {
            var fsinfo = [UInt8](repeating: 0, count: Int(bps))
            LE.put32(&fsinfo, 0, 0x4161_5252)
            LE.put32(&fsinfo, 484, 0x6141_7272)
            LE.put32(&fsinfo, 488, UInt32(clusters - 1))
            LE.put32(&fsinfo, 492, 3)
            LE.put32(&fsinfo, 508, 0xAA55_0000)
            var third = [UInt8](repeating: 0, count: Int(bps))
            third[510] = 0x55; third[511] = 0xAA
            for base in [UInt64(0), 6] {
                if base != 0 { try dev.writeBytes(at: offset + base * bps, bs) }
                try dev.writeBytes(at: offset + (base + 1) * bps, fsinfo)
                try dev.writeBytes(at: offset + (base + 2) * bps, third)
            }
        }

        // FAT tables
        var fatStart: [UInt8]
        switch kind {
        case .fat32:
            fatStart = [UInt8](repeating: 0, count: 12)
            LE.put32(&fatStart, 0, 0x0FFF_FFF8)
            LE.put32(&fatStart, 4, 0x0FFF_FFFF)
            LE.put32(&fatStart, 8, 0x0FFF_FFFF)   // root directory: end of chain
        case .fat16:
            fatStart = [0xF8, 0xFF, 0xFF, 0xFF]
        case .fat12:
            fatStart = [0xF8, 0xFF, 0xFF]
        }
        for i in 0..<numFATs {
            try dev.writeBytes(at: offset + (reserved + i * fatSectors) * bps, fatStart)
        }

        // Volume label entry in the root directory.
        if !options.label.trimmingCharacters(in: .whitespaces).isEmpty {
            let rootOffset = kind == .fat32 ? offset + (reserved + numFATs * fatSectors) * bps : offset + (reserved + numFATs * fatSectors) * bps
            var e = [UInt8](repeating: 0, count: 32)
            e.replaceSubrange(0..<11, with: label)
            e[11] = 0x08
            let (date, time) = dosDateTime(Date())
            LE.put16(&e, 22, time)
            LE.put16(&e, 24, date)
            try dev.writeBytes(at: rootOffset, e)
        }
        dev.sync()
        logInfo("Created \(kind == .fat32 ? "FAT32" : (kind == .fat16 ? "FAT16" : "FAT12")) file system: \(clusters) clusters of \(Units.human(spc * bps)), label '\(String(decoding: label, as: UTF8.self).trimmingCharacters(in: .whitespaces))'")
    }

    static func volumeLabel11(_ label: String) -> [UInt8] {
        let ascii = label.uppercased().unicodeScalars.map { $0.isASCII ? UInt8($0.value) : UInt8(ascii: "_") }
        if ascii.isEmpty { return Array("NO NAME    ".utf8) }
        return Array(ascii.prefix(11)) + [UInt8](repeating: 0x20, count: max(0, 11 - ascii.count))
    }

    static func dosDateTime(_ d: Date) -> (UInt16, UInt16) {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        // Split into typed sub-expressions: the one-liner is too slow for the type checker.
        let year: Int = max(0, min(127, (c.year ?? 1980) - 1980))
        let month: Int = c.month ?? 1
        let day: Int = c.day ?? 1
        let hour: Int = c.hour ?? 0
        let minute: Int = c.minute ?? 0
        let second: Int = (c.second ?? 0) / 2
        let dateBits: Int = (year << 9) | (month << 5) | day
        let timeBits: Int = (hour << 11) | (minute << 5) | second
        return (UInt16(truncatingIfNeeded: dateBits), UInt16(truncatingIfNeeded: timeBits))
    }

    // MARK: - exFAT

    static func defaultExFATCluster(_ size: UInt64) -> UInt32 {
        if size <= 256 * Units.MB { return 4096 }
        if size <= 32 * Units.GB { return 32768 }
        return 131072
    }

    static func exfatChecksum(_ bytes: [UInt8], skip: Set<Int> = []) -> UInt32 {
        var c: UInt32 = 0
        for (i, b) in bytes.enumerated() where !skip.contains(i) {
            c = ((c & 1) != 0 ? 0x8000_0000 : 0) &+ (c >> 1) &+ UInt32(b)
        }
        return c
    }

    public static func formatExFAT(_ dev: RawDevice, offset: UInt64, size: UInt64, options: Options, cancel: CancellationToken? = nil) throws {
        let bps = UInt64(dev.blockSize)
        let bpsShift = UInt8(log2(Double(bps)))
        let volumeSectors = size / bps
        let clusterBytes = UInt64(max(options.clusterSize > 0 ? options.clusterSize : defaultExFATCluster(size), UInt32(bps)))
        let spc = clusterBytes / bps
        guard spc & (spc - 1) == 0, clusterBytes <= 32 * Units.MB else { throw BootKitError.invalidOption("Unsupported exFAT cluster size") }
        let spcShift = UInt8(log2(Double(spc)))

        // Layout: boot regions (24 sectors), FAT aligned to 1 MiB (or 128 sectors on tiny volumes), heap aligned to the cluster.
        let fatOffset: UInt64 = size >= 64 * Units.MB ? max(Units.MB / bps, 24) : max(128 * 512 / bps, 24)
        var clusterCount: UInt64 = 0
        var fatLength: UInt64 = 0
        var heapOffset: UInt64 = 0
        for _ in 0..<4 {
            fatLength = Units.alignUp(((clusterCount + 2) * 4 + bps - 1) / bps, spc)
            heapOffset = Units.alignUp(fatOffset + fatLength, spc)
            clusterCount = (volumeSectors - heapOffset) / spc
        }
        fatLength = Units.alignUp(((clusterCount + 2) * 4 + bps - 1) / bps, spc)
        heapOffset = Units.alignUp(fatOffset + fatLength, spc)
        clusterCount = (volumeSectors - heapOffset) / spc
        guard clusterCount > 16 else { throw BootKitError.deviceTooSmall(needed: Units.MB, available: size) }

        // Cluster heap content: bitmap, up-case table, root directory.
        let upcase = [UInt8](try BootResources.data("exfat-upcase.bin"))
        let bitmapBytes = (clusterCount + 7) / 8
        let bitmapClusters = (bitmapBytes + clusterBytes - 1) / clusterBytes
        let upcaseClusters = (UInt64(upcase.count) + clusterBytes - 1) / clusterBytes
        let bitmapCluster: UInt64 = 2
        let upcaseCluster = bitmapCluster + bitmapClusters
        let rootCluster = upcaseCluster + upcaseClusters
        let usedClusters = bitmapClusters + upcaseClusters + 1

        // Boot sector
        var bs = [UInt8](repeating: 0, count: Int(bps))
        bs[0] = 0xEB; bs[1] = 0x76; bs[2] = 0x90
        bs.replaceSubrange(3..<11, with: Array("EXFAT   ".utf8))
        LE.put64(&bs, 64, options.hiddenSectors)
        LE.put64(&bs, 72, volumeSectors)
        LE.put32(&bs, 80, UInt32(fatOffset))
        LE.put32(&bs, 84, UInt32(fatLength))
        LE.put32(&bs, 88, UInt32(heapOffset))
        LE.put32(&bs, 92, UInt32(clusterCount))
        LE.put32(&bs, 96, UInt32(rootCluster))
        LE.put32(&bs, 100, options.volumeID)
        LE.put16(&bs, 104, 0x0100)
        bs[108] = bpsShift
        bs[109] = spcShift
        bs[110] = 1
        bs[111] = 0x80
        bs[112] = UInt8(min(100, usedClusters * 100 / clusterCount))
        // Boot code: "hlt; jmp $" so firmware never executes garbage.
        bs[120] = 0xF4; bs[121] = 0xEB; bs[122] = 0xFD
        bs[510] = 0x55; bs[511] = 0xAA

        var region = bs
        for _ in 1...8 {
            var ext = [UInt8](repeating: 0, count: Int(bps))
            LE.put32(&ext, Int(bps) - 4, 0xAA55_0000)
            region += ext
        }
        region += [UInt8](repeating: 0, count: Int(bps))  // OEM parameters
        region += [UInt8](repeating: 0, count: Int(bps))  // reserved
        let sum = exfatChecksum(region, skip: [106, 107, 112])
        var checksumSector = [UInt8](repeating: 0, count: Int(bps))
        for i in stride(from: 0, to: Int(bps), by: 4) { LE.put32(&checksumSector, i, sum) }
        region += checksumSector

        try dev.zero(at: offset, count: fatOffset * bps + fatLength * bps)
        try cancel?.check()
        try dev.writeBytes(at: offset, region)                       // main boot region
        try dev.writeBytes(at: offset + 12 * bps, region)            // backup boot region

        // FAT: media + end markers, and the chains of our three system objects.
        var fat = [UInt8](repeating: 0, count: Int((rootCluster + 1) * 4))
        LE.put32(&fat, 0, 0xFFFF_FFF8)
        LE.put32(&fat, 4, 0xFFFF_FFFF)
        func chain(_ first: UInt64, _ count: UInt64) {
            for k in 0..<count {
                let c = first + k
                LE.put32(&fat, Int(c * 4), k == count - 1 ? 0xFFFF_FFFF : UInt32(c + 1))
            }
        }
        chain(bitmapCluster, bitmapClusters)
        chain(upcaseCluster, upcaseClusters)
        chain(rootCluster, 1)
        try dev.writeBytes(at: offset + fatOffset * bps, fat)

        func clusterOffset(_ c: UInt64) -> UInt64 { offset + (heapOffset + (c - 2) * spc) * bps }

        // Allocation bitmap
        try dev.zero(at: clusterOffset(bitmapCluster), count: bitmapClusters * clusterBytes)
        var bitmap = [UInt8](repeating: 0, count: Int((usedClusters + 7) / 8))
        for k in 0..<Int(usedClusters) { bitmap[k / 8] |= UInt8(1 << (k % 8)) }
        try dev.writeBytes(at: clusterOffset(bitmapCluster), bitmap)

        // Up-case table
        try dev.writeBytes(at: clusterOffset(upcaseCluster), upcase + [UInt8](repeating: 0, count: Int(upcaseClusters * clusterBytes) - upcase.count))

        // Root directory
        var root = [UInt8](repeating: 0, count: Int(clusterBytes))
        var e = 0
        let labelUnits = Array(options.label.utf16.prefix(11))
        if !labelUnits.isEmpty {
            root[e] = 0x83
            root[e + 1] = UInt8(labelUnits.count)
            for (i, u) in labelUnits.enumerated() { LE.put16(&root, e + 2 + 2 * i, u) }
            e += 32
        }
        root[e] = 0x81
        LE.put32(&root, e + 20, UInt32(bitmapCluster))
        LE.put64(&root, e + 24, bitmapBytes)
        e += 32
        root[e] = 0x82
        LE.put32(&root, e + 4, exfatChecksum(upcase))
        LE.put32(&root, e + 20, UInt32(upcaseCluster))
        LE.put64(&root, e + 24, UInt64(upcase.count))
        try dev.writeBytes(at: clusterOffset(rootCluster), root)
        dev.sync()
        logInfo("Created exFAT file system: \(clusterCount) clusters of \(Units.human(clusterBytes)), label '\(options.label)'")
    }
}

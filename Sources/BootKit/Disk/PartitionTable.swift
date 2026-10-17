import Foundation

public enum PartitionScheme: String, Codable, CaseIterable, Sendable, Identifiable {
    case mbr = "MBR"
    case gpt = "GPT"
    public var id: String { rawValue }
}

/// Well known GPT partition type GUIDs.
public enum GPTType {
    public static let basicData = UUID(uuidString: "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7")!
    public static let efiSystem = UUID(uuidString: "C12A7328-F81F-11D2-BA4B-00A0C93EC93B")!
    public static let msReserved = UUID(uuidString: "E3C9E316-0B5C-4DB8-817D-F92DF00215AE")!
    public static let linuxData = UUID(uuidString: "0FC63DAF-8483-4772-8E79-3D69D8477DE4")!
    public static let appleHFS = UUID(uuidString: "48465300-0000-11AA-AA11-00306543ECAC")!
    public static let appleAPFS = UUID(uuidString: "7C3457EF-0000-11AA-AA11-00306543ECAC")!
    public static let biosBoot = UUID(uuidString: "21686148-6449-6E6F-744E-656564454649")!

    /// GPT attribute: tell Windows not to assign a drive letter.
    public static let attrNoDriveLetter: UInt64 = 0x8000_0000_0000_0000
}

/// One partition in a planned layout.
public struct PlannedPartition: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable {
        case main, esp, msr, persistence, uefiNTFS, compat, windowsData
    }
    public var role: Role
    public var name: String
    public var offset: UInt64
    public var size: UInt64
    public var mbrType: UInt8
    public var gptType: UUID
    public var bootable: Bool
    public var gptAttributes: UInt64
    public var uniqueGUID: UUID

    public init(role: Role, name: String, offset: UInt64 = 0, size: UInt64 = 0, mbrType: UInt8 = 0x0c,
                gptType: UUID = GPTType.basicData, bootable: Bool = false, gptAttributes: UInt64 = 0) {
        self.role = role
        self.name = name
        self.offset = offset
        self.size = size
        self.mbrType = mbrType
        self.gptType = gptType
        self.bootable = bootable
        self.gptAttributes = gptAttributes
        self.uniqueGUID = UUID()
    }

    public var end: UInt64 { offset + size }
}

/// A complete partition layout ready to be written to a disk.
public struct PartitionLayout: Codable, Sendable {
    public var scheme: PartitionScheme
    public var diskSize: UInt64
    public var sectorSize: UInt32
    public var partitions: [PlannedPartition]
    public var mbrSignature: UInt32
    public var diskGUID: UUID

    public init(scheme: PartitionScheme, diskSize: UInt64, sectorSize: UInt32, partitions: [PlannedPartition], mbrSignature: UInt32? = nil) {
        self.scheme = scheme
        self.diskSize = diskSize
        self.sectorSize = sectorSize
        self.partitions = partitions
        self.mbrSignature = mbrSignature ?? UInt32.random(in: 1...UInt32.max)
        self.diskGUID = UUID()
    }

    public func index(of role: PlannedPartition.Role) -> Int? {
        partitions.firstIndex { $0.role == role }
    }

    public func partition(_ role: PlannedPartition.Role) -> PlannedPartition? {
        partitions.first { $0.role == role }
    }

    /// The macOS slice identifier for a partition ("disk4s2").
    public func sliceIdentifier(disk: String, role: PlannedPartition.Role) -> String? {
        guard let i = index(of: role) else { return nil }
        return "\(disk)s\(i + 1)"
    }

    public var summary: String {
        partitions.enumerated().map { i, p in
            "  #\(i + 1) \(p.name): offset \(p.offset) (\(Units.human(p.offset))), size \(Units.human(p.size))"
        }.joined(separator: "\n")
    }
}

// MARK: - Binary encoding

enum LE {
    static func put16(_ b: inout [UInt8], _ off: Int, _ v: UInt16) {
        b[off] = UInt8(v & 0xff); b[off + 1] = UInt8(v >> 8)
    }
    static func put32(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
        for i in 0..<4 { b[off + i] = UInt8((v >> (8 * UInt32(i))) & 0xff) }
    }
    static func put64(_ b: inout [UInt8], _ off: Int, _ v: UInt64) {
        for i in 0..<8 { b[off + i] = UInt8((v >> (8 * UInt64(i))) & 0xff) }
    }
    static func get16(_ b: [UInt8], _ off: Int) -> UInt16 {
        UInt16(b[off]) | UInt16(b[off + 1]) << 8
    }
    static func get32(_ b: [UInt8], _ off: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(b[off + $1]) << (8 * UInt32($1)) }
    }
    static func get64(_ b: [UInt8], _ off: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[off + $1]) << (8 * UInt64($1)) }
    }
}

extension UUID {
    /// GPT stores GUIDs in "mixed endian": the first three fields are little endian.
    var gptBytes: [UInt8] {
        let u = uuid
        let b = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        return [b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6]] + Array(b[8...])
    }

    init(gptBytes b: [UInt8]) {
        let r = [b[3], b[2], b[1], b[0], b[5], b[4], b[7], b[6]] + Array(b[8..<16])
        self = UUID(uuid: (r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10], r[11], r[12], r[13], r[14], r[15]))
    }
}

public enum PartitionTableWriter {
    static let gptEntryCount = 128
    static let gptEntrySize = 128

    /// CHS tuple for an LBA using the conventional 255 heads / 63 sectors geometry.
    static func chs(_ lba: UInt64) -> [UInt8] {
        let spt: UInt64 = 63, heads: UInt64 = 255
        let cyl = lba / (spt * heads)
        if cyl > 1023 { return [0xFE, 0xFF, 0xFF] }
        let head = (lba / spt) % heads
        let sector = (lba % spt) + 1
        return [UInt8(head), UInt8((sector & 0x3f) | ((cyl >> 2) & 0xc0)), UInt8(cyl & 0xff)]
    }

    static func mbrEntry(status: UInt8, type: UInt8, startLBA: UInt64, sectors: UInt64) -> [UInt8] {
        var e = [UInt8](repeating: 0, count: 16)
        e[0] = status
        let s = chs(startLBA), t = chs(startLBA + sectors - 1)
        e[1] = s[0]; e[2] = s[1]; e[3] = s[2]
        e[4] = type
        e[5] = t[0]; e[6] = t[1]; e[7] = t[2]
        LE.put32(&e, 8, UInt32(min(startLBA, 0xFFFF_FFFF)))
        LE.put32(&e, 12, UInt32(min(sectors, 0xFFFF_FFFF)))
        return e
    }

    /// Build sector 0 (MBR or protective MBR) with a zeroed boot code area.
    public static func buildMBR(_ layout: PartitionLayout) -> [UInt8] {
        var mbr = [UInt8](repeating: 0, count: 512)
        let ss = UInt64(layout.sectorSize)
        LE.put32(&mbr, 440, layout.mbrSignature)
        switch layout.scheme {
        case .mbr:
            for (i, p) in layout.partitions.prefix(4).enumerated() {
                let e = mbrEntry(status: p.bootable ? 0x80 : 0x00, type: p.mbrType,
                                 startLBA: p.offset / ss, sectors: p.size / ss)
                mbr.replaceSubrange((446 + 16 * i)..<(446 + 16 * i + 16), with: e)
            }
        case .gpt:
            let total = layout.diskSize / ss
            var e = [UInt8](repeating: 0, count: 16)
            e[1] = 0x00; e[2] = 0x02; e[3] = 0x00
            e[4] = 0xEE
            e[5] = 0xFF; e[6] = 0xFF; e[7] = 0xFF
            LE.put32(&e, 8, 1)
            LE.put32(&e, 12, UInt32(min(total - 1, 0xFFFF_FFFF)))
            mbr.replaceSubrange(446..<462, with: e)
        }
        mbr[510] = 0x55
        mbr[511] = 0xAA
        return mbr
    }

    /// Build the GPT entry array (128 x 128 bytes).
    static func buildGPTEntries(_ layout: PartitionLayout) -> [UInt8] {
        var a = [UInt8](repeating: 0, count: gptEntryCount * gptEntrySize)
        let ss = UInt64(layout.sectorSize)
        for (i, p) in layout.partitions.enumerated() {
            let o = i * gptEntrySize
            a.replaceSubrange(o..<(o + 16), with: p.gptType.gptBytes)
            a.replaceSubrange((o + 16)..<(o + 32), with: p.uniqueGUID.gptBytes)
            LE.put64(&a, o + 32, p.offset / ss)
            LE.put64(&a, o + 40, (p.offset + p.size) / ss - 1)
            LE.put64(&a, o + 48, p.gptAttributes)
            let name = Array(p.name.utf16.prefix(36))
            for (j, c) in name.enumerated() { LE.put16(&a, o + 56 + 2 * j, c) }
        }
        return a
    }

    static func buildGPTHeader(_ layout: PartitionLayout, entries: [UInt8], primary: Bool) -> [UInt8] {
        let ss = UInt64(layout.sectorSize)
        let total = layout.diskSize / ss
        let entrySectors = UInt64(entries.count) / ss
        var h = [UInt8](repeating: 0, count: Int(ss))
        h.replaceSubrange(0..<8, with: Array("EFI PART".utf8))
        LE.put32(&h, 8, 0x0001_0000)
        LE.put32(&h, 12, 92)
        let myLBA: UInt64 = primary ? 1 : total - 1
        let altLBA: UInt64 = primary ? total - 1 : 1
        LE.put64(&h, 24, myLBA)
        LE.put64(&h, 32, altLBA)
        LE.put64(&h, 40, 2 + entrySectors)                 // first usable
        LE.put64(&h, 48, total - 2 - entrySectors)         // last usable
        h.replaceSubrange(56..<72, with: layout.diskGUID.gptBytes)
        LE.put64(&h, 72, primary ? 2 : total - 1 - entrySectors)
        LE.put32(&h, 80, UInt32(gptEntryCount))
        LE.put32(&h, 84, UInt32(gptEntrySize))
        LE.put32(&h, 88, CRC32.checksum(entries))
        LE.put32(&h, 16, CRC32.checksum(h[0..<92]))
        return h
    }

    /// Wipe old structures and write the layout's partition tables.
    public static func write(_ layout: PartitionLayout, to dev: RawDevice) throws {
        let ss = UInt64(dev.blockSize)
        precondition(ss == UInt64(layout.sectorSize))
        // Clear the first and last MiB: old MBR/GPT, old backup GPT, stale boot sectors.
        let clear = min(Units.MB, dev.size / 4)
        try dev.zero(at: 0, count: clear)
        try dev.zero(at: Units.alignDown(dev.size - clear, ss), count: clear)
        // Clear the start of every partition so no stale file system gets detected.
        for p in layout.partitions {
            try dev.zero(at: p.offset, count: min(p.size, Units.MB))
        }

        try dev.writeBytes(at: 0, buildMBR(layout))
        if layout.scheme == .gpt {
            let entries = buildGPTEntries(layout)
            let entrySectors = UInt64(entries.count) / ss
            let total = dev.size / ss
            try dev.writeBytes(at: 2 * ss, entries)
            try dev.writeBytes(at: 1 * ss, buildGPTHeader(layout, entries: entries, primary: true))
            try dev.writeBytes(at: (total - 1 - entrySectors) * ss, entries)
            try dev.writeBytes(at: (total - 1) * ss, buildGPTHeader(layout, entries: entries, primary: false))
        }
        dev.sync()
        logInfo("Wrote \(layout.scheme.rawValue) partition table:\n\(layout.summary)")
    }

    // MARK: Reading (verification, tests)

    public struct ReadEntry: Equatable, Sendable {
        public var startLBA: UInt64
        public var sectors: UInt64
        public var mbrType: UInt8?
        public var gptType: UUID?
        public var name: String?
        public var bootable: Bool
    }

    public static func read(from dev: RawDevice) throws -> (PartitionScheme?, [ReadEntry]) {
        let ss = UInt64(dev.blockSize)
        let mbr = try dev.readBytes(at: 0, count: 512)
        guard mbr[510] == 0x55, mbr[511] == 0xAA else { return (nil, []) }
        if mbr[446 + 4] == 0xEE {
            let hdr = try dev.readBytes(at: ss, count: 92)
            guard Array(hdr[0..<8]) == Array("EFI PART".utf8) else { return (nil, []) }
            let entriesLBA = LE.get64(hdr, 72)
            let count = Int(LE.get32(hdr, 80))
            let size = Int(LE.get32(hdr, 84))
            let entries = try dev.readBytes(at: entriesLBA * ss, count: count * size)
            var out: [ReadEntry] = []
            for i in 0..<count {
                let o = i * size
                let t = Array(entries[o..<(o + 16)])
                if t.allSatisfy({ $0 == 0 }) { continue }
                var nameUnits: [UInt16] = []
                for j in 0..<36 {
                    let c = LE.get16(entries, o + 56 + 2 * j)
                    if c == 0 { break }
                    nameUnits.append(c)
                }
                let first = LE.get64(entries, o + 32), last = LE.get64(entries, o + 40)
                out.append(ReadEntry(startLBA: first, sectors: last - first + 1, mbrType: nil,
                                     gptType: UUID(gptBytes: t), name: String(decoding: nameUnits, as: UTF16.self),
                                     bootable: false))
            }
            return (.gpt, out)
        }
        var out: [ReadEntry] = []
        for i in 0..<4 {
            let o = 446 + 16 * i
            let type = mbr[o + 4]
            if type == 0 { continue }
            out.append(ReadEntry(startLBA: UInt64(LE.get32(mbr, o + 8)), sectors: UInt64(LE.get32(mbr, o + 12)),
                                 mbrType: type, gptType: nil, name: nil, bootable: mbr[o] == 0x80))
        }
        return (.mbr, out)
    }
}

import Foundation

/// Minimal read-only FAT12/16/32 reader: enough to locate a root directory file and map its
/// sectors (needed to install Syslinux, which loads ldlinux.sys by raw sector numbers).
public final class FATVolume {
    let dev: RawDevice
    public let bytesPerSector: UInt32
    public let sectorsPerCluster: UInt32
    let reservedSectors: UInt32
    let fatCount: UInt32
    let rootEntries: UInt32
    let fatSize: UInt32
    let totalSectors: UInt32
    let rootCluster: UInt32
    public let fatBits: Int
    let firstDataSector: UInt32
    let rootDirSector: UInt32
    let rootDirSectors: UInt32

    public init(device: RawDevice) throws {
        dev = device
        let bs = try device.readBytes(at: 0, count: 512)
        guard bs[510] == 0x55, bs[511] == 0xAA else { throw BootKitError.generic("No FAT boot sector found") }
        bytesPerSector = UInt32(LE.get16(bs, 0x0B))
        sectorsPerCluster = UInt32(bs[0x0D])
        reservedSectors = UInt32(LE.get16(bs, 0x0E))
        fatCount = UInt32(bs[0x10])
        rootEntries = UInt32(LE.get16(bs, 0x11))
        let fat16Size = UInt32(LE.get16(bs, 0x16))
        let tot16 = UInt32(LE.get16(bs, 0x13))
        totalSectors = tot16 != 0 ? tot16 : LE.get32(bs, 0x20)
        fatSize = fat16Size != 0 ? fat16Size : LE.get32(bs, 0x24)
        rootCluster = fat16Size == 0 ? LE.get32(bs, 0x2C) : 0
        guard bytesPerSector >= 512, sectorsPerCluster > 0, fatCount > 0 else { throw BootKitError.generic("Invalid FAT BPB") }
        rootDirSectors = (rootEntries * 32 + bytesPerSector - 1) / bytesPerSector
        rootDirSector = reservedSectors + fatCount * fatSize
        firstDataSector = rootDirSector + rootDirSectors
        let clusters = (totalSectors - firstDataSector) / sectorsPerCluster
        fatBits = fat16Size == 0 ? 32 : (clusters < 4085 ? 12 : 16)
    }

    public func clusterToSector(_ c: UInt32) -> UInt64 {
        UInt64(firstDataSector) + UInt64(c - 2) * UInt64(sectorsPerCluster)
    }

    func nextCluster(_ c: UInt32) throws -> UInt32? {
        let fatOffset: UInt64
        switch fatBits {
        case 32: fatOffset = UInt64(c) * 4
        case 16: fatOffset = UInt64(c) * 2
        default: fatOffset = UInt64(c) + UInt64(c) / 2
        }
        let byteOff = UInt64(reservedSectors) * UInt64(bytesPerSector) + fatOffset
        let b = try dev.readBytes(at: byteOff, count: 4)
        let v: UInt32
        switch fatBits {
        case 32:
            v = LE.get32(b, 0) & 0x0FFF_FFFF
            return v >= 0x0FFF_FFF8 || v < 2 ? nil : v
        case 16:
            v = UInt32(LE.get16(b, 0))
            return v >= 0xFFF8 || v < 2 ? nil : v
        default:
            let raw = UInt32(LE.get16(b, 0))
            v = (c & 1) != 0 ? raw >> 4 : raw & 0x0FFF
            return v >= 0x0FF8 || v < 2 ? nil : v
        }
    }

    /// Sectors (relative to the volume start) of the root directory.
    func rootDirectorySectors() throws -> [UInt64] {
        if fatBits == 32 { return try sectors(ofChainStarting: rootCluster) }
        return (0..<UInt64(rootDirSectors)).map { UInt64(rootDirSector) + $0 }
    }

    /// All sectors of a cluster chain.
    public func sectors(ofChainStarting first: UInt32) throws -> [UInt64] {
        var out: [UInt64] = []
        var c: UInt32? = first
        var guardCount = 0
        while let cl = c {
            let s = clusterToSector(cl)
            for i in 0..<UInt64(sectorsPerCluster) { out.append(s + i) }
            c = try nextCluster(cl)
            guardCount += 1
            if guardCount > 4_000_000 { throw BootKitError.generic("FAT chain loop detected") }
        }
        return out
    }

    /// Find the first cluster of an 8.3 file in the root directory (name like "LDLINUX SYS").
    public func findRootFile(shortName: String) throws -> (cluster: UInt32, size: UInt32)? {
        let target = Array(shortName.uppercased().utf8)
        precondition(target.count == 11)
        for s in try rootDirectorySectors() {
            let sec = try dev.readBytes(at: s * UInt64(bytesPerSector), count: Int(bytesPerSector))
            for o in stride(from: 0, to: sec.count, by: 32) {
                let first = sec[o]
                if first == 0x00 { return nil }
                if first == 0xE5 || sec[o + 11] == 0x0F { continue }
                if Array(sec[o..<(o + 11)]) == target {
                    let hi = fatBits == 32 ? UInt32(LE.get16(sec, o + 0x14)) << 16 : 0
                    let cluster = hi | UInt32(LE.get16(sec, o + 0x1A))
                    return (cluster, LE.get32(sec, o + 0x1C))
                }
            }
        }
        return nil
    }
}

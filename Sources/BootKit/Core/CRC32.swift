import Foundation

/// IEEE 802.3 CRC32 (as used by GPT and zip).
public struct CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private var value: UInt32 = 0xFFFF_FFFF

    public init() {}

    public mutating func update<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        var v = value
        for b in bytes { v = CRC32.table[Int((v ^ UInt32(b)) & 0xFF)] ^ (v >> 8) }
        value = v
    }

    public mutating func update(_ ptr: UnsafeRawBufferPointer) {
        var v = value
        for b in ptr { v = CRC32.table[Int((v ^ UInt32(b)) & 0xFF)] ^ (v >> 8) }
        value = v
    }

    public var checksum: UInt32 { value ^ 0xFFFF_FFFF }

    public static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var c = CRC32()
        c.update(bytes)
        return c.checksum
    }
}

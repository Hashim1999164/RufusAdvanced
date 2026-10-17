import Foundation

/// Destructive write/read surface test (port of Rufus' badblocks "write mode" test).
/// Also detects counterfeit drives that report more capacity than they really have.
public enum BadBlocks {
    public struct Report: Sendable {
        public var badBlocks: [UInt64] = []   // byte offsets of bad sectors
        public var readErrors = 0
        public var writeErrors = 0
        public var corruptionErrors = 0
        public var total: Int { badBlocks.count }
    }

    /// Fill `buf` with the repeating little-endian bytes of `pattern` (Rufus pattern_fill()).
    static func fill(_ buf: UnsafeMutableRawPointer, count: Int, pattern: UInt32) {
        var bytes: [UInt8] = []
        var p = pattern
        repeat { bytes.append(UInt8(p & 0xff)); p >>= 8 } while p != 0
        let b = buf.assumingMemoryBound(to: UInt8.self)
        if bytes.count == 1 { memset(buf, Int32(bytes[0]), count); return }
        for i in 0..<count { b[i] = bytes[i % bytes.count] }
    }

    public static func run(disk: String, options: BadBlocksOptions, reporter: JobReporter, cancel: CancellationToken) throws -> Report {
        try DiskUtil.unmountDisk(disk)
        let dev = try RawDevice(path: "/dev/r\(disk)", writable: true)
        defer { dev.close() }
        let patterns = options.patternSet.patterns
        let chunk = 4 * Int(Units.MB)
        let bs = Int(dev.blockSize)
        let wbuf = RawDevice.alignedBuffer(chunk)
        let rbuf = RawDevice.alignedBuffer(chunk)
        defer { free(wbuf); free(rbuf) }
        var report = Report()
        var bad = Set<UInt64>()

        for (pi, pattern) in patterns.enumerated() {
            let label = "Pass \(pi + 1)/\(patterns.count), pattern 0x\(String(pattern, radix: 16, uppercase: true))"
            fill(wbuf, count: chunk, pattern: pattern)
            // Write pass
            reporter.begin("Checking for bad blocks", detail: "\(label): writing", total: dev.size)
            var pos: UInt64 = 0
            while pos < dev.size {
                try cancel.check()
                let n = Int(min(UInt64(chunk), dev.size - pos))
                do { try dev.write(at: pos, from: wbuf, count: n, retries: 1) }
                catch {
                    // Isolate failing sectors.
                    for s in stride(from: 0, to: n, by: bs) {
                        if (try? dev.write(at: pos + UInt64(s), from: wbuf + s, count: bs, retries: 0)) == nil {
                            if bad.insert(pos + UInt64(s)).inserted { report.writeErrors += 1 }
                        }
                    }
                }
                pos += UInt64(n)
                reporter.bytes(pos, of: dev.size, detail: "\(label): writing · \(bad.count) bad")
            }
            dev.sync()
            // Read / compare pass
            reporter.begin("Checking for bad blocks", detail: "\(label): reading", total: dev.size)
            pos = 0
            while pos < dev.size {
                try cancel.check()
                let n = Int(min(UInt64(chunk), dev.size - pos))
                do {
                    try dev.read(at: pos, into: rbuf, count: n)
                    if memcmp(rbuf, wbuf, n) != 0 {
                        for s in stride(from: 0, to: n, by: bs) where memcmp(rbuf + s, wbuf + s, bs) != 0 {
                            if bad.insert(pos + UInt64(s)).inserted { report.corruptionErrors += 1 }
                        }
                    }
                } catch {
                    for s in stride(from: 0, to: n, by: bs) {
                        if (try? dev.read(at: pos + UInt64(s), into: rbuf + s, count: bs)) == nil {
                            if bad.insert(pos + UInt64(s)).inserted { report.readErrors += 1 }
                        }
                    }
                }
                pos += UInt64(n)
                reporter.bytes(pos, of: dev.size, detail: "\(label): reading · \(bad.count) bad")
            }
            if bad.count > 1000 { break }
        }
        report.badBlocks = bad.sorted()
        logInfo("Bad blocks check completed: \(report.total) bad block(s) found (\(report.readErrors)/\(report.writeErrors)/\(report.corruptionErrors) read/write/corruption errors)")
        if let first = report.badBlocks.first, report.corruptionErrors > 0 {
            logWarning("First corrupted sector at \(Units.human(first)) – if most of the drive above this point fails, the drive is likely FAKE (its real capacity is about \(Units.human(first))).")
        }
        return report
    }
}

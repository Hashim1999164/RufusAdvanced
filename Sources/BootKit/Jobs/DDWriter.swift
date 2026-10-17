import Foundation
import CryptoKit

/// Raw ("DD") image writer with optional read-back verification.
public enum DDWriter {
    public static func write(_ ctx: JobContext) throws {
        guard let image = ctx.spec.image else { throw BootKitError.invalidOption("No image selected") }
        let r = ctx.reporter
        r.plan([("Preparing drive", 1), ("Converting", 4), ("Writing image", 90), ("Verifying", ctx.spec.verifyWrite ? 60 : 0), ("Finalizing", 1)])
        r.begin("Preparing drive", detail: "Unmounting \(ctx.spec.disk)")
        try DiskUtil.unmountDisk(ctx.spec.disk)

        let source = try ImageSourceFactory.open(image, scratch: ctx.scratch, reporter: r, cancel: ctx.cancel)
        defer { source.close() }
        let dev = try RawDevice(path: "/dev/r\(ctx.spec.disk)", writable: true)
        defer { dev.close() }
        if let raw = source.rawSize, raw > dev.size {
            throw BootKitError.deviceTooSmall(needed: raw, available: dev.size)
        }

        // Clear the end of the disk so a stale backup GPT can't confuse firmware/OSes.
        try dev.zero(at: Units.alignDown(dev.size - min(Units.MB, dev.size / 2), UInt64(dev.blockSize)), count: Units.MB)

        r.begin("Writing image", detail: image.fileName, total: source.progressTotal)
        let chunk = 4 * Int(Units.MB)
        let buf = RawDevice.alignedBuffer(chunk)
        defer { free(buf) }
        var offset: UInt64 = 0
        var hasher = SHA256()
        let bs = Int(dev.blockSize)
        while true {
            try ctx.cancel.check()
            var filled = 0
            while filled < chunk {
                let n = try source.read(into: buf + filled, count: chunk - filled)
                if n == 0 { break }
                filled += n
            }
            if filled == 0 { break }
            if offset + UInt64(filled) > dev.size { throw BootKitError.deviceTooSmall(needed: offset + UInt64(filled), available: dev.size) }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: filled))
            // Pad a short final chunk to the sector size (Rufus: sector_write workaround).
            let padded = (filled + bs - 1) / bs * bs
            if padded > filled { memset(buf + filled, 0, padded - filled) }
            try dev.write(at: offset, from: buf, count: padded)
            offset += UInt64(filled)
            r.bytes(source.progressPosition, of: source.progressTotal, detail: "\(Units.human(offset)) written")
            if filled < chunk { break }
        }
        dev.sync()
        let written = offset
        logInfo("Wrote \(Units.human(written)) to \(ctx.spec.disk)")
        let digest = hasher.finalize().hex

        if ctx.spec.verifyWrite {
            r.begin("Verifying", detail: "Reading back \(Units.human(written))", total: written)
            var check = SHA256()
            var pos: UInt64 = 0
            while pos < written {
                try ctx.cancel.check()
                let n = Int(min(UInt64(chunk), written - pos))
                let aligned = (n + bs - 1) / bs * bs
                try dev.read(at: pos, into: buf, count: aligned)
                check.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
                pos += UInt64(n)
                r.bytes(pos, of: written)
            }
            let back = check.finalize().hex
            guard back == digest else { throw BootKitError.verificationFailed("the data read back from the drive differs from the image (SHA-256 \(back) ≠ \(digest)). The drive may be faulty or fake.") }
            r.notice("Verification passed: the drive content matches the image (SHA-256 \(digest.prefix(16))…).")
        }
        r.begin("Finalizing")
        dev.close()
    }
}

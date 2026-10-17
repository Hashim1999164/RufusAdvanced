import Foundation

/// Errors raised by the BootKit engine. Messages are written for end users.
public enum BootKitError: Error, LocalizedError, Sendable {
    case cancelled
    case deviceNotFound(String)
    case deviceChanged(String)
    case deviceIsInternal(String)
    case deviceTooSmall(needed: UInt64, available: UInt64)
    case openFailed(String, Int32)
    case readFailed(String, Int32)
    case writeFailed(String, Int32)
    case ioctlFailed(String, Int32)
    case commandFailed(String, Int32, String)
    case toolMissing(tool: String, hint: String)
    case unsupportedImage(String)
    case unsupported(String)
    case invalidOption(String)
    case partitionNotFound(String)
    case mountFailed(String)
    case verificationFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case network(String)
    case badBlocks(Int)
    case generic(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: return "The operation was cancelled."
        case .deviceNotFound(let d): return "The device \(d) could not be found. Was it unplugged?"
        case .deviceChanged(let d): return "The device \(d) changed since it was selected. Please re-select it."
        case .deviceIsInternal(let d): return "\(d) is an internal disk. Refusing to touch it."
        case .deviceTooSmall(let n, let a):
            return "The target device is too small: \(Units.human(n)) needed but only \(Units.human(a)) available."
        case .openFailed(let p, let e): return "Could not open \(p): \(String(cString: strerror(e)))"
        case .readFailed(let p, let e): return "Read error on \(p): \(String(cString: strerror(e)))"
        case .writeFailed(let p, let e): return "Write error on \(p): \(String(cString: strerror(e)))"
        case .ioctlFailed(let p, let e): return "Device control failed (\(p)): \(String(cString: strerror(e)))"
        case .commandFailed(let c, let code, let out):
            let tail = out.split(separator: "\n").suffix(4).joined(separator: "\n")
            return "\(c) failed (exit code \(code)).\(tail.isEmpty ? "" : "\n\(tail)")"
        case .toolMissing(let t, let h): return "The external tool '\(t)' is required but was not found. \(h)"
        case .unsupportedImage(let s): return "Unsupported image: \(s)"
        case .unsupported(let s): return s
        case .invalidOption(let s): return "Invalid option: \(s)"
        case .partitionNotFound(let s): return "Partition \(s) did not appear after partitioning."
        case .mountFailed(let s): return "Could not mount \(s)."
        case .verificationFailed(let s): return "Verification failed: \(s)"
        case .checksumMismatch(let e, let a): return "Checksum mismatch.\nExpected: \(e)\nActual:   \(a)"
        case .network(let s): return "Network error: \(s)"
        case .badBlocks(let n): return "\(n) bad block(s) were found on the device. It is not safe to use."
        case .generic(let s): return s
        }
    }
}

public extension Error {
    var userMessage: String {
        (self as? LocalizedError)?.errorDescription ?? String(describing: self)
    }
}

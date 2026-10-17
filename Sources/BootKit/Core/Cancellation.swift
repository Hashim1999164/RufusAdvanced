import Foundation

/// Cooperative cancellation. Either flipped in-process, or by the presence of a
/// "cancel file" (used to cancel the privileged helper from the unprivileged app).
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    private let cancelFile: String?
    private var lastFileCheck = Date.distantPast

    public init(cancelFile: String? = nil) {
        self.cancelFile = cancelFile
    }

    public func cancel() {
        lock.lock(); flag = true; lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        if flag { return true }
        if let cancelFile {
            // Avoid hammering the file system in tight I/O loops.
            let now = Date()
            if now.timeIntervalSince(lastFileCheck) > 0.25 {
                lastFileCheck = now
                if FileManager.default.fileExists(atPath: cancelFile) { flag = true }
            }
        }
        return flag
    }

    public func check() throws {
        if isCancelled { throw BootKitError.cancelled }
    }
}

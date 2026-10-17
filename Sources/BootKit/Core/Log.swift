import Foundation

/// Severity of a log line.
public enum LogLevel: String, Codable, Sendable {
    case debug, info, notice, warning, error
}

/// A single log entry, shared between the app and the privileged helper.
public struct LogEntry: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var date: Date
    public var level: LogLevel
    public var message: String

    public init(date: Date = Date(), level: LogLevel, message: String) {
        self.date = date
        self.level = level
        self.message = message
    }

    public var formatted: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let prefix: String
        switch level {
        case .debug: prefix = "  "
        case .info: prefix = ""
        case .notice: prefix = "• "
        case .warning: prefix = "WARNING: "
        case .error: prefix = "ERROR: "
        }
        return "[\(f.string(from: date))] \(prefix)\(message)"
    }
}

/// Process-wide logger. Sinks receive every entry (UI, event stream, stderr, file).
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    public typealias Sink = (LogEntry) -> Void
    private var sinks: [UUID: Sink] = [:]
    private let lock = NSLock()
    public var verbose = false

    private init() {}

    @discardableResult
    public func addSink(_ sink: @escaping Sink) -> UUID {
        lock.lock(); defer { lock.unlock() }
        let id = UUID()
        sinks[id] = sink
        return id
    }

    public func removeSink(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        sinks[id] = nil
    }

    public func log(_ level: LogLevel, _ message: String) {
        if level == .debug && !verbose { return }
        let entry = LogEntry(level: level, message: message)
        lock.lock()
        let current = Array(sinks.values)
        lock.unlock()
        for s in current { s(entry) }
    }
}

@inline(__always) public func logDebug(_ m: @autoclosure () -> String) { if Log.shared.verbose { Log.shared.log(.debug, m()) } }
@inline(__always) public func logInfo(_ m: String) { Log.shared.log(.info, m) }
@inline(__always) public func logNotice(_ m: String) { Log.shared.log(.notice, m) }
@inline(__always) public func logWarning(_ m: String) { Log.shared.log(.warning, m) }
@inline(__always) public func logError(_ m: String) { Log.shared.log(.error, m) }

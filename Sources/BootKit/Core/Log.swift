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

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let fileFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS ZZZZZ"
        return f
    }()

    private var prefix: String {
        switch level {
        case .debug: return "  "
        case .info: return ""
        case .notice: return "• "
        case .warning: return "WARNING: "
        case .error: return "ERROR: "
        }
    }

    /// "[21:34:05.123] message" — used by the log views, Copy and Save.
    public var formatted: String {
        "[\(LogEntry.timeFormatter.string(from: date))] \(prefix)\(message)"
    }

    /// Full date, time zone and level — used for the persistent log file.
    public var fileLine: String {
        let lvl = level.rawValue.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)
        return "\(LogEntry.fileFormatter.string(from: date)) \(lvl) \(message)"
    }
}

/// Persistent log in ~/Library/Logs/RufusAdvanced (one file per app launch, old files pruned).
public final class LogFile: @unchecked Sendable {
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RufusAdvanced", isDirectory: true)
    }

    public let url: URL
    private let handle: FileHandle?
    private let queue = DispatchQueue(label: "rufusadvanced.logfile")

    public init(prefix: String = "RufusAdvanced", keep: Int = 20) {
        let fm = FileManager.default
        let dir = LogFile.directory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        url = dir.appendingPathComponent("\(prefix)-\(f.string(from: Date())).log")
        fm.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
        // Keep only the most recent files.
        if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "log" && $0.lastPathComponent.hasPrefix(prefix + "-") })
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }), files.count > keep {
            for old in files.dropFirst(keep) { try? fm.removeItem(at: old) }
        }
    }

    deinit { try? handle?.close() }

    public func write(_ entry: LogEntry) {
        let line = entry.fileLine + "\n"
        queue.async { [handle] in
            try? handle?.write(contentsOf: Data(line.utf8))
        }
    }

    /// Wait until everything queued so far has been written.
    public func flush() {
        queue.sync { try? handle?.synchronize() }
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

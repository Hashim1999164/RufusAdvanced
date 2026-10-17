import Foundation

/// Result of running an external command.
public struct ShellResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var combined: String { stdout + (stderr.isEmpty ? "" : "\n" + stderr) }
    public var ok: Bool { status == 0 }
}

/// Thin, cancellable wrapper around `Process`.
public enum Shell {
    /// PATH used for every child process, so Homebrew tools are found even when
    /// launched from Finder or as root through an authorization prompt.
    public static let searchPath = [
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/local/sbin",
        "/opt/homebrew/opt/e2fsprogs/sbin", "/usr/local/opt/e2fsprogs/sbin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/libexec",
    ].joined(separator: ":")

    public static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = searchPath
        env["LC_ALL"] = "C"
        env["LANG"] = "C"
        return env
    }

    /// Run a command to completion. `onLine` receives stdout+stderr lines as they arrive
    /// (split on both \n and \r so tools printing progress with \r are handled).
    @discardableResult
    public static func run(_ executable: String,
                           _ arguments: [String],
                           input: Data? = nil,
                           cancel: CancellationToken? = nil,
                           onLine: ((String) -> Void)? = nil,
                           logCommand: Bool = true) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = Pipe()
        process.standardInput = input != nil ? inPipe : FileHandle.nullDevice

        if logCommand {
            logDebug("$ \(executable) \(arguments.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " "))")
        }

        let collector = OutputCollector(onLine: onLine)
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { collector.append(d, err: false) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { collector.append(d, err: true) }
        }

        do {
            try process.run()
        } catch {
            logDebug("  could not launch \(executable): \(error.localizedDescription)")
            throw BootKitError.commandFailed((executable as NSString).lastPathComponent, -1, error.localizedDescription)
        }

        if let input {
            inPipe.fileHandleForWriting.write(input)
            try? inPipe.fileHandleForWriting.close()
        }

        var cancelled = false
        while process.isRunning {
            if let cancel, cancel.isCancelled, !cancelled {
                cancelled = true
                process.interrupt()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if process.isRunning { process.terminate() }
                }
            }
            usleep(50_000)
        }
        process.waitUntilExit()
        // Drain anything left in the pipes.
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        if let rest = try? outPipe.fileHandleForReading.readToEnd(), !rest.isEmpty { collector.append(rest, err: false) }
        if let rest = try? errPipe.fileHandleForReading.readToEnd(), !rest.isEmpty { collector.append(rest, err: true) }
        collector.flush()

        if cancelled { throw BootKitError.cancelled }
        let result = ShellResult(status: process.terminationStatus, stdout: collector.out, stderr: collector.err)
        if logCommand && Log.shared.verbose {
            let name = (executable as NSString).lastPathComponent
            logDebug("  \(name) exited with status \(result.status)")
            // Failed commands: everything they printed (bounded). Successful ones: a short tail.
            let limit = result.ok ? 6 : 40
            for (stream, text) in [("stdout", result.stdout), ("stderr", result.stderr)] {
                let lines = text.split(whereSeparator: { $0.isNewline })
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard !lines.isEmpty else { continue }
                if lines.count > limit { logDebug("  [\(name) \(stream)] … \(lines.count - limit) earlier line(s) omitted") }
                for l in lines.suffix(limit) { logDebug("  [\(name) \(stream)] \(String(l.prefix(400)))") }
            }
        }
        return result
    }

    /// Run and throw if the exit status is not zero.
    @discardableResult
    public static func check(_ executable: String,
                             _ arguments: [String],
                             input: Data? = nil,
                             cancel: CancellationToken? = nil,
                             onLine: ((String) -> Void)? = nil) throws -> ShellResult {
        let r = try run(executable, arguments, input: input, cancel: cancel, onLine: onLine)
        if !r.ok {
            throw BootKitError.commandFailed((executable as NSString).lastPathComponent, r.status, r.combined)
        }
        return r
    }

    /// Locate an executable by name in our search path.
    public static func which(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in searchPath.split(separator: ":") {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var out = ""
    private(set) var err = ""
    private var pending = ""
    private let onLine: ((String) -> Void)?

    init(onLine: ((String) -> Void)?) { self.onLine = onLine }

    func append(_ data: Data, err isErr: Bool) {
        let s = String(decoding: data, as: UTF8.self)
        lock.lock()
        if isErr { err += s } else { out += s }
        var lines: [String] = []
        if onLine != nil {
            pending += s
            while let r = pending.rangeOfCharacter(from: CharacterSet(charactersIn: "\r\n")) {
                let line = String(pending[pending.startIndex..<r.lowerBound])
                pending.removeSubrange(pending.startIndex..<r.upperBound)
                if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
            }
        }
        lock.unlock()
        for l in lines { onLine?(l) }
    }

    func flush() {
        lock.lock()
        let rest = pending
        pending = ""
        lock.unlock()
        if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onLine?(rest) }
    }
}

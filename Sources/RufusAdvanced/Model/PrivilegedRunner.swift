import Foundation
import AppKit
import BootKit

/// Launches the disk helper (with administrator rights when needed) and streams its events.
final class PrivilegedRunner: @unchecked Sendable {
    enum RunError: LocalizedError {
        case helperMissing
        case authorizationCancelled
        case launchFailed(String)
        var errorDescription: String? {
            switch self {
            case .helperMissing: return "The rufusadv-helper tool is missing from the application bundle."
            case .authorizationCancelled: return "Administrator authorization was cancelled."
            case .launchFailed(let s): return "Could not start the disk helper: \(s)"
            }
        }
    }

    private let jobDir: String
    private let eventsPath: String
    private let cancelPath: String
    private var offset: UInt64 = 0
    private var buffer = Data()
    private var timer: DispatchSourceTimer?
    private var helperPID: Int32?
    private var finished = false
    private var lastEvent = Date()
    private var directProcess: Process?
    private let onEvent: (JobEvent) -> Void

    init(onEvent: @escaping (JobEvent) -> Void) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!.path + "/RufusAdvanced/jobs"
        jobDir = base + "/" + UUID().uuidString
        eventsPath = jobDir + "/events.jsonl"
        cancelPath = jobDir + "/cancel"
        self.onEvent = onEvent
    }

    static var helperPath: String? {
        let candidates = [
            Bundle.main.url(forAuxiliaryExecutable: "rufusadv-helper")?.path,
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("rufusadv-helper").path,
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Start the job. Throws if the helper could not be launched.
    func start(_ spec: JobSpec) throws {
        guard let helper = Self.helperPath else { throw RunError.helperMissing }
        let fm = FileManager.default
        try fm.createDirectory(atPath: jobDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard fm.createFile(atPath: eventsPath, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw RunError.launchFailed("cannot create \(eventsPath)")
        }
        let job = try spec.encoded()
        let args = ["run", "--job", job, "--events", eventsPath, "--cancel", cancelPath]

        // Disk images and other user-owned devices don't need administrator rights.
        let needsAdmin = spec.operation == .write && spec.bootSelection == .macInstaller
            || !userCanWrite("/dev/r\(spec.disk)")
            || spec.writeMode == .createInstallMedia || spec.writeMode == .asrRestore
        if needsAdmin {
            let command = ([helper] + args).map(shellQuote).joined(separator: " ") + " > /dev/null 2>&1 &"
            let script = "do shell script \"\(appleScriptEscape(command))\" with administrator privileges with prompt \"RufusAdvanced needs administrator rights to write to the drive \(spec.diskMediaName) (\(spec.disk)).\""
            let osa = Process()
            osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            osa.arguments = ["-e", script]
            let err = Pipe()
            osa.standardError = err
            osa.standardOutput = Pipe()
            try osa.run()
            osa.waitUntilExit()
            if osa.terminationStatus != 0 {
                let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if msg.contains("-128") || msg.lowercased().contains("cancel") { throw RunError.authorizationCancelled }
                throw RunError.launchFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: helper)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            directProcess = p
            helperPID = p.processIdentifier
        }
        startTailing()
    }

    func cancel() {
        FileManager.default.createFile(atPath: cancelPath, contents: Data())
    }

    private func userCanWrite(_ path: String) -> Bool { access(path, W_OK) == 0 }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func startTailing() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
    }

    private func poll() {
        guard !finished, let fh = FileHandle(forReadingAtPath: eventsPath) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: offset)
        let data = (try? fh.readToEnd()) ?? Data()
        if !data.isEmpty {
            offset += UInt64(data.count)
            buffer.append(data)
            lastEvent = Date()
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                guard let event = JobEvent.parse(line) else { continue }
                if case .started(let pid) = event { helperPID = pid }
                if case .finished = event { finish() }
                DispatchQueue.main.async { self.onEvent(event) }
            }
            return
        }
        // Detect a helper that died without reporting (crash, killed).
        if let pid = helperPID, Date().timeIntervalSince(lastEvent) > 3 {
            let alive = kill(pid, 0) == 0 || errno == EPERM
            if !alive {
                finish()
                DispatchQueue.main.async {
                    self.onEvent(.finished(success: false, error: "The disk helper stopped unexpectedly. See the log for details.", notices: []))
                }
            }
        } else if helperPID == nil, Date().timeIntervalSince(lastEvent) > 60 {
            finish()
            DispatchQueue.main.async {
                self.onEvent(.finished(success: false, error: "The disk helper did not start.", notices: []))
            }
        }
    }

    private func finish() {
        finished = true
        timer?.cancel()
        timer = nil
        let dir = jobDir
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { try? FileManager.default.removeItem(atPath: dir) }
    }
}

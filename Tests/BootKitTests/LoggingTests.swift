import Foundation
import Testing
@testable import BootKit

/// Verbose logging, log persistence and the permission error messages (no disks involved).
@Suite(.serialized) struct LoggingTests {

    final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [LogEntry] = []
        func add(_ e: LogEntry) { lock.lock(); items.append(e); lock.unlock() }
        var messages: [String] { lock.lock(); defer { lock.unlock() }; return items.map(\.message) }
    }

    @Test func formattedHasMilliseconds() {
        let e = LogEntry(date: Date(timeIntervalSince1970: 1_000_000_000.123), level: .debug, message: "hello")
        #expect(e.formatted.range(of: #"^\[\d{2}:\d{2}:\d{2}\.\d{3}\]   hello$"#, options: .regularExpression) != nil, "\(e.formatted)")
        #expect(e.fileLine.contains("DEBUG"))
        #expect(e.fileLine.hasSuffix("hello"))
    }

    @Test func jobEventKeepsSubSecondTimestamps() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000.456)
        let line = JobEvent.log(LogEntry(date: date, level: .info, message: "x")).jsonLine
        guard case .log(let back)? = JobEvent.parse(line.trimmingCharacters(in: .newlines)) else {
            Issue.record("could not parse \(line)"); return
        }
        #expect(abs(back.date.timeIntervalSince1970 - date.timeIntervalSince1970) < 0.002)
        #expect(back.message == "x")
    }

    @Test func shellLogsExitStatusAndOutputInVerboseMode() throws {
        let old = Log.shared.verbose
        Log.shared.verbose = true
        defer { Log.shared.verbose = old }
        let cap = Capture()
        let id = Log.shared.addSink { cap.add($0) }
        defer { Log.shared.removeSink(id) }
        let r = try Shell.run("/bin/sh", ["-c", "echo out-line; echo err-line >&2; exit 3"])
        #expect(r.status == 3)
        let all = cap.messages.joined(separator: "\n")
        #expect(all.contains("$ /bin/sh -c"))
        #expect(all.contains("sh exited with status 3"))
        #expect(all.contains("[sh stdout] out-line"))
        #expect(all.contains("[sh stderr] err-line"))
    }

    @Test func permissionErrorIsActionable() {
        let msg = BootKitError.permissionDenied(path: "/dev/rdisk9", errno: EPERM, detail: "test").userMessage
        #expect(msg.contains("/dev/rdisk9"))
        #expect(msg.contains("Operation not permitted"))
        #expect(msg.contains("Full Disk Access"))
        #expect(msg.contains("password"))
    }

    @Test func eaccesOnNonDeviceFileMapsToPermissionDenied() throws {
        // /etc/master.passwd is root-only: opening it as a normal user gives EACCES.
        guard getuid() != 0, FileManager.default.fileExists(atPath: "/etc/master.passwd") else { return }
        do {
            _ = try RawDevice(path: "/etc/master.passwd", writable: false)
            Issue.record("open unexpectedly succeeded")
        } catch BootKitError.permissionDenied(let path, let e, _) {
            #expect(path == "/etc/master.passwd")
            #expect(e == EACCES || e == EPERM)
        }
    }

    @Test func logFileIsWritten() throws {
        let f = LogFile(prefix: "RufusAdvancedTest", keep: 3)
        f.write(LogEntry(level: .warning, message: "persisted line"))
        f.flush()
        let text = try String(contentsOf: f.url, encoding: .utf8)
        #expect(text.contains("WARNING persisted line"))
        #expect(f.url.path.contains("Library/Logs/RufusAdvanced"))
        try? FileManager.default.removeItem(at: f.url)
    }

    @Test func dosDateTimeEncoding() {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 17; c.hour = 21; c.minute = 34; c.second = 10
        let d = Calendar.current.date(from: c)!
        let (date, time) = FATFormatter.dosDateTime(d)
        #expect(date == 23889)   // (2026-1980)<<9 | 10<<5 | 17
        #expect(time == 44101)   // 21<<11 | 34<<5 | 10/2
    }

    @Test func rootVolumeIsNotHidden() {
        #expect(!DiskUtil.isHiddenFromFinder("/"))
        #expect(DiskUtil.slices(of: "disk987654").last == "disk987654")
    }

    @Test func ejectIsOffByDefault() {
        let s = JobSpec(disk: "disk9", diskSize: 1, diskMediaName: "x")
        #expect(s.ejectWhenDone == false)
        #expect(s.mountWhenDone == true)
    }

    @Test func wholeDiskNameAndRights() {
        #expect(DiskAuthorization.wholeDisk(of: "/dev/rdisk9s1") == "disk9")
        #expect(DiskAuthorization.wholeDisk(of: "/dev/disk12") == "disk12")
        let rights = DiskAuthorization.rightNames(for: "disk9")
        #expect(rights.contains("sys.openfile.readwrite./dev/rdisk9"))
        #expect(rights.contains("sys.openfile.readwrite./dev/disk9s1"))
    }
}

import Foundation

/// Everything the privileged helper needs to perform one operation. Built by the app,
/// passed to the helper as base64 JSON on its command line.
public struct JobSpec: Codable, Sendable {
    public enum Operation: String, Codable, Sendable {
        case write          // create bootable / formatted media
        case saveImage      // read the device into an image file
        case badBlocksOnly  // just test the device
    }

    public enum SaveFormat: String, Codable, CaseIterable, Sendable, Identifiable {
        case img = "Raw image (.img)"
        case vhd = "Fixed VHD (.vhd)"
        case dmg = "Apple disk image (.dmg)"
        public var id: String { rawValue }
        public var fileExtension: String {
            switch self { case .img: return "img"; case .vhd: return "vhd"; case .dmg: return "dmg" }
        }
    }

    public var operation: Operation = .write
    public var disk: String
    public var diskSize: UInt64
    public var diskMediaName: String
    public var allowVirtualDisks = false

    public var bootSelection: BootSelection = .image
    public var imagePath: String?
    public var image: ImageReport?
    public var writeMode: WriteMode = .iso

    public var partitionScheme: PartitionScheme = .gpt
    public var targetSystem: TargetSystem = .uefi
    public var fileSystem: FileSystemType = .fat32
    public var clusterSize: UInt32 = 0
    public var label: String = ""
    public var quickFormat = true
    public var extendedLabel = false
    public var badBlocks: BadBlocksOptions?
    public var oldBIOSFixes = false
    public var useRufusMBR = false
    public var biosDriveID: UInt8 = 0x80
    public var persistenceSize: UInt64 = 0
    public var uefiMediaValidation = false
    public var largeWIMStrategy: LargeWIMStrategy = .splitWIM
    public var windows: WindowsCustomization?
    public var verifyWrite = false
    public var ejectWhenDone = true
    public var freeDOSKeyboard = "us"
    public var syslinuxFilesDir: String?          // downloaded, signature verified ldlinux.sys/.bss(/.c32)
    public var grubCoreImagePath: String?         // downloaded GRUB core.img matching the ISO

    public var saveImagePath: String?
    public var saveFormat: SaveFormat = .img

    public var macInstallToApplications = false   // keep the extracted installer app in /Applications
    public var macTempDirectory: String?          // large scratch space for installer assembly

    public var ownerUID: UInt32 = getuid()
    public var ownerGID: UInt32 = getgid()

    public init(disk: String, diskSize: UInt64, diskMediaName: String) {
        self.disk = disk
        self.diskSize = diskSize
        self.diskMediaName = diskMediaName
    }

    public func encoded() throws -> String {
        try JSONEncoder().encode(self).base64EncodedString()
    }

    public static func decode(_ base64: String) throws -> JobSpec {
        guard let d = Data(base64Encoded: base64) else { throw BootKitError.invalidOption("job spec is not valid base64") }
        return try JSONDecoder().decode(JobSpec.self, from: d)
    }
}

/// Progress of a running job.
public struct JobProgress: Codable, Sendable, Equatable {
    public var phase: String
    public var detail: String?
    public var fraction: Double?        // nil = indeterminate
    public var overall: Double?         // whole job, 0...1
    public var bytesDone: UInt64?
    public var bytesTotal: UInt64?
    public var bytesPerSecond: Double?

    public init(phase: String, detail: String? = nil, fraction: Double? = nil, overall: Double? = nil,
                bytesDone: UInt64? = nil, bytesTotal: UInt64? = nil, bytesPerSecond: Double? = nil) {
        self.phase = phase
        self.detail = detail
        self.fraction = fraction
        self.overall = overall
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.bytesPerSecond = bytesPerSecond
    }
}

/// Events streamed from the helper to the app (one JSON object per line).
public enum JobEvent: Codable, Sendable {
    case started(pid: Int32)
    case log(LogEntry)
    case progress(JobProgress)
    case finished(success: Bool, error: String?, notices: [String])

    public var jsonLine: String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .millisecondsSince1970  // keep sub-second log timestamps
        let d = (try? enc.encode(self)) ?? Data()
        return String(decoding: d, as: UTF8.self) + "\n"
    }

    public static func parse(_ line: String) -> JobEvent? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .millisecondsSince1970
        return try? dec.decode(JobEvent.self, from: Data(line.utf8))
    }
}

/// Phase-weighted progress reporting with rate computation and throttling.
public final class JobReporter: @unchecked Sendable {
    public typealias Sink = (JobEvent) -> Void
    private let sink: Sink
    private let lock = NSLock()
    private var phases: [(String, Double)] = []
    private var phaseIndex = -1
    private var phaseStart = Date()
    private var lastEmit = Date.distantPast
    private var current = JobProgress(phase: "")
    private var lastLoggedBucket = 0
    public private(set) var notices: [String] = []

    public init(sink: @escaping Sink) { self.sink = sink }

    /// Declare the phases of the job with relative weights.
    public func plan(_ phases: [(String, Double)]) {
        lock.lock(); self.phases = phases; phaseIndex = -1; lock.unlock()
    }

    public func begin(_ phase: String, detail: String? = nil, total: UInt64? = nil) {
        lock.lock()
        if let i = phases.firstIndex(where: { $0.0 == phase }) { phaseIndex = i }
        phaseStart = Date()
        lastLoggedBucket = 0
        current = JobProgress(phase: phase, detail: detail, fraction: total == nil ? nil : 0, overall: overall(0),
                              bytesDone: total == nil ? nil : 0, bytesTotal: total)
        let p = current
        lock.unlock()
        logInfo(phase + (detail.map { ": \($0)" } ?? ""))
        sink(.progress(p))
    }

    public func update(fraction: Double?, detail: String? = nil, bytesDone: UInt64? = nil, bytesTotal: UInt64? = nil, force: Bool = false) {
        lock.lock()
        let now = Date()
        guard force || now.timeIntervalSince(lastEmit) >= 0.1 else { lock.unlock(); return }
        lastEmit = now
        current.fraction = fraction.map { min(1, max(0, $0)) }
        if let detail { current.detail = detail }
        if let bytesDone { current.bytesDone = bytesDone }
        if let bytesTotal { current.bytesTotal = bytesTotal }
        if let done = current.bytesDone {
            let dt = now.timeIntervalSince(phaseStart)
            current.bytesPerSecond = dt > 0.5 ? Double(done) / dt : nil
        }
        current.overall = overall(current.fraction ?? 0)
        let p = current
        // Verbose log: one line per 10% step of the current phase.
        var milestone: Int?
        if let f = current.fraction {
            let bucket = Int(f * 10)
            if bucket > lastLoggedBucket { lastLoggedBucket = bucket; milestone = bucket * 10 }
        }
        lock.unlock()
        if let m = milestone, Log.shared.verbose {
            var line = "  \(p.phase): \(m)%"
            if let done = p.bytesDone, let total = p.bytesTotal { line += " (\(Units.human(done)) of \(Units.human(total)))" }
            if let r = p.bytesPerSecond { line += " at \(Units.rate(r))" }
            if let d = p.detail { line += " — \(d)" }
            logDebug(line)
        }
        sink(.progress(p))
    }

    public func bytes(_ done: UInt64, of total: UInt64, detail: String? = nil) {
        update(fraction: total > 0 ? Double(done) / Double(total) : nil, detail: detail, bytesDone: done, bytesTotal: total)
    }

    public func notice(_ text: String) {
        lock.lock(); notices.append(text); lock.unlock()
        logNotice(text)
    }

    private func overall(_ fraction: Double) -> Double? {
        guard !phases.isEmpty, phaseIndex >= 0 else { return nil }
        let total = phases.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        let before = phases.prefix(phaseIndex).reduce(0) { $0 + $1.1 }
        return min(1, (before + phases[phaseIndex].1 * fraction) / total)
    }

    public func emit(_ e: JobEvent) { sink(e) }
}

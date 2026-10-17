import Foundation
import CryptoKit

/// Progress snapshot of a running download.
public struct TransferProgress: Sendable, Equatable {
    public var bytes: UInt64
    public var total: UInt64?
    public var bytesPerSecond: Double
    public var phase: String

    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(bytes) / Double(total))
    }

    public var eta: Double? {
        guard let total, bytesPerSecond > 0 else { return nil }
        return Double(total - min(bytes, total)) / bytesPerSecond
    }
}

/// Resumable HTTP(S) download to a file with on-the-fly checksum verification.
///
/// Data is written to "<destination>.part"; an interrupted download resumes with a Range
/// request. The file is renamed to its final name only after the checksum matched.
public final class HTTPDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    public let url: URL
    public let destination: String
    public let expected: (algorithm: HashAlgorithm, value: String)?
    public let headers: [String: String]

    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var hasher: MultiHasher?
    private var received: UInt64 = 0
    private var resumedFrom: UInt64 = 0
    private var total: UInt64?
    private var lastTick = Date()
    private var lastBytes: UInt64 = 0
    private var rate: Double = 0
    private var finished = false
    private let lock = NSLock()

    private var onProgress: ((TransferProgress) -> Void)?
    private var onComplete: ((Result<String, Error>) -> Void)?

    public var partPath: String { destination + ".part" }

    public init(url: URL, destination: String, expected: (HashAlgorithm, String)? = nil, headers: [String: String] = [:]) {
        self.url = url
        self.destination = destination
        self.expected = expected.map { ($0.0, $0.1.lowercased()) }
        self.headers = headers
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 7 * 24 * 3600
        cfg.httpAdditionalHeaders = ["User-Agent": HTTP.userAgent]
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: q)
    }

    public func start(progress: @escaping (TransferProgress) -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        onProgress = progress
        onComplete = completion
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (destination as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let attrs = try? fm.attributesOfItem(atPath: partPath), let sz = attrs[.size] as? UInt64, sz > 0 {
            resumedFrom = sz
            req.setValue("bytes=\(sz)-", forHTTPHeaderField: "Range")
            logInfo("Resuming download of \((destination as NSString).lastPathComponent) at \(Units.human(sz))")
        } else {
            fm.createFile(atPath: partPath, contents: nil)
        }
        task = session.dataTask(with: req)
        task?.resume()
    }

    /// Stop the transfer, keeping the partial file for a later resume.
    public func pause() {
        task?.cancel()
    }

    /// Stop and delete partial data.
    public func cancel() {
        lock.lock(); finished = true; lock.unlock()
        task?.cancel()
        try? handle?.close()
        try? FileManager.default.removeItem(atPath: partPath)
        onComplete?(.failure(BootKitError.cancelled))
        onComplete = nil
    }

    // MARK: URLSessionDataDelegate

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        do {
            if http.statusCode == 206 {
                handle = try FileHandle(forWritingTo: URL(fileURLWithPath: partPath))
                try handle?.seekToEnd()
                received = resumedFrom
                hasher = nil // hash the whole file at the end
                if let cr = http.value(forHTTPHeaderField: "Content-Range"), let t = cr.split(separator: "/").last, let tt = UInt64(t) { total = tt }
            } else if (200..<300).contains(http.statusCode) {
                FileManager.default.createFile(atPath: partPath, contents: nil)
                handle = try FileHandle(forWritingTo: URL(fileURLWithPath: partPath))
                received = 0
                resumedFrom = 0
                hasher = expected.map { MultiHasher([$0.algorithm]) }
                total = http.expectedContentLength > 0 ? UInt64(http.expectedContentLength) : nil
            } else if http.statusCode == 416 {
                // Requested range not satisfiable: the part file is already complete.
                received = resumedFrom
                total = resumedFrom
                completionHandler(.cancel)
                finish(error: nil)
                return
            } else {
                completionHandler(.cancel)
                finish(error: BootKitError.network("HTTP \(http.statusCode) for \(url.host ?? url.absoluteString)"))
                return
            }
        } catch {
            completionHandler(.cancel)
            finish(error: error)
            return
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle?.write(contentsOf: data)
        } catch {
            task?.cancel()
            finish(error: error)
            return
        }
        hasher?.update(data)
        received += UInt64(data.count)
        let now = Date()
        let dt = now.timeIntervalSince(lastTick)
        if dt >= 0.5 {
            let inst = Double(received - lastBytes) / dt
            rate = rate == 0 ? inst : rate * 0.7 + inst * 0.3
            lastTick = now
            lastBytes = received
            onProgress?(TransferProgress(bytes: received, total: total, bytesPerSecond: rate, phase: "Downloading"))
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let e = error as? URLError, e.code == .cancelled {
            lock.lock(); let done = finished; lock.unlock()
            if !done {
                // Paused: keep part file.
                try? handle?.close()
                handle = nil
                finish(error: BootKitError.cancelled, keepPart: true)
            }
            return
        }
        finish(error: error)
    }

    private func finish(error: Error?, keepPart: Bool = true) {
        lock.lock()
        if finished && error == nil { lock.unlock(); return }
        finished = true
        lock.unlock()
        try? handle?.close()
        handle = nil
        guard let completion = onComplete else { return }
        onComplete = nil
        if let error {
            completion(.failure(error))
            return
        }
        do {
            if let total, received < total {
                throw BootKitError.network("Download incomplete (\(Units.human(received)) of \(Units.human(total))). Try again to resume.")
            }
            if let expected {
                let actual: String
                if let h = hasher {
                    actual = h.finalize()[expected.algorithm] ?? ""
                } else {
                    onProgress?(TransferProgress(bytes: 0, total: received, bytesPerSecond: 0, phase: "Verifying"))
                    actual = try MultiHasher.hashFile(at: partPath, algorithms: [expected.algorithm]) { f in
                        self.onProgress?(TransferProgress(bytes: UInt64(Double(self.received) * f), total: self.received, bytesPerSecond: 0, phase: "Verifying"))
                    }[expected.algorithm] ?? ""
                }
                if actual.lowercased() != expected.value {
                    try? FileManager.default.removeItem(atPath: partPath)
                    throw BootKitError.checksumMismatch(expected: expected.value, actual: actual)
                }
                logInfo("\(expected.algorithm.rawValue) verified for \((destination as NSString).lastPathComponent)")
            }
            try? FileManager.default.removeItem(atPath: destination)
            try FileManager.default.moveItem(atPath: partPath, toPath: destination)
            completion(.success(destination))
        } catch {
            completion(.failure(error))
        }
        session.finishTasksAndInvalidate()
    }

    /// async/await convenience.
    public func run(progress: @escaping (TransferProgress) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            start(progress: progress) { cont.resume(with: $0) }
        }
    }
}

/// Small HTTP helpers for the catalog resolvers.
public enum HTTP {
    public static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    public static func get(_ url: String, headers: [String: String] = [:], timeout: TimeInterval = 30) async throws -> (Data, HTTPURLResponse) {
        guard let u = URL(string: url) else { throw BootKitError.network("Invalid URL \(url)") }
        var req = URLRequest(url: u, timeoutInterval: timeout)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw BootKitError.network("No HTTP response from \(u.host ?? url)") }
        return (data, http)
    }

    public static func getString(_ url: String, headers: [String: String] = [:]) async throws -> String {
        let (d, r) = try await get(url, headers: headers)
        guard (200..<300).contains(r.statusCode) else { throw BootKitError.network("HTTP \(r.statusCode) from \(URL(string: url)?.host ?? url)") }
        return String(decoding: d, as: UTF8.self)
    }

    public static func getJSON(_ url: String, headers: [String: String] = [:]) async throws -> Any {
        let (d, r) = try await get(url, headers: headers)
        guard (200..<300).contains(r.statusCode) else { throw BootKitError.network("HTTP \(r.statusCode) from \(URL(string: url)?.host ?? url)") }
        return try JSONSerialization.jsonObject(with: d)
    }

    /// Content length through a HEAD request.
    public static func contentLength(_ url: String) async -> UInt64? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.httpMethod = "HEAD"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, resp) = try? await URLSession.shared.data(for: req), let h = resp as? HTTPURLResponse,
              h.expectedContentLength > 0 else { return nil }
        return UInt64(h.expectedContentLength)
    }
}

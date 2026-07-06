import CryptoKit
import Foundation

public enum CatalogDownloadProgress: Equatable, Sendable {
    case checkingCache(path: String)
    case cacheHit(path: String)
    case startingDownload(url: String, bytes: UInt64)
    case downloading(received: UInt64, total: UInt64?)
    case verifying(path: String, sha256: String)
    case ready(path: String)
}

public typealias CatalogDownloadProgressHandler = @Sendable (CatalogDownloadProgress) -> Void

public struct CatalogDownloader: Sendable {
    private let home: MSLHome

    public init(home: MSLHome) {
        self.home = home
    }

    public func fetch(
        _ resolved: CatalogResolved, progress: CatalogDownloadProgressHandler? = nil
    ) throws -> URL {
        try home.ensureDirectories()
        let destination = try destinationURL(for: resolved)
        progress?(.checkingCache(path: destination.path))
        if try verifyIfPresent(destination, sha256: resolved.artifact.sha256) {
            progress?(.cacheHit(path: destination.path))
            return destination
        }
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = destination.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partial)
        progress?(.startingDownload(url: resolved.artifact.url, bytes: resolved.artifact.sizeBytes))
        try download(
            url: resolved.artifact.url, output: partial, expectedBytes: resolved.artifact.sizeBytes,
            progress: progress)
        progress?(.verifying(path: partial.path, sha256: resolved.artifact.sha256))
        guard try sha256Hex(partial) == resolved.artifact.sha256 else {
            try? FileManager.default.removeItem(at: partial)
            throw MSLError.configuration("download SHA256 mismatch for \(resolved.selector)")
        }
        try replace(partial, destination)
        progress?(.ready(path: destination.path))
        return destination
    }

    private func destinationURL(for resolved: CatalogResolved) throws -> URL {
        let basename = URL(string: resolved.artifact.url)?.lastPathComponent ?? ""
        guard !basename.isEmpty, basename != ".", basename != "..", !basename.contains("/") else {
            throw MSLError.configuration("catalog artifact basename invalid")
        }
        return home.catalogCacheDirectory
            .appendingPathComponent(resolved.family.name)
            .appendingPathComponent(resolved.version.version)
            .appendingPathComponent(resolved.artifact.sha256)
            .appendingPathComponent(basename)
    }

    private func verifyIfPresent(_ url: URL, sha256: String) throws -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return false }
        if try sha256Hex(url) == sha256 { return true }
        try? FileManager.default.removeItem(at: url)
        return false
    }

    private func download(
        url: String, output: URL, expectedBytes: UInt64,
        progress: CatalogDownloadProgressHandler?
    ) throws {
        guard let source = URL(string: url), source.scheme == "https" else {
            throw MSLError.configuration("catalog URL must be HTTPS: \(url)")
        }
        let delegate = CatalogDownloadDelegate(
            output: output, expectedBytes: expectedBytes, progress: progress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.downloadTask(with: source).resume()
        try delegate.wait()
    }

    private func replace(_ source: URL, _ destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
    }

    private func sha256Hex(_ url: URL) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw MSLError.io("cannot read \(url.path)")
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 1024 * 1024)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class CatalogDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let output: URL
    private let expectedBytes: UInt64
    private let progress: CatalogDownloadProgressHandler?
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var downloadFinished = false
    private var downloadError: Error?
    private var redirectCount = 0

    init(output: URL, expectedBytes: UInt64, progress: CatalogDownloadProgressHandler?) {
        self.output = output
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    func wait() throws {
        semaphore.wait()
        lock.lock()
        let final = result
        lock.unlock()
        switch final {
        case .success:
            return
        case .failure(let error):
            throw error
        case .none:
            throw MSLError.io("download ended without a result")
        }
    }

    func urlSession(
        _: URLSession, downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let received = UInt64(max(totalBytesWritten, 0))
        let reported = totalBytesExpectedToWrite > 0 ? UInt64(totalBytesExpectedToWrite) : nil
        let total = reported ?? (expectedBytes > 0 ? expectedBytes : nil)
        progress?(.downloading(received: received, total: total))
    }

    func urlSession(
        _: URLSession, downloadTask _: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.removeItem(at: output)
            }
            try FileManager.default.moveItem(at: location, to: output)
            recordDownload(finished: true, error: nil)
        } catch {
            recordDownload(finished: false, error: error)
        }
    }

    func urlSession(
        _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        redirectCount += 1
        let allowed = redirectCount <= 5
        lock.unlock()
        guard allowed, request.url?.scheme == "https" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            complete(.failure(MSLError.io("download failed: \(error.localizedDescription)")))
            return
        }
        if let response = task.response as? HTTPURLResponse {
            guard (200...299).contains(response.statusCode) else {
                complete(.failure(MSLError.io("download failed: HTTP \(response.statusCode)")))
                return
            }
        }
        lock.lock()
        let finished = downloadFinished
        let storedError = downloadError
        lock.unlock()
        if let storedError {
            complete(.failure(MSLError.io("store download failed: \(storedError)")))
            return
        }
        guard finished else {
            complete(.failure(MSLError.io("download finished without a file")))
            return
        }
        complete(.success(()))
    }

    private func recordDownload(finished: Bool, error: Error?) {
        lock.lock()
        downloadFinished = finished
        downloadError = error
        lock.unlock()
    }

    private func complete(_ value: Result<Void, Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        lock.unlock()
        if case .failure = value {
            try? FileManager.default.removeItem(at: output)
        }
        semaphore.signal()
    }
}

extension CatalogDownloadDelegate: @unchecked Sendable {}

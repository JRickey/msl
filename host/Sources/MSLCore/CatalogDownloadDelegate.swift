import Foundation

final class CatalogDownloadDelegate: NSObject, URLSessionDownloadDelegate {
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
        finishCompletion()
    }

    private func finishCompletion() {
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

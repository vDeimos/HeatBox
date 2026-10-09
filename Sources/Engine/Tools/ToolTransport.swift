import Foundation

/// How the provisioner reaches the internet. Tests give it a stand-in; the
/// app gives it `URLSessionTransport`. Only `https` addresses are ever used.
public protocol ToolTransport: Sendable {
    /// A small answer (a release's tag, a list of checksums).
    func data(from url: URL) async throws -> Data
    /// A file, written to `file`. `progress` is 0 to 1 when the size is known.
    func download(from url: URL, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws
}

public struct URLSessionTransport: ToolTransport {
    public init() {}

    private static let userAgent = "\(Engine.productName)/\(Engine.version)"

    public func data(from url: URL) async throws -> Data {
        guard url.scheme == "https" else { throw ToolInstallError.notSecure }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral, delegate: SecureRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ToolInstallError.unreachable }
        return data
    }

    public func download(from url: URL, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard url.scheme == "https" else { throw ToolInstallError.notSecure }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        try await FileDownload(destination: file, progress: progress).run(request)
    }
}

/// Follows redirects only while they stay on https.
private class SecureRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}

private final class TaskBox: @unchecked Sendable {
    let task: URLSessionTask
    init(_ task: URLSessionTask) { self.task = task }
}

/// One download to a file, with progress, that ends when the task is cancelled.
private final class FileDownload: SecureRedirects, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func run(_ request: URLRequest) async throws {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let box = TaskBox(session.downloadTask(with: request))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                self.continuation = continuation
                lock.unlock()
                box.task.resume()
            }
        } onCancel: {
            box.task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            lock.lock(); failure = ToolInstallError.unreachable; lock.unlock()
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            lock.lock(); failure = error; lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        let problem = error ?? failure
        lock.unlock()
        if let problem { waiting?.resume(throwing: problem) } else { waiting?.resume() }
    }
}

import CryptoKit
import Foundation

final class UpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let progress: @Sendable (Double) -> Void
    private let expectedSize: Int
    private let destination: URL
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var moveError: Error?
    private let lock = NSLock()

    init(configuration: URLSessionConfiguration, destination: URL, expectedSize: Int, progress: @escaping @Sendable (Double) -> Void) {
        self.configuration = configuration
        self.destination = destination
        self.expectedSize = expectedSize
        self.progress = progress
    }

    func download(_ request: URLRequest) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                lock.lock()
                continuation = cont
                let config = configuration
                config.urlCache = nil
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            let task = self.task
            self.lock.unlock()
            task?.cancel()
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
        guard let cont else { return }
        switch result {
        case .success(let url): cont.resume(returning: url)
        case .failure(let error): cont.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? Double(totalBytesExpectedToWrite) : Double(expectedSize)
        guard total > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / total))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            moveError = UpdateError.downloadFailed("HTTP \(http.statusCode)")
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let moveError {
            finish(.failure(moveError))
        } else if let error {
            if (error as? URLError)?.code == .cancelled { finish(.failure(CancellationError())) }
            else { finish(.failure(UpdateError.downloadFailed(error.localizedDescription))) }
        } else {
            progress(1)
            finish(.success(destination))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if let from = task.originalRequest?.url?.host, let to = request.url?.host, from != to {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

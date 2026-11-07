import Foundation
import FSCore

public struct RetryPolicy: Sendable, Hashable {
    public var maxAttempts: Int
    public var initialDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 3, initialDelay: TimeInterval = 0.5, maxDelay: TimeInterval = 8) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
    }

    public static let none = RetryPolicy(maxAttempts: 1)

    public func delay(afterAttempt attempt: Int) -> TimeInterval {
        min(maxDelay, initialDelay * pow(2, Double(max(0, attempt - 1))))
    }

    public func run<T>(isRetryable: (Error) -> Bool = RetryPolicy.isTransient, onRetry: ((Int, Error) async -> Void)? = nil, _ body: (Int) async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            try Task.checkCancellation()
            do {
                return try await body(attempt)
            } catch {
                if error is CancellationError || (error as? ResourceError) == .cancelled { throw error }
                guard attempt < maxAttempts, isRetryable(error) else { throw error }
                await onRetry?(attempt, error)
                let nanos = UInt64(delay(afterAttempt: attempt) * 1_000_000_000)
                if nanos > 0 { try await Task.sleep(nanoseconds: nanos) }
                attempt += 1
            }
        }
    }

    public static func isTransient(_ error: Error) -> Bool {
        if let r = error as? ResourceError { return r.isTransient }
        if let u = error as? URLError {
            switch u.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost, .resourceUnavailable, .secureConnectionFailed:
                return true
            default:
                return false
            }
        }
        return false
    }
}

public enum ConnectionState: Sendable, Hashable {
    case idle
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case failed(String)
    case disconnected

    public var isConnected: Bool { self == .connected }
}

final class AsyncLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var available: Int
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    init(_ limit: Int) { available = max(1, limit) }

    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    c.resume(throwing: CancellationError())
                } else if available > 0 {
                    available -= 1
                    lock.unlock()
                    c.resume()
                } else {
                    waiters.append((id, c))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let idx = waiters.firstIndex { $0.0 == id }
            let w = idx.map { waiters.remove(at: $0) }
            lock.unlock()
            w?.1.resume(throwing: CancellationError())
        }
    }

    func release() {
        lock.lock()
        if !waiters.isEmpty {
            let w = waiters.removeFirst()
            lock.unlock()
            w.1.resume()
        } else {
            available += 1
            lock.unlock()
        }
    }

    func with<T>(_ body: () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        return try await body()
    }
}

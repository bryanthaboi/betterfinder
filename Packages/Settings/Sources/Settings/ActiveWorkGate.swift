import AppKit
import Combine
import Foundation

@MainActor
public final class ActiveWorkGate {
    public enum Purpose: Sendable {
        case quit
        case update
    }

    public enum Choice: Sendable {
        case waitUntilFinished
        case cancelWorkAndProceed
        case dontProceed
    }

    public enum TerminationDecision: Equatable, Sendable {
        case proceed
        case cancel
        case quitWhenIdle
        case cancelWorkThenProceed
    }

    public var activeCount: @MainActor () -> Int
    public var cancelAll: @MainActor () -> Void
    public var counts: AnyPublisher<Int, Never>
    public var ask: @MainActor (Int, Purpose) -> Choice
    public var keepWaitingForCancellation: @MainActor () -> Bool
    public var cancellationPromptDelay: TimeInterval

    private var pendingQuit: AnyCancellable?
    private var pendingQuitAction: (@MainActor () -> Void)?
    private var pendingQuitToken = 0

    public init(
        activeCount: @escaping @MainActor () -> Int,
        cancelAll: @escaping @MainActor () -> Void,
        counts: AnyPublisher<Int, Never>,
        ask: @escaping @MainActor (Int, Purpose) -> Choice = ActiveWorkGate.alert(count:purpose:),
        keepWaitingForCancellation: @escaping @MainActor () -> Bool = ActiveWorkGate.keepWaitingAlert,
        cancellationPromptDelay: TimeInterval = 20
    ) {
        self.activeCount = activeCount
        self.cancelAll = cancelAll
        self.counts = counts
        self.ask = ask
        self.keepWaitingForCancellation = keepWaitingForCancellation
        self.cancellationPromptDelay = cancellationPromptDelay
    }

    public var isQuitPending: Bool { pendingQuitAction != nil }

    public func cancelPendingQuit() {
        pendingQuitToken &+= 1
        pendingQuitAction = nil
        pendingQuit = nil
    }

    public func terminationDecision() -> TerminationDecision {
        let n = activeCount()
        guard n > 0 else {
            cancelPendingQuit()
            return .proceed
        }
        switch ask(n, .quit) {
        case .dontProceed:
            cancelPendingQuit()
            return .cancel
        case .waitUntilFinished:
            return .quitWhenIdle
        case .cancelWorkAndProceed:
            cancelPendingQuit()
            cancelAll()
            return .cancelWorkThenProceed
        }
    }

    public func quitWhenIdle(_ action: @escaping @MainActor () -> Void) {
        cancelPendingQuit()
        let token = pendingQuitToken
        pendingQuitAction = action
        let subscription = counts
            .filter { $0 == 0 }
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.schedulePendingQuitCheck(token) }
            }
        if token == pendingQuitToken, pendingQuitAction != nil { pendingQuit = subscription }
        schedulePendingQuitCheck(token)
    }

    private func schedulePendingQuitCheck(_ token: Int) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.deliverPendingQuitIfIdle(token) }
        }
    }

    private func deliverPendingQuitIfIdle(_ token: Int) {
        guard token == pendingQuitToken, let action = pendingQuitAction, activeCount() == 0 else { return }
        cancelPendingQuit()
        action()
    }

    public func confirm(_ purpose: Purpose) async -> Bool {
        let n = activeCount()
        guard n > 0 else { return true }
        switch ask(n, purpose) {
        case .dontProceed:
            return false
        case .waitUntilFinished:
            return await waitUntilIdle(timeout: nil)
        case .cancelWorkAndProceed:
            cancelAll()
            return await waitForCancellation()
        }
    }

    public func waitForCancellation() async -> Bool {
        while true {
            if await waitUntilIdle(timeout: cancellationPromptDelay) { return true }
            if Task.isCancelled { return false }
            if !keepWaitingForCancellation() { return true }
        }
    }

    public func waitUntilIdle(timeout: TimeInterval?) async -> Bool {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while activeCount() > 0 {
            if Task.isCancelled { return false }
            let remaining = deadline.map { $0.timeIntervalSinceNow }
            if let remaining, remaining <= 0 { return false }
            guard await nextIdleSignal(timeout: remaining) else {
                return !Task.isCancelled && activeCount() == 0
            }
            await Self.nextMainLoopTurn()
        }
        return true
    }

    private static func nextMainLoopTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func nextIdleSignal(timeout: TimeInterval?) async -> Bool {
        if activeCount() == 0 { return true }
        let box = WaitBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                box.install(continuation)
                let subscription = counts.sink { value in if value == 0 { box.finish(true) } }
                box.retain(subscription)
                if activeCount() == 0 { box.finish(true) }
                if let timeout {
                    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { box.finish(false) }
                }
            }
        } onCancel: {
            box.finish(false)
        }
    }

    public static func message(count: Int, purpose: Purpose) -> (title: String, detail: String, wait: String, cancelWork: String, dontProceed: String) {
        let ops = count == 1 ? "A file operation is" : "\(count) file operations are"
        switch purpose {
        case .quit:
            return ("\(ops) still running", "Quitting now would stop copies and moves partway through. betterfinder can quit as soon as they finish, or cancel them and clean up first.", "Quit When Finished", "Cancel Operations and Quit", "Don’t Quit")
        case .update:
            return ("\(ops) still running", "Installing the update quits betterfinder. It can install as soon as they finish, or cancel them and clean up first.", "Install When Finished", "Cancel Operations and Install", "Not Now")
        }
    }

    public static func alert(count: Int, purpose: Purpose) -> Choice {
        let text = message(count: count, purpose: purpose)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = text.title
        alert.informativeText = text.detail
        alert.addButton(withTitle: text.wait)
        alert.addButton(withTitle: text.dontProceed)
        alert.addButton(withTitle: text.cancelWork)
        alert.buttons[1].keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .waitUntilFinished
        case .alertThirdButtonReturn: return .cancelWorkAndProceed
        default: return .dontProceed
        }
    }

    public static func keepWaitingAlert() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "File operations are still stopping"
        alert.informativeText = "Some cancelled operations haven’t finished cleaning up. Quitting now may leave partial copies behind."
        alert.addButton(withTitle: "Keep Waiting")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

private final class WaitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var pendingResult: Bool?
    private var subscription: AnyCancellable?

    func install(_ c: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if let result = pendingResult {
            lock.unlock()
            c.resume(returning: result)
            return
        }
        continuation = c
        lock.unlock()
    }

    func retain(_ s: AnyCancellable) {
        lock.lock()
        if pendingResult != nil {
            lock.unlock()
            s.cancel()
            return
        }
        subscription = s
        lock.unlock()
    }

    func finish(_ value: Bool) {
        lock.lock()
        guard pendingResult == nil else { lock.unlock(); return }
        pendingResult = value
        let c = continuation
        continuation = nil
        let s = subscription
        subscription = nil
        lock.unlock()
        s?.cancel()
        c?.resume(returning: value)
    }
}

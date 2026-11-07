import AppKit
import Foundation

private final class SheetHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var dismiss: (@MainActor () -> Void)?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func set(_ handler: @escaping @MainActor () -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        dismiss = handler
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let handler = dismiss
        dismiss = nil
        lock.unlock()
        if let handler { DispatchQueue.main.async { MainActor.assumeIsolated { handler() } } }
    }
}

public final class AlertHookDecisionPresenter: HookDecisionPresenting, @unchecked Sendable {
    private let windowProvider: @MainActor @Sendable () -> NSWindow?

    public init(windowProvider: @escaping @MainActor @Sendable () -> NSWindow? = { NSApp.keyWindow }) {
        self.windowProvider = windowProvider
    }

    public func decide(_ info: PausedOperationInfo) async -> HookUserDecision {
        let handle = SheetHandle()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<HookUserDecision, Never>) in
                DispatchQueue.main.async { [self] in
                    MainActor.assumeIsolated { present(info, handle: handle, continuation: cont) }
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    @MainActor
    private func present(_ info: PausedOperationInfo, handle: SheetHandle, continuation: CheckedContinuation<HookUserDecision, Never>) {
        if handle.isCancelled {
            continuation.resume(returning: .cancel)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = info.message
        alert.informativeText = "“Run Anyway” performs the operation without this check. “Cancel” leaves your files untouched."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Run Anyway")

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            continuation.resume(returning: response == .alertSecondButtonReturn ? .runAnyway : .cancel)
        }

        if let window = windowProvider(), window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: finish)
            let sheet = alert.window
            _ = handle.set { [weak window] in
                if sheet.isVisible { window?.endSheet(sheet, returnCode: .abort) }
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            finish(alert.runModal())
        }
    }
}

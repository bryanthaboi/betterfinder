import AppKit
import FileOps

@MainActor
final class OperationFailureNotifier {
    static let shared = OperationFailureNotifier()

    private var pending: [String] = []
    private var scheduled = false

    static func failureText(for op: FileOperation) -> String? {
        switch op.state {
        case .failed(let reason):
            return "\(op.title) failed: \(reason)"
        case .finished where !op.errors.isEmpty:
            let n = op.errors.count
            return "\(op.title) finished with \(n == 1 ? "1 item" : "\(n) items") that couldn’t be completed"
        default:
            return nil
        }
    }

    func operationFinished(_ op: FileOperation) {
        guard let text = Self.failureText(for: op) else { return }
        pending.append(text)
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        scheduled = false
        let texts = pending
        pending = []
        guard !texts.isEmpty else { return }
        if let window = OperationsWindowController.shared.window, !window.isVisible {
            window.orderFront(nil)
        }
    }
}

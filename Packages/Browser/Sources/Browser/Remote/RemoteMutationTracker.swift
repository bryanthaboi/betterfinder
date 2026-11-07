import Combine
import Foundation

@MainActor
public final class RemoteMutationTracker: ObservableObject {
    public static let shared = RemoteMutationTracker()

    @Published public private(set) var activeCount = 0
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    @discardableResult
    public func run(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        activeCount += 1
        let task = Task { @MainActor [weak self] in
            await body()
            self?.finish(id)
        }
        tasks[id] = task
        return task
    }

    public func cancelAll() {
        tasks.values.forEach { $0.cancel() }
    }

    private func finish(_ id: UUID) {
        tasks[id] = nil
        activeCount = max(0, activeCount - 1)
    }
}

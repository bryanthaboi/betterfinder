import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public final class ThemeEditorModel: ObservableObject {
    public let manager: ThemeManager
    @Published public var draft: Theme {
        didSet { draftChanged(from: oldValue) }
    }
    @Published public var errorMessage: String?
    public var saveDelay: TimeInterval = 0.35

    private var suppress = false
    private var pendingSave: DispatchWorkItem?

    public init(manager: ThemeManager) {
        self.manager = manager
        self.draft = manager.current
    }

    public var isBuiltIn: Bool { manager.isBuiltIn(draft.id) }
    public var hasOverride: Bool { manager.hasUserOverride(draft.id) }
    public var isContributed: Bool { manager.isContributed(draft.id) }
    public var contributionOwner: String? { manager.contributionOwner(of: draft.id) }

    public func binding<T>(_ keyPath: WritableKeyPath<Theme, T>) -> Binding<T> {
        Binding(get: { self.draft[keyPath: keyPath] }, set: { self.draft[keyPath: keyPath] = $0 })
    }

    public func optionalBinding<T>(_ keyPath: WritableKeyPath<Theme, T?>, default makeDefault: @escaping () -> T) -> (isOn: Binding<Bool>, value: Binding<T>) {
        let on = Binding<Bool>(
            get: { self.draft[keyPath: keyPath] != nil },
            set: { self.draft[keyPath: keyPath] = $0 ? (self.draft[keyPath: keyPath] ?? makeDefault()) : nil }
        )
        let value = Binding<T>(
            get: { self.draft[keyPath: keyPath] ?? makeDefault() },
            set: { self.draft[keyPath: keyPath] = $0 }
        )
        return (on, value)
    }

    public func load(_ theme: Theme) {
        suppress = true
        draft = theme
        suppress = false
    }

    public func syncFromManager() {
        if manager.current.id != draft.id || pendingSave == nil && manager.current != draft {
            load(manager.current)
        }
    }

    private func draftChanged(from old: Theme) {
        guard !suppress, draft != old else { return }
        if manager.isContributed(old.id) {
            forkContributedDraft(editedFrom: old)
            return
        }
        manager.applyLive(draft)
        scheduleSave()
    }

    private func forkContributedDraft(editedFrom old: Theme) {
        let edited = draft
        suppress = true
        draft = old
        suppress = false
        cancelPendingSave()
        perform {
            let forked = try manager.forkContributed(old.id, applying: edited)
            manager.select(forked.id)
            load(manager.current)
        }
    }

    @discardableResult
    func forkIfContributed() -> Bool {
        guard manager.isContributed(draft.id) else { return true }
        cancelPendingSave()
        do {
            let forked = try manager.forkContributed(draft.id, applying: draft)
            manager.select(forked.id)
            load(manager.current)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + saveDelay, execute: work)
    }

    public func flush() {
        guard let work = pendingSave else { return }
        work.cancel()
        pendingSave = nil
        do {
            try manager.save(draft)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cancelPendingSave() {
        pendingSave?.cancel()
        pendingSave = nil
    }

    public func select(_ id: String) {
        guard id != draft.id else { return }
        flush()
        manager.select(id)
        load(manager.current)
    }

    public func duplicate() {
        flush()
        perform {
            let t = try manager.duplicate(draft.id)
            manager.select(t.id)
            load(manager.current)
        }
    }

    public func resetToOriginal() {
        cancelPendingSave()
        perform {
            try manager.resetToOriginal(draft.id)
            load(manager.current)
        }
    }

    public func deleteCurrent() {
        cancelPendingSave()
        perform {
            try manager.delete(draft.id)
            load(manager.current)
        }
    }

    public func importTheme() {
        let panel = NSOpenPanel()
        panel.title = "Import Theme"
        panel.allowedContentTypes = [UTType(filenameExtension: ThemeManager.packageExtension) ?? .data, .zip, .json, .folder]
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        flush()
        perform {
            let t = try manager.importTheme(from: url)
            manager.select(t.id)
            load(manager.current)
        }
    }

    public func exportCurrent() {
        flush()
        let panel = NSSavePanel()
        panel.title = "Export Theme"
        panel.nameFieldStringValue = "\(draft.name).\(ThemeManager.packageExtension)"
        panel.allowedContentTypes = [UTType(filenameExtension: ThemeManager.packageExtension) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try manager.exportTheme(draft.id, to: url) }
    }

    public func chooseAsset(subdirectory: String, types: [UTType]) -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        flush()
        guard forkIfContributed() else { return nil }
        do {
            try manager.save(draft)
            return try manager.importAsset(from: url, for: draft.id, subdirectory: subdirectory)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func perform(_ body: () throws -> Void) {
        do {
            try body()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

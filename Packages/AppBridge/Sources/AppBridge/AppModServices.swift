import AppKit
import Foundation
import ModHost

public final class AppModServices: ModHostServices, @unchecked Sendable {
    public let environmentState: ModEnvironmentState
    public var modName: @Sendable (String) -> String
    public var defaults: UserDefaults = .standard
    public static let alwaysAllowedExecutionKey = "modExecAlwaysAllowed"
    private let lock = NSLock()
    private var scriptedDestination: URL?
    private var scriptedExecution: Bool?
    private var scriptedCredential: String?

    public init(environment: ModEnvironmentState, modName: @escaping @Sendable (String) -> String = { $0 }) {
        self.environmentState = environment
        self.modName = modName
    }

    public func script(destination: URL? = nil, execution: Bool? = nil, credential: String? = nil) {
        lock.withLock {
            scriptedDestination = destination
            scriptedExecution = execution
            scriptedCredential = credential
        }
    }

    var isScripted: Bool { lock.withLock { scriptedDestination != nil || scriptedExecution != nil || scriptedCredential != nil } }

    public func pickDestination(modId: String, prompt: String) async -> URL? {
        if isScripted { return lock.withLock { scriptedDestination } }
        let name = modName(modId)
        return await MainActor.run {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose"
            panel.message = "“\(name)” asks: \(prompt)"
            NSApp.activate(ignoringOtherApps: true)
            return panel.runModal() == .OK ? panel.url : nil
        }
    }

    public func confirmUnrestrictedExecution(modId: String, executable: String, arguments: [String]) async -> Bool {
        if isScripted { return lock.withLock { scriptedExecution ?? false } }
        if isExecutionAlwaysAllowed(modId: modId, executable: executable) { return true }
        switch await Self.confirmExecution(mod: modName(modId), executable: executable, arguments: arguments) {
        case .deny: return false
        case .once: return true
        case .always:
            setExecutionAlwaysAllowed(true, modId: modId, executable: executable)
            return true
        }
    }

    public func isExecutionAlwaysAllowed(modId: String, executable: String) -> Bool {
        lock.withLock { (defaults.dictionary(forKey: Self.alwaysAllowedExecutionKey) as? [String: [String]])?[modId]?.contains(executable) ?? false }
    }

    public func setExecutionAlwaysAllowed(_ allowed: Bool, modId: String, executable: String) {
        lock.withLock {
            var all = defaults.dictionary(forKey: Self.alwaysAllowedExecutionKey) as? [String: [String]] ?? [:]
            var list = all[modId] ?? []
            list.removeAll { $0 == executable }
            if allowed { list.append(executable) }
            all[modId] = list.isEmpty ? nil : list
            defaults.set(all, forKey: Self.alwaysAllowedExecutionKey)
        }
    }

    public func forgetAlwaysAllowedExecution(modId: String) {
        lock.withLock {
            var all = defaults.dictionary(forKey: Self.alwaysAllowedExecutionKey) as? [String: [String]] ?? [:]
            all[modId] = nil
            defaults.set(all, forKey: Self.alwaysAllowedExecutionKey)
        }
    }

    enum ExecutionChoice { case deny, once, always }

    public func requestCredential(modId: String, name: String, destination: String) async -> String? {
        if isScripted { return lock.withLock { scriptedCredential } }
        return await Self.askCredential(mod: modName(modId), name: name, destination: destination)
    }

    @MainActor
    static func confirmExecution(mod: String, executable: String, arguments: [String]) async -> ExecutionChoice {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Allow “\(mod)” to run a program with full access?"
        let command = ([executable] + arguments).map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
        let program = (executable as NSString).lastPathComponent
        alert.informativeText = "The program runs as you, with access to all your files and the network. Only allow this if you trust the mod. Always Allow stops asking whenever this mod runs \(program), with any arguments, until you uninstall the mod.\n\n\(command)"
        alert.addButton(withTitle: "Don’t Allow")
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Always Allow \(program)")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        alert.buttons[2].keyEquivalent = ""
        switch await present(alert) {
        case .alertSecondButtonReturn: return .once
        case .alertThirdButtonReturn: return .always
        default: return .deny
        }
    }

    @MainActor
    static func askCredential(mod: String, name: String, destination: String) async -> String? {
        let alert = NSAlert()
        alert.messageText = "“\(mod)” needs a credential"
        alert.informativeText = "Enter “\(name)” for \(destination). It's stored in your Keychain and only sent to \(destination)."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = name
        field.setAccessibilityLabel(name)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard await present(alert) == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue
        return value.isEmpty ? nil : value
    }

    public func environment() async -> ModHostEnvironment { environmentState.snapshot }

    @MainActor
    public static func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.keyWindow ?? NSApp.mainWindow, w.isVisible, w.attachedSheet == nil, !(w is NSPanel) {
            return await withCheckedContinuation { c in alert.beginSheetModal(for: w) { c.resume(returning: $0) } }
        }
        return alert.runModal()
    }
}

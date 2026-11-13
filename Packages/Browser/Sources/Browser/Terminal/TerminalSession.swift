import AppKit
import Integration

@MainActor
final class TerminalSession {
    let id = UUID()
    let emulator: TerminalEmulator
    let shellPath: String
    private(set) var process: PTYProcess?
    private(set) var exited = false
    private(set) var startError: String?
    var onChange: () -> Void = {}
    var onTitleChange: () -> Void = {}
    var onExit: () -> Void = {}

    private let pending = PendingBytes()
    private let startDirectory: URL

    init(shellPath: String, directory: URL, cols: Int = 80, rows: Int = 24) {
        self.shellPath = shellPath
        self.startDirectory = directory
        emulator = TerminalEmulator(cols: cols, rows: rows)
        emulator.respond = { [weak self] bytes in self?.send(bytes) }
        emulator.onTitleChange = { [weak self] _ in self?.onTitleChange() }
        emulator.onBell = { NSSound.beep() }
    }

    func start() {
        guard process == nil, !exited else { return }
        let pending = pending
        do {
            process = try PTYProcess(shell: shellPath, directory: startDirectory, cols: emulator.cols, rows: emulator.rows, onOutput: { [weak self] bytes in
                guard pending.append(bytes) else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.flush() } }
            }, onExit: { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.processExited() } }
            })
        } catch {
            startError = error.localizedDescription
            emulator.feed("\(error.localizedDescription)\r\n")
            exited = true
        }
    }

    var title: String {
        let t = emulator.title.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { return t }
        if let dir = process?.currentDirectory { return dir.path == NSHomeDirectory() ? "~" : dir.lastPathComponent }
        return (shellPath as NSString).lastPathComponent
    }

    var currentDirectory: URL? { process?.currentDirectory }
    var isBusy: Bool { process?.hasForegroundJob ?? false }

    private func flush() {
        let bytes = pending.drain()
        guard !bytes.isEmpty else { return }
        emulator.feed(bytes)
        onChange()
    }

    private func processExited() {
        flush()
        exited = true
        process?.terminate()
        onExit()
    }

    func send(_ bytes: [UInt8]) {
        guard !exited else { return }
        let process = process
        DispatchQueue.global(qos: .userInitiated).async { process?.write(bytes) }
    }

    func send(_ text: String) { send(Array(text.utf8)) }

    func paste(_ text: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        if emulator.bracketedPaste {
            send("\u{1B}[200~" + normalized.replacingOccurrences(of: "\u{1B}[201~", with: "") + "\u{1B}[201~")
        } else {
            send(normalized)
        }
    }

    func changeDirectory(to url: URL) {
        send([0x15])
        send(" cd -- \(Self.shellQuote(url.path))\r")
    }

    nonisolated static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func resize(cols: Int, rows: Int) {
        guard cols != emulator.cols || rows != emulator.rows else { return }
        emulator.resize(cols: cols, rows: rows)
        process?.resize(cols: cols, rows: rows)
        onChange()
    }

    func terminate() {
        process?.terminate()
        exited = true
    }
}

final class PendingBytes: @unchecked Sendable {
    private var bytes: [UInt8] = []
    private var scheduled = false
    private let lock = NSLock()

    func append(_ new: [UInt8]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        bytes += new
        if scheduled { return false }
        scheduled = true
        return true
    }

    func drain() -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        scheduled = false
        let out = bytes
        bytes.removeAll(keepingCapacity: true)
        return out
    }
}

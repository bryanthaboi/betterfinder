import Darwin
import Foundation
import Integration

final class PTYProcess: @unchecked Sendable {
    enum SpawnError: LocalizedError {
        case forkFailed(Int32)
        var errorDescription: String? {
            switch self {
            case .forkFailed(let e): return "Couldn't start a shell: \(String(cString: strerror(e)))"
            }
        }
    }

    let pid: pid_t
    private let master: Int32
    private let source: DispatchSourceRead
    private let exitSource: DispatchSourceProcess
    private var closed = false
    private let lock = NSLock()

    static func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "betterfinder"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        for key in ["TERM_SESSION_ID", "ITERM_SESSION_ID", "TERM_PROGRAM_VERSION", "__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS"] { env.removeValue(forKey: key) }
        return env
    }

    init(shell: String = TerminalShells.loginShellPath(), directory: URL, cols: Int, rows: Int,
         onOutput: @escaping @Sendable ([UInt8]) -> Void, onExit: @escaping @Sendable (Int32) -> Void) throws {
        let name = (shell as NSString).lastPathComponent
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("-" + name), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = Self.environment().map { strdup("\($0.key)=\($0.value)") } + [nil]
        let shellPath = strdup(shell)
        let dirPath = strdup(directory.path)
        let home = strdup(FileManager.default.homeDirectoryForCurrentUser.path)
        defer {
            for p in argv { free(p) }
            for p in envp { free(p) }
            free(shellPath); free(dirPath); free(home)
        }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        var fd: Int32 = -1
        let child = forkpty(&fd, nil, nil, &size)
        if child < 0 { throw SpawnError.forkFailed(errno) }
        if child == 0 {
            if chdir(dirPath) != 0 { _ = chdir(home) }
            argv.withUnsafeBufferPointer { a in
                envp.withUnsafeBufferPointer { e in
                    _ = execve(shellPath, a.baseAddress, e.baseAddress)
                }
            }
            _exit(127)
        }
        pid = child
        master = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let queue = DispatchQueue(label: "betterfinder.pty.\(child)")
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        exitSource = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                onOutput(Array(buffer[0..<n]))
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                self.source.cancel()
            }
        }
        exitSource.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(child, &status, 0)
            self?.exitSource.cancel()
            onExit(status)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        exitSource.resume()
    }

    deinit { terminate() }

    func write(_ bytes: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, !bytes.isEmpty else { return }
        var offset = 0
        var spins = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(master, $0.baseAddress! + offset, bytes.count - offset) }
            if n > 0 { offset += n; spins = 0; continue }
            if n < 0 && (errno == EAGAIN || errno == EINTR) && spins < 200 { spins += 1; usleep(1000); continue }
            return
        }
    }

    func resize(cols: Int, rows: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    var currentDirectory: URL? {
        var info = proc_vnodepathinfo()
        let pgid = tcgetpgrp(master)
        let target = pgid > 0 ? pgid : pid
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(target, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    var hasForegroundJob: Bool {
        let pgid = tcgetpgrp(master)
        return pgid > 0 && pgid != pid
    }

    func terminate() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        source.cancel()
        kill(-pid, SIGHUP)
        kill(pid, SIGHUP)
    }
}

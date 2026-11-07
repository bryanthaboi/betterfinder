import Darwin
import Foundation

public struct SubprocessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

enum Subprocess {
    static func run(_ executable: URL, arguments: [String], stdin: Data, environment: [String: String], currentDirectory: URL? = nil) async throws -> SubprocessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<SubprocessResult, Error>) in
                do {
                    try process.run()
                } catch {
                    c.resume(throwing: error)
                    return
                }
                DispatchQueue.global(qos: .utility).async {
                    let h = inPipe.fileHandleForWriting
                    if !stdin.isEmpty { try? h.write(contentsOf: stdin) }
                    try? h.close()
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let (out, err) = drain(outPipe.fileHandleForReading.fileDescriptor, errPipe.fileHandleForReading.fileDescriptor, exited: exited)
                    try? outPipe.fileHandleForReading.close()
                    try? errPipe.fileHandleForReading.close()
                    c.resume(returning: SubprocessResult(status: process.terminationStatus, stdout: out, stderr: err))
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
    }

    private static func drain(_ outFD: Int32, _ errFD: Int32, exited: DispatchSemaphore) -> (Data, Data) {
        var out = Data()
        var err = Data()
        var open = [outFD: true, errFD: true]
        var buffer = [UInt8](repeating: 0, count: 65536)
        var hasExited = false
        var quietAfterExit = 0
        func readOnce(_ fd: Int32) -> Bool {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                if fd == outFD { out.append(contentsOf: buffer[0..<n]) } else { err.append(contentsOf: buffer[0..<n]) }
                return true
            }
            if n == 0 || (errno != EAGAIN && errno != EINTR) { open[fd] = false }
            return false
        }
        while open.values.contains(true) {
            if !hasExited, exited.wait(timeout: .now()) == .success { hasExited = true }
            var fds = open.filter(\.value).map { pollfd(fd: $0.key, events: Int16(POLLIN), revents: 0) }
            let r = poll(&fds, nfds_t(fds.count), 100)
            if r > 0 {
                var any = false
                for p in fds where p.revents != 0 {
                    if readOnce(p.fd) { any = true }
                }
                if hasExited && !any { quietAfterExit += 1 }
            } else if hasExited {
                quietAfterExit += 1
            }
            if hasExited && quietAfterExit >= 2 { break }
        }
        if !hasExited { exited.wait() }
        return (out, err)
    }
}

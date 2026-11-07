import Foundation

public struct CommandInvocation: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: URL?
    public var input: Data?
    public var timeout: TimeInterval

    public init(_ executable: String, _ arguments: [String], workingDirectory: URL? = nil, input: Data? = nil, timeout: TimeInterval = 120) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.input = input
        self.timeout = timeout
    }

    public var display: String { ([executable] + arguments).joined(separator: " ") }
}

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var succeeded: Bool { status == 0 }
}

public enum CommandRunnerError: Error, Equatable, Sendable {
    case notFound(String)
    case launchFailed(String)
    case timedOut(String)
}

public protocol CommandRunning: Sendable {
    func run(_ invocation: CommandInvocation) async throws -> CommandResult
}

public struct UnavailableCommandRunner: CommandRunning {
    public init() {}
    public func run(_ invocation: CommandInvocation) async throws -> CommandResult { throw CommandRunnerError.notFound(invocation.executable) }
}

public struct ProcessCommandRunner: CommandRunning {
    public static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    public static let allowedExecutables: Set<String> = ["gh", "git"]
    static let outputLimit = 1 << 20

    public init() {}

    public static func locate(_ name: String) -> URL? {
        guard allowedExecutables.contains(name) else { return nil }
        let fm = FileManager.default
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for extra in searchDirectories where !dirs.contains(extra) { dirs.append(extra) }
        for dir in dirs {
            let path = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    public func run(_ invocation: CommandInvocation) async throws -> CommandResult {
        guard let url = Self.locate(invocation.executable) else { throw CommandRunnerError.notFound(invocation.executable) }
        let process = Process()
        process.executableURL = url
        process.arguments = invocation.arguments
        if let cwd = invocation.workingDirectory { process.currentDirectoryURL = cwd }
        var env = ProcessInfo.processInfo.environment
        env["GH_PROMPT_DISABLED"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GH_NO_UPDATE_NOTIFIER"] = "1"
        env["GH_SPINNER_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        process.environment = env
        let out = Pipe(), err = Pipe(), inPipe = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = invocation.input == nil ? FileHandle.nullDevice : inPipe

        let collector = OutputCollector()
        out.fileHandleForReading.readabilityHandler = { h in collector.append(h.availableData, stderr: false) }
        err.fileHandleForReading.readabilityHandler = { h in collector.append(h.availableData, stderr: true) }

        return try await withTaskCancellationHandler {
            do { try process.run() } catch { throw CommandRunnerError.launchFailed("\(invocation.executable): \(error.localizedDescription)") }
            if let input = invocation.input {
                inPipe.fileHandleForWriting.write(input)
                try? inPipe.fileHandleForWriting.close()
            }
            let deadline = DispatchTime.now() + invocation.timeout
            let timedOut = TimeoutFlag()
            let timer = DispatchWorkItem { timedOut.set(); process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: deadline, execute: timer)
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    process.waitUntilExit()
                    c.resume()
                }
            }
            timer.cancel()
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            collector.append(out.fileHandleForReading.readDataToEndOfFile(), stderr: false)
            collector.append(err.fileHandleForReading.readDataToEndOfFile(), stderr: true)
            if timedOut.value { throw CommandRunnerError.timedOut(invocation.executable) }
            try Task.checkCancellation()
            let (o, e) = collector.snapshot()
            return CommandResult(status: process.terminationStatus, stdout: o, stderr: e)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func append(_ data: Data, stderr: Bool) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if stderr {
            if err.count < ProcessCommandRunner.outputLimit { err.append(data.prefix(ProcessCommandRunner.outputLimit - err.count)) }
        } else if out.count < ProcessCommandRunner.outputLimit {
            out.append(data.prefix(ProcessCommandRunner.outputLimit - out.count))
        }
    }

    func snapshot() -> (String, String) {
        lock.lock()
        defer { lock.unlock() }
        return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}

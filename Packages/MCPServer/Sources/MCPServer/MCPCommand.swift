import Foundation
import ModKit
import ModValidation

public enum MCPCommand {
    public static let usage = """
    betterfinder-mod mcp [--stdio | --http] [--port n] [--token-file path] [--workspaces dir] [--allow-origin url] [--no-live]
        Run the MCP authoring server. --stdio (default) speaks newline-delimited JSON-RPC on stdin/stdout and
        logs to stderr only. --http listens on 127.0.0.1 (random port unless --port) behind a bearer token written
        to --token-file (default ~/Library/Application Support/betterfinder/mcp-cli.json, mode 0600).
        Live tools (mod_load, mod_screenshot, mod_logs) talk to the running app through its mcp.json and report
        unavailable when the app is not running; --no-live disables them.

    """

    struct Options {
        var http = false
        var port: UInt16 = 0
        var tokenFile = MCPTokenFile.cliURL
        var workspaces: URL?
        var origins: [String] = []
        var live = true
    }

    struct UsageFailure: Error { var message: String }

    static func parse(_ args: [String]) -> Result<Options, UsageFailure> {
        var o = Options()
        var i = 0
        func value(_ name: String) -> String? {
            guard i < args.count else { return nil }
            defer { i += 1 }
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            i += 1
            switch a {
            case "--stdio": o.http = false
            case "--http": o.http = true
            case "--no-live": o.live = false
            case "--port":
                guard let v = value(a), let n = UInt16(v) else { return .failure(UsageFailure(message: "--port needs a number from 0 to 65535")) }
                o.port = n
            case "--token-file":
                guard let v = value(a) else { return .failure(UsageFailure(message: "--token-file needs a path")) }
                o.tokenFile = URL(fileURLWithPath: (v as NSString).expandingTildeInPath)
            case "--workspaces":
                guard let v = value(a) else { return .failure(UsageFailure(message: "--workspaces needs a folder")) }
                o.workspaces = URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true)
            case "--allow-origin":
                guard let v = value(a) else { return .failure(UsageFailure(message: "--allow-origin needs a URL origin")) }
                o.origins.append(v)
            default:
                return .failure(UsageFailure(message: "unknown option \(a)"))
            }
        }
        return .success(o)
    }

    public static func run(arguments: [String], io: CLIIO, validator: ModValidator, dryRunner: DryRunning) async throws -> Int32 {
        if arguments.contains("--help") || arguments.contains("-h") {
            io.out(usage)
            return 0
        }
        let options: Options
        switch parse(arguments) {
        case .failure(let failure):
            io.err("betterfinder-mod mcp: \(failure.message)\n")
            return 2
        case .success(let o): options = o
        }
        signal(SIGPIPE, SIG_IGN)
        let live: LiveModHosting = options.live ? RemoteLiveModHosting() : UnavailableLiveHosting(reason: "live tools were disabled with --no-live")
        let configuration = MCPServerConfiguration(
            validator: validator, dryRunner: dryRunner,
            workspaces: options.workspaces.map { ModWorkspaces(root: $0) } ?? ModWorkspaces(),
            live: live, serverVersion: ModCLI.toolVersion
        )
        if !options.http {
            let server = MCPServer(configuration: configuration)
            await StdioTransport(server: server).run()
            return 0
        }
        let host = MCPServerHost(MCPServerHostConfiguration(server: configuration, tokenFile: options.tokenFile, port: options.port, allowedOrigins: options.origins, exposeLiveBridge: false))
        let info: MCPEndpointInfo
        do { info = try await host.start() }
        catch {
            io.err("betterfinder-mod mcp: \(error.localizedDescription)\n")
            return 1
        }
        io.err("betterfinder-mod mcp listening on \(info.url)\npairing token written to \(options.tokenFile.path) (mode 0600); send it as 'Authorization: Bearer <token>'\n")
        await waitForTermination()
        host.stop()
        return 0
    }

    static func waitForTermination() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = ResumeOnce()
            for sig in [SIGINT, SIGTERM] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
                source.setEventHandler { if once.take() { continuation.resume() } }
                source.resume()
                SignalHolder.keep(source)
            }
        }
    }
}

enum SignalHolder {
    nonisolated(unsafe) static var sources = [DispatchSourceSignal]()
    static let lock = NSLock()
    static func keep(_ s: DispatchSourceSignal) { lock.lock(); sources.append(s); lock.unlock() }
}

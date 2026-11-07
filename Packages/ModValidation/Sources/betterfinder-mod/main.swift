import Foundation
import MCPServer
import ModHostRuntime
import ModValidation

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == HostDryRunner.hostCommand { ModHostStdioServer.run() }

let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
let wantsDryRun = ProcessInfo.processInfo.environment["BETTERFINDER_MOD_DRY_RUN"] != "0"
let needsHost = wantsDryRun && ["validate", "package", "scaffold", "index-entry", "mcp"].contains(arguments.first ?? "")
let host = needsHost ? HostDryRunner(executable: executable) : nil
let code = await ModCLI.run(arguments: arguments, dryRunner: host ?? NotRunDryRunner(), extensions: ["mcp": MCPCommand.run])
await host?.shutdown()
exit(code)

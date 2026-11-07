import Foundation
import ModHost
import ModKit
import ModValidation

final class HostDryRunner: DryRunning, @unchecked Sendable {
    static let hostCommand = "__modhost"

    let root: URL
    private let controller: ModHostController?
    private let failure: String?

    init(executable: URL) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("betterfinder-mod-dryrun-\(getpid())-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let transport = ModHostTransports.subprocess(executable, arguments: [Self.hostCommand])
        let options = ModRuntimeOptions(
            paths: ModHostPaths(root: root, caches: root.appendingPathComponent("Caches", isDirectory: true)),
            transport: transport, checkTransport: transport, developerMode: true
        )
        do {
            controller = try ModHostController(options: options)
            failure = nil
        } catch {
            controller = nil
            failure = error.localizedDescription
        }
    }

    func dryRun(package: ModPackage, compiled: CompiledMod) async -> [ModDiagnostic] {
        guard let controller else {
            return [ModDiagnostic(.checkNotRun, message: "dry run not performed: the dry-run host could not start (\(failure ?? "unknown error"))")]
        }
        return await ModHostDryRunner(controller: controller).dryRun(package: package, compiled: compiled)
    }

    func shutdown() async {
        await controller?.shutdown()
        try? FileManager.default.removeItem(at: root)
    }
}

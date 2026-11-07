import Foundation
import ModHostProtocol
import ModKit
import ModValidation

public final class ModHostDryRunner: DryRunning, @unchecked Sendable {
    public let controller: () -> ModHostController?

    public init(controller: @escaping () -> ModHostController?) { self.controller = controller }

    public convenience init(controller: ModHostController) { self.init(controller: { controller }) }

    public static func compiledScript(_ compiled: CompiledMod, treeHash: String, toolchain: String = ModCatalog.v1.toolchain) -> ModCompiledScript? {
        compiled.script.map { s in
            ModCompiledScript(
                treeHash: treeHash, toolchain: s.runtime == .jscIR ? toolchain : "ts",
                kind: (s.runtime == .jscIR ? ModScriptKind.bfscript : ModScriptKind.module).rawValue, source: s.executionSource
            )
        }
    }

    public func dryRun(package: ModPackage, compiled: CompiledMod) async -> [ModDiagnostic] {
        guard let controller = controller() else {
            return [ModDiagnostic(.checkNotRun, message: "dry run not performed: the mod runtime is not available")]
        }
        return await controller.dryRun(package: package, manifest: compiled.manifest, script: Self.compiledScript(compiled, treeHash: package.treeHash))
    }
}

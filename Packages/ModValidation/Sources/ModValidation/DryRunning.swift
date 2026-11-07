import Foundation
import ModKit

public struct CompiledScript: Sendable, Equatable {
    public var runtime: ModRuntime
    public var entry: String
    public var executionSource: String
    public var moduleSource: String?

    public init(runtime: ModRuntime, entry: String, executionSource: String, moduleSource: String? = nil) {
        self.runtime = runtime; self.entry = entry; self.executionSource = executionSource
        self.moduleSource = moduleSource
    }
}

public struct CompiledMod: Sendable {
    public var manifest: ModManifest
    public var script: CompiledScript?
    public var analysis: ScriptAnalysis?

    public init(manifest: ModManifest, script: CompiledScript?, analysis: ScriptAnalysis?) {
        self.manifest = manifest; self.script = script; self.analysis = analysis
    }
}

public protocol DryRunning: Sendable {
    func dryRun(package: ModPackage, compiled: CompiledMod) async -> [ModDiagnostic]
}

public struct NotRunDryRunner: DryRunning {
    public init() {}

    public func dryRun(package: ModPackage, compiled: CompiledMod) async -> [ModDiagnostic] {
        [ModDiagnostic(.checkNotRun, message: "dry run not performed: no dry-run host is configured in this build")]
    }
}

public typealias HostInfo = ModHostVersions

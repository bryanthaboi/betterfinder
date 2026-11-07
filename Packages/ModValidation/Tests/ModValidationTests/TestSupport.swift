import Foundation
import ModKit
import XCTest
@testable import ModValidation

final class Capture: @unchecked Sendable {
    var out = ""
    var err = ""
    var io: CLIIO { CLIIO(out: { self.out += $0 }, err: { self.err += $0 }) }
}

enum Support {
    static func tempDir(_ name: String = "mod") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bfmod-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.appendingPathComponent(name, isDirectory: true)
    }

    static func write(_ files: [ScaffoldFile], to dir: URL) {
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files {
            let url = dir.appendingPathComponent(f.path)
            try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! Data(f.contents.utf8).write(to: url)
        }
    }

    static func scaffold(_ template: ScaffoldTemplate, _ language: ScaffoldLanguage, id: String = "alice.test-mod", overrides: [String: String] = [:], remove: [String] = []) -> URL {
        var files = try! ModScaffold.files(id: id, language: language, template: template)
        files.removeAll { remove.contains($0.path) }
        for (path, text) in overrides {
            if let i = files.firstIndex(where: { $0.path == path }) { files[i].contents = text } else { files.append(ScaffoldFile(path: path, contents: text)) }
        }
        let dir = tempDir()
        write(files, to: dir)
        return dir
    }

    static func manifest(_ dir: URL, edit: (inout [String: Any]) -> Void) {
        let url = dir.appendingPathComponent("manifest.json")
        var obj = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        edit(&obj)
        try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: url)
    }

    static func run(_ source: ModPackageSource, host: HostInfo = .current, dry: DryRunning = NotRunDryRunner()) async -> ModValidationResult {
        await ModValidator.shared.run(source, host: host, dryRunner: dry)
    }

    static func codes(_ r: ModValidationResult) -> [String] { r.receipt.diagnostics.map(\.code.rawValue) }

    static func hasCode(_ r: ModValidationResult, _ code: ModDiagnosticCode, containing text: String? = nil) -> Bool {
        r.receipt.diagnostics.contains { $0.code == code && (text == nil || $0.message.contains(text!)) }
    }

    static func cli(_ args: [String]) async -> (code: Int32, out: String, err: String) {
        let c = Capture()
        let code = await ModCLI.run(arguments: args, io: c.io)
        return (code, c.out, c.err)
    }

    static func archive(of dir: URL) -> Data {
        ModPackaging.archive(package: PackageLoader.loadDirectory(dir))
    }
}

struct StubDryRunner: DryRunning {
    var diagnostics: [ModDiagnostic]
    var calls: CallCounter

    func dryRun(package: ModPackage, compiled: CompiledMod) async -> [ModDiagnostic] {
        calls.increment()
        return diagnostics
    }
}

final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    func increment() { lock.lock(); n += 1; lock.unlock() }
}

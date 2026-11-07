import FileOps
import Foundation
import ImageIO
import Integration
import ModHost
import ModKit
import Settings
import UniformTypeIdentifiers
import XCTest

struct PlainBookmarkCoder: BookmarkCoding {
    func makeBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) { (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false) }
    func startAccessing(_ url: URL) -> Bool { false }
    func stopAccessing(_ url: URL) {}
}

final class TestServices: ModHostServices, @unchecked Sendable {
    let lock = NSLock()
    var destination: URL?
    var allowExec = false
    var credential: String?
    var folder: URL?

    func pickDestination(modId: String, prompt: String) async -> URL? { lock.withLock { destination } }
    func confirmUnrestrictedExecution(modId: String, executable: String, arguments: [String]) async -> Bool { lock.withLock { allowExec } }
    func requestCredential(modId: String, name: String, destination: String) async -> String? { lock.withLock { credential } }
    func environment() async -> ModHostEnvironment {
        let folder = lock.withLock { self.folder }
        return ModHostEnvironment(locale: "en_US", dark: false, currentLocation: folder.map { ($0.path, $0.lastPathComponent, nil) }, currentFolder: folder)
    }
}

final class FakeResolver: ModHostResolving, @unchecked Sendable {
    var table: [String: [String]] = [:]
    func addresses(for host: String) -> [String] { table[host] ?? [] }
}

enum Runner {
    static var url: URL {
        let products = Bundle(for: TestEnv.self).bundleURL.deletingLastPathComponent()
        return products.appendingPathComponent("bf-modhost-runner")
    }
}

final class TestEnv: @unchecked Sendable {
    let root: URL
    let work: URL
    let access: ScopedAccessAuthorizer
    let services = TestServices()
    let resolver = FakeResolver()
    let registry = FileOperationHookRegistry()
    let runtime: ModHostController
    let sink: ModRecordingSink

    @MainActor
    init(transport: ModHostTransportFactory = ModHostTransports.inProcess(), configure: (inout ModRuntimeOptions) -> Void = { _ in }) throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("modhost-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let real = URL(fileURLWithPath: base.path).resolvingSymlinksInPath()
        root = real.appendingPathComponent("support", isDirectory: true)
        work = real.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let suite = "modhost.tests.\(UUID().uuidString)"
        access = ScopedAccessAuthorizer(defaults: UserDefaults(suiteName: suite)!, coder: PlainBookmarkCoder())
        var options = ModRuntimeOptions(paths: ModHostPaths(root: root), transport: transport, developerMode: true, settingsDefaults: { id in UserDefaults(suiteName: "\(suite).\(id)") })
        configure(&options)
        runtime = try ModHostController(options: options, dependencies: ModRuntimeDependencies(
            scopedAccess: access, services: services, hookRegistry: registry, resolver: resolver, secrets: InMemorySecretStore()
        ))
        sink = ModRecordingSink()
        runtime.attach(sink: sink, assets: nil)
    }

    func cleanup() async {
        await runtime.shutdown()
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func file(_ name: String, _ text: String) throws -> URL {
        let u = work.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
        return u
    }

    func png(_ name: String, width: Int, height: Int) throws -> URL {
        let u = work.appendingPathComponent(name)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(u as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return u
    }

    func mod(_ id: String, manifest: [String: Any], files: [String: String]) throws -> URL {
        let dir = work.appendingPathComponent("pkg-\(id)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var m: [String: Any] = [
            "manifestVersion": 1, "id": id, "name": id, "author": String(id.split(separator: ".").first!), "version": "1.0.0",
            "api": ">=1.0.0 <2.0.0", "app": ">=1.0.0 <2.0.0", "runtime": "ts/1", "entry": "scripts/main.ts", "license": "MIT",
            "permissions": [], "contributes": [:], "hooks": [], "settings": [], "dependencies": [], "conflicts": [],
        ]
        for (k, v) in manifest { m[k] = v }
        try JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("manifest.json"))
        for (path, text) in files {
            let u = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: u)
        }
        return dir
    }

    @discardableResult
    func install(_ dir: URL, approve: Bool = true, file: StaticString = #filePath, line: UInt = #line) async throws -> ModPreflightReport {
        let r = try await runtime.install(from: dir, developer: true)
        XCTAssertTrue(r.installed, "install refused: \(r.receipt.diagnostics.map { "\($0.code.rawValue) \($0.file ?? "") \($0.pointer ?? ""): \($0.message)" })", file: file, line: line)
        if approve, let m = r.manifest { try await runtime.approveAll(id: m.id) }
        return r
    }
}

func commandManifest(_ cmd: String, handler: String, permissions: [[String: Any]] = [], extraHooks: [[String: Any]] = [], contributes: [String: Any] = [:]) -> [String: Any] {
    var c = contributes
    var cmds = (c["commands"] as? [[String: Any]]) ?? []
    cmds.append(["id": cmd, "title": cmd, "handler": handler])
    c["commands"] = cmds
    return [
        "permissions": permissions,
        "contributes": c,
        "hooks": [["name": "command.run", "handler": handler, "version": 1]] + extraHooks,
    ]
}

func pid_alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

func eventually(timeout: TimeInterval = 5, _ check: () async -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if await check() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await check()
}

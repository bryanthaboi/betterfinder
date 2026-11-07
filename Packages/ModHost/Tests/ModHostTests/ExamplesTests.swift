import Foundation
import ModHost
import ModKit
import XCTest

@MainActor
final class ExamplesTests: XCTestCase {
    func example(_ id: String) throws -> URL { try XCTUnwrap(ModExamples.example(id)).directory }

    func testImageDimensionsColumn() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        let r = try await env.install(try example("image-dimensions"))
        XCTAssertEqual(r.receipt[.dryRun], .pass)
        try await env.runtime.enable(id: "alice.image-dimensions")
        XCTAssertEqual(env.sink.ids(owner: "alice.image-dimensions"), ["alice.image-dimensions/dimensions"])
        let provider = try XCTUnwrap(env.sink.entry("alice.image-dimensions/dimensions")?.column)
        let png = try env.png("a.png", width: 64, height: 48)
        let txt = try env.file("b.txt", "hello")
        let values = try await provider.values(for: [png, txt], revision: 1)
        XCTAssertEqual(values[png]?.text, "64×48")
        XCTAssertNil(values[txt]?.text)
    }

    func testMarkdownPreview() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        try await env.install(try example("markdown-previewer"))
        try await env.runtime.enable(id: "alice.markdown-previewer")
        let provider = try XCTUnwrap(env.sink.entry("alice.markdown-previewer/markdown")?.preview)
        let md = try env.file("README.md", "# Hello\n\nworld")
        let content = try await provider.render(md, maxBytes: 4096, dark: false)
        XCTAssertEqual(content.title, "README.md")
        XCTAssertEqual(content.node.kind, .markdown)
        XCTAssertEqual(content.node.text, "# Hello\n\nworld")
    }

    func testRecentDownloadsLocation() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        try await env.install(try example("recent-downloads"))
        let downloads = env.work.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: downloads.appendingPathComponent("old.zip"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: downloads.appendingPathComponent("old.zip").path)
        try Data("yy".utf8).write(to: downloads.appendingPathComponent("new.dmg"))
        try await env.runtime.enable(id: "alice.recent-downloads")
        let provider = try XCTUnwrap(env.sink.entry("alice.recent-downloads/recent-downloads")?.location)
        let unbound = try await provider.list(path: "", limit: 50, cursor: nil)
        XCTAssertTrue(unbound.items.isEmpty)
        try env.runtime.bindRoot(id: "alice.recent-downloads", rootId: "downloads", to: downloads)
        let page = try await provider.list(path: "", limit: 50, cursor: nil)
        XCTAssertEqual(page.items.map(\.name), ["new.dmg", "old.zip"])
        XCTAssertEqual(page.items.first?.size, 2)
        XCTAssertEqual(env.sink.ids(owner: "alice.recent-downloads", kind: .sidebar), ["alice.recent-downloads/downloads"])
    }

    func testZipSelectionCommand() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        try await env.install(try example("zip-selection"))
        try await env.runtime.enable(id: "alice.zip-selection")
        XCTAssertEqual(env.sink.ids(owner: "alice.zip-selection"), ["alice.zip-selection/zip", "alice.zip-selection/zip-selection"])
        let out = env.work.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        env.services.lock.withLock { env.services.destination = out }
        let a = try env.file("docs/a.txt", "alpha")
        let b = try env.file("docs/b.txt", "beta")
        let runner = try XCTUnwrap(env.sink.entry("alice.zip-selection/zip-selection")?.command)
        let result = try await runner.run(selection: [a, b], args: nil)
        XCTAssertEqual(result.message, "Zipping 2 items")
        XCTAssertNotNil(result.operationId)
        let archive = out.appendingPathComponent("Archive.zip")
        let made = await eventually { FileManager.default.fileExists(atPath: archive.path) }
        XCTAssertTrue(made)
        let empty = try await runner.run(selection: [], args: nil)
        XCTAssertEqual(empty.message, "Select something to zip first")
    }

    func testPinnedFoldersDataMod() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        let r = try await env.install(try example("pinned-folders"))
        XCTAssertTrue(r.receipt.ok)
        try await env.runtime.enable(id: "alice.pinned-folders")
        XCTAssertEqual(env.sink.ids(owner: "alice.pinned-folders"), ["alice.pinned-folders/go-downloads", "alice.pinned-folders/pinned"])
        XCTAssertNil(env.runtime.hostProcessIdentifier)
        try await env.runtime.disable(id: "alice.pinned-folders")
        XCTAssertTrue(env.sink.ids(owner: "alice.pinned-folders").isEmpty)
    }

    func testAllExamplesPassPreflight() async throws {
        let env = try TestEnv()
        defer { Task { await env.cleanup() } }
        for ex in ModExamples.all {
            let report = await env.runtime.preflight(directory: ex.directory)
            XCTAssertTrue(report.receipt.ok, "\(ex.id): \(report.receipt.diagnostics.map(\.message))")
        }
    }
}

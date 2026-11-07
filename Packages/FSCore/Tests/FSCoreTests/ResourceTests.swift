import XCTest
@testable import FSCore

final class ResourceTests: XCTestCase {
    func testLocalProviderListsLikeDirectoryLister() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fscore-res-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data().write(to: dir.appendingPathComponent(".hidden"))
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = LocalResourceProvider()
        let id = ResourceID.local(dir)
        let items = try await p.listAll(id, options: ResourceListOptions(showHidden: false))
        let lister = try DirectoryLister.list(dir)
        XCTAssertEqual(Set(items.map(\.name)), Set(lister.map(\.name)))
        XCTAssertEqual(items.first { $0.name == "a.txt" }?.size, 3)
        XCTAssertEqual(items.first { $0.name == "sub" }?.isDirectory, true)
        let slice = try await p.read(id.appending("a.txt"), range: 1..<3)
        XCTAssertEqual(slice, Data("bc".utf8))
        XCTAssertEqual(p.parent(of: id), ResourceID.local(dir.deletingLastPathComponent()))
        XCTAssertTrue(p.capabilities.canTrash && p.capabilities.canWatch && p.capabilities.canUndo)
        let stat = try await p.stat(id.appending("a.txt"))
        XCTAssertEqual(stat.contentTypeIdentifier, "public.plain-text")
    }

    func testRegistryRejectsDuplicatesAndUnregisters() throws {
        let r = ResourceProviderRegistry()
        let t = try r.register(LocalResourceProvider(), owner: "a")
        XCTAssertThrowsError(try r.register(LocalResourceProvider(), owner: "b"))
        XCTAssertEqual(r.owner(of: "file"), "a")
        t.cancel()
        XCTAssertNil(r.provider(for: "file"))
        XCTAssertNotNil(ResourceProviderRegistry.shared.provider(for: ResourceID.localProviderID))
    }

    func testResourceIDHelpers() {
        let id = ResourceID(providerID: "x", path: "/a/b")
        XCTAssertEqual(id.name, "b")
        XCTAssertEqual(id.lexicalParent?.path, "/a")
        XCTAssertTrue(id.isDescendant(of: ResourceID(providerID: "x", path: "/a")))
        XCTAssertFalse(id.isDescendant(of: ResourceID(providerID: "x", path: "/ab")))
        XCTAssertFalse(id.isDescendant(of: ResourceID(providerID: "y", path: "/a")))
        XCTAssertEqual(ResourceID(providerID: "x", path: "/").appending("c").path, "/c")
        XCTAssertNil(ResourceID(uri: URL(string: "https://x/a")!))
    }

    func testFileDigest() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("digest-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: u)
        defer { try? FileManager.default.removeItem(at: u) }
        let d = try FileDigest.compute(u, chunkSize: 1)
        XCTAssertEqual(d.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(d.md5, "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(d.size, 3)
    }
}

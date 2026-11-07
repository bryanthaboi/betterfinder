import Carbon.HIToolbox
import XCTest
@testable import Integration

final class FakeBookmarkCoder: BookmarkCoding, @unchecked Sendable {
    var accessed: [URL] = []
    var stopped: [URL] = []
    var failResolve = false

    func makeBookmark(for url: URL) throws -> Data { Data(url.path.utf8) }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        if failResolve { throw NSError(domain: "fake", code: 1) }
        return (URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), false)
    }

    func startAccessing(_ url: URL) -> Bool { accessed.append(url); return true }
    func stopAccessing(_ url: URL) { stopped.append(url) }
}

final class Clock: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ s: TimeInterval) { date = date.addingTimeInterval(s) }
}

final class ScopedAccessTests: XCTestCase {
    var dirs: [URL] = []
    var suites: [String] = []

    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        dirs = []
        suites = []
        super.tearDown()
    }

    func tempDir(_ name: String = UUID().uuidString) -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("bf-scope-\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dirs.append(d)
        return d.resolvingSymlinksInPath()
    }

    func defaults() -> UserDefaults {
        let name = "bf-scope-\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    func make(_ d: UserDefaults? = nil, coder: BookmarkCoding = FakeBookmarkCoder(), clock: Clock = Clock()) -> ScopedAccessAuthorizer {
        ScopedAccessAuthorizer(defaults: d ?? defaults(), coder: coder, now: { clock.date })
    }

    func testRootGrantAllowsDescendantsOnly() throws {
        let root = tempDir()
        let child = root.appendingPathComponent("a/b.txt")
        try FileManager.default.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: child.path, contents: Data())
        let outside = tempDir()
        let auth = make()
        let granted = try auth.addRoot(root, modID: "m", purpose: "scan", mode: .read)

        XCTAssertEqual(auth.authorize(child, mode: .read, modID: "m", token: nil), .allowed(.root(granted.id)))
        XCTAssertEqual(auth.authorize(root, mode: .read, modID: "m", token: nil), .allowed(.root(granted.id)))
        XCTAssertEqual(auth.authorize(outside, mode: .read, modID: "m", token: nil), .denied(.outsideScope))
        XCTAssertEqual(auth.authorize(child, mode: .readWrite, modID: "m", token: nil), .denied(.insufficientMode))
        XCTAssertEqual(auth.authorize(child, mode: .read, modID: "other", token: nil), .denied(.noGrant))
        let traversal = root.appendingPathComponent("../\(outside.lastPathComponent)/x")
        XCTAssertFalse(auth.authorize(traversal, mode: .read, modID: "m", token: nil).isAllowed)
        XCTAssertEqual(auth.authorize(URL(string: "https://example.com")!, mode: .read, modID: "m", token: nil), .denied(.invalidPath))
    }

    func testSiblingPrefixIsNotContained() throws {
        let parent = tempDir()
        let a = parent.appendingPathComponent("docs", isDirectory: true)
        let b = parent.appendingPathComponent("docs-private", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        let auth = make()
        try auth.addRoot(a, modID: "m", purpose: "p", mode: .read)
        XCTAssertFalse(auth.authorize(b, mode: .read, modID: "m", token: nil).isAllowed)
    }

    func testSymlinkEscapeIsDenied() throws {
        let root = tempDir()
        let outside = tempDir()
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let auth = make()
        try auth.addRoot(root, modID: "m", purpose: "p", mode: .read)
        XCTAssertFalse(auth.authorize(link.appendingPathComponent("file"), mode: .read, modID: "m", token: nil).isAllowed)
    }

    func testRejectsInvalidRoots() {
        let auth = make()
        XCTAssertThrowsError(try auth.addRoot(URL(fileURLWithPath: "/"), modID: "m", purpose: "p", mode: .read))
        XCTAssertThrowsError(try auth.addRoot(URL(fileURLWithPath: "/definitely/missing"), modID: "m", purpose: "p", mode: .read))
        XCTAssertThrowsError(try auth.addRoot(URL(string: "https://x.test")!, modID: "m", purpose: "p", mode: .read))
        XCTAssertThrowsError(try auth.addRoot(tempDir(), modID: "", purpose: "p", mode: .read))
    }

    func testAddRootIsIdempotentAndUpgradesMode() throws {
        let root = tempDir()
        let auth = make()
        let a = try auth.addRoot(root, modID: "m", purpose: "p", mode: .read)
        let b = try auth.addRoot(root, modID: "m", purpose: "p", mode: .readWrite)
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(auth.roots(for: "m").count, 1)
        XCTAssertEqual(auth.roots(for: "m").first?.mode, .readWrite)
    }

    func testGrantsPersistAcrossInstancesAndStopAccessOnRemoval() throws {
        let root = tempDir()
        let d = defaults()
        let coder = FakeBookmarkCoder()
        let first = make(d, coder: coder)
        let granted = try first.addRoot(root, modID: "m", purpose: "p", mode: .read)

        let coder2 = FakeBookmarkCoder()
        let second = make(d, coder: coder2)
        XCTAssertEqual(second.roots(for: "m").map(\.id), [granted.id])
        XCTAssertEqual(coder2.accessed.count, 1)
        XCTAssertTrue(second.authorize(root.appendingPathComponent("x"), mode: .read, modID: "m", token: nil).isAllowed)

        second.removeRoot(granted.id)
        XCTAssertEqual(coder2.stopped.count, 1)
        XCTAssertTrue(make(d).roots(for: "m").isEmpty)
    }

    func testUnresolvableBookmarksAreDropped() throws {
        let d = defaults()
        let first = make(d)
        try first.addRoot(tempDir(), modID: "m", purpose: "p", mode: .read)
        let coder = FakeBookmarkCoder()
        coder.failResolve = true
        let second = make(d, coder: coder)
        XCTAssertTrue(second.roots(for: "m").isEmpty)
        XCTAssertTrue(make(d).roots(for: "m").isEmpty)
    }

    func testRealSecurityScopedBookmarkRoundTrip() throws {
        let root = tempDir()
        let d = defaults()
        let first = ScopedAccessAuthorizer(defaults: d, coder: SecurityScopedBookmarkCoder())
        do {
            try first.addRoot(root, modID: "m", purpose: "p", mode: .read)
        } catch {
            throw XCTSkip("security-scoped bookmarks unavailable here: \(error)")
        }
        let second = ScopedAccessAuthorizer(defaults: d, coder: SecurityScopedBookmarkCoder())
        XCTAssertEqual(second.roots(for: "m").first?.path, root.path)
    }

    func testSelectionTokenScopeExpiryAndOwnership() throws {
        let root = tempDir()
        let file = root.appendingPathComponent("a.txt")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let other = root.appendingPathComponent("b.txt")
        FileManager.default.createFile(atPath: other.path, contents: Data())
        let clock = Clock()
        let auth = make(clock: clock)

        let token = auth.issueSelectionToken(modID: "m", urls: [file], mode: .read, lifetime: 10)
        XCTAssertEqual(auth.authorize(file, mode: .read, modID: "m", token: token.id), .allowed(.selection(token.id)))
        XCTAssertEqual(auth.authorize(other, mode: .read, modID: "m", token: token.id), .denied(.outsideScope))
        XCTAssertEqual(auth.authorize(file, mode: .readWrite, modID: "m", token: token.id), .denied(.insufficientMode))
        XCTAssertEqual(auth.authorize(file, mode: .read, modID: "thief", token: token.id), .denied(.tokenBelongsToAnotherMod))
        XCTAssertEqual(auth.authorize(file, mode: .read, modID: "m", token: UUID()), .denied(.unknownToken))

        clock.advance(11)
        XCTAssertEqual(auth.authorize(file, mode: .read, modID: "m", token: token.id), .denied(.expiredToken))
        XCTAssertEqual(auth.authorize(file, mode: .read, modID: "m", token: token.id), .denied(.unknownToken))
    }

    func testSelectionTokenCoversDirectoryDescendantsAndCanBeRevoked() throws {
        let root = tempDir()
        let sub = root.appendingPathComponent("dir", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let auth = make()
        let token = auth.issueSelectionToken(modID: "m", urls: [sub], mode: .read, lifetime: 30)
        XCTAssertTrue(auth.authorize(sub.appendingPathComponent("deep/x"), mode: .read, modID: "m", token: token.id).isAllowed)
        auth.revokeSelectionToken(token.id)
        XCTAssertEqual(auth.authorize(sub, mode: .read, modID: "m", token: token.id), .denied(.unknownToken))
    }

    func testTokenLifetimeIsCapped() {
        let clock = Clock()
        let auth = make(clock: clock)
        let token = auth.issueSelectionToken(modID: "m", urls: [], mode: .read, lifetime: 86_400)
        XCTAssertEqual(token.expiresAt, clock.date.addingTimeInterval(ScopedAccessAuthorizer.maxTokenLifetime))
    }

    func testRemoveAllGrantsClearsRootsAndTokens() throws {
        let root = tempDir()
        let auth = make()
        try auth.addRoot(root, modID: "m", purpose: "p", mode: .read)
        let token = auth.issueSelectionToken(modID: "m", urls: [root], mode: .read, lifetime: 30)
        auth.removeAllGrants(for: "m")
        XCTAssertTrue(auth.roots(for: "m").isEmpty)
        XCTAssertEqual(auth.authorize(root, mode: .read, modID: "m", token: token.id), .denied(.unknownToken))
    }
}

final class FakePrompter: ExternalActionPrompting, @unchecked Sendable {
    var choice: ExternalApprovalChoice
    var requests: [ExternalOpenRequest] = []
    init(_ choice: ExternalApprovalChoice) { self.choice = choice }
    func requestApproval(_ request: ExternalOpenRequest) async -> ExternalApprovalChoice {
        requests.append(request)
        return choice
    }
}

final class FakeOpener: URLOpening, @unchecked Sendable {
    var opened: [URL] = []
    var succeeds = true
    func open(_ url: URL) async -> Bool {
        if succeeds { opened.append(url) }
        return succeeds
    }
}

final class ExternalActionBrokerTests: XCTestCase {
    var suites: [String] = []

    override func tearDown() {
        for s in suites { UserDefaults().removePersistentDomain(forName: s) }
        suites = []
        super.tearDown()
    }

    func make(_ choice: ExternalApprovalChoice, opener: FakeOpener = FakeOpener(), defaults: UserDefaults? = nil, permitted: @escaping @Sendable (String) -> Bool = { _ in true }) -> (ExternalActionBroker, FakePrompter, FakeOpener) {
        let name = "bf-ext-\(UUID().uuidString)"
        suites.append(name)
        let p = FakePrompter(choice)
        let b = ExternalActionBroker(defaults: defaults ?? UserDefaults(suiteName: name)!, prompter: p, opener: opener, isPermitted: permitted)
        return (b, p, opener)
    }

    func testAllowOncePromptsEveryTime() async throws {
        let (broker, prompter, opener) = make(.allowOnce)
        let url = URL(string: "https://example.com/docs")!
        try await broker.open(url, modID: "m", reason: "docs")
        try await broker.open(url, modID: "m")
        XCTAssertEqual(prompter.requests.count, 2)
        XCTAssertEqual(opener.opened.count, 2)
        XCTAssertEqual(prompter.requests.first?.scopeKey, "https://example.com")
        XCTAssertEqual(prompter.requests.first?.reason, "docs")
    }

    func testAllowAlwaysIsPerModAndPerHost() async throws {
        let (broker, prompter, opener) = make(.allowAlways)
        try await broker.open(URL(string: "https://example.com/a")!, modID: "m")
        try await broker.open(URL(string: "https://example.com/b")!, modID: "m")
        XCTAssertEqual(prompter.requests.count, 1)
        try await broker.open(URL(string: "https://example.com/b")!, modID: "other")
        try await broker.open(URL(string: "https://elsewhere.org/")!, modID: "m")
        XCTAssertEqual(prompter.requests.count, 3)
        XCTAssertEqual(opener.opened.count, 4)
        XCTAssertEqual(broker.approvals(for: "m"), ["https://elsewhere.org", "https://example.com"])

        broker.revokeApproval("https://example.com", for: "m")
        XCTAssertEqual(broker.approvals(for: "m"), ["https://elsewhere.org"])
        broker.revokeApprovals(for: "m")
        XCTAssertTrue(broker.approvals(for: "m").isEmpty)
    }

    func testDenyDoesNotOpen() async {
        let (broker, _, opener) = make(.deny)
        do {
            try await broker.open(URL(string: "https://example.com")!, modID: "m")
            XCTFail("expected denial")
        } catch {
            XCTAssertEqual(error as? ExternalActionError, .userDenied)
        }
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testRejectsDangerousURLsWithoutPrompting() async {
        let (broker, prompter, opener) = make(.allowAlways)
        let bad = ["file:///etc/passwd", "javascript:alert(1)", "x-apple.systempreferences:com.apple.preference", "https://user:pw@example.com/", "https://", "ssh://host"]
        for text in bad {
            do {
                try await broker.open(URL(string: text)!, modID: "m")
                XCTFail("opened \(text)")
            } catch {
                XCTAssertTrue(error is ExternalActionError, text)
            }
        }
        XCTAssertTrue(prompter.requests.isEmpty)
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testMailtoAndInsecureHTTPFlags() async throws {
        let (broker, prompter, _) = make(.allowOnce)
        try await broker.open(URL(string: "mailto:a@b.co")!, modID: "m")
        try await broker.open(URL(string: "http://example.com")!, modID: "m")
        XCTAssertEqual(prompter.requests[0].scopeKey, "mailto:")
        XCTAssertFalse(prompter.requests[0].isInsecure)
        XCTAssertTrue(prompter.requests[1].isInsecure)
    }

    func testModWithoutGrantCannotOpen() async {
        let (broker, prompter, _) = make(.allowOnce, permitted: { $0 == "ok" })
        do {
            try await broker.open(URL(string: "https://example.com")!, modID: "nope")
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? ExternalActionError, .notPermitted("nope"))
        }
        XCTAssertTrue(prompter.requests.isEmpty)
    }

    func testOpenFailureSurfaces() async {
        let opener = FakeOpener()
        opener.succeeds = false
        let (broker, _, _) = make(.allowOnce, opener: opener)
        do {
            try await broker.open(URL(string: "https://example.com")!, modID: "m")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? ExternalActionError, .openFailed)
        }
    }

    func testOverlongURLRejected() async {
        let (broker, _, _) = make(.allowOnce)
        let url = URL(string: "https://example.com/" + String(repeating: "a", count: 3000))!
        do {
            try await broker.open(url, modID: "m")
            XCTFail("expected rejection")
        } catch {
            XCTAssertEqual(error as? ExternalActionError, .invalidURL("too long"))
        }
    }
}

final class FakeHotKeyBackend: HotKeyBackend {
    var onPressed: ((UInt32) -> Void)?
    var registered: [UInt32: HotKeyCombo] = [:]
    var failNext: Int32?

    func register(_ combo: HotKeyCombo, id: UInt32) throws {
        if let status = failNext {
            failNext = nil
            throw GlobalBindingError.registrationFailed(status)
        }
        registered[id] = combo
    }

    func unregister(id: UInt32) { registered.removeValue(forKey: id) }
}

@MainActor
final class GlobalCommandBindingTests: XCTestCase {
    let mods = UInt32(controlKey | optionKey | cmdKey)

    func make(appReserved: [HotKeyCombo] = []) -> (GlobalCommandBindingRegistry, FakeHotKeyBackend) {
        let backend = FakeHotKeyBackend()
        return (GlobalCommandBindingRegistry(backend: backend, reservedByApp: { appReserved }), backend)
    }

    func combo(_ key: Int, _ m: UInt32? = nil) -> HotKeyCombo { HotKeyCombo(keyCode: UInt32(key), modifiers: m ?? mods) }

    func testRegisterRemoveToken() throws {
        let (registry, backend) = make()
        let token = try registry.register(GlobalCommandBinding(commandID: "a.go", combo: combo(kVK_ANSI_J)), owner: "a") {}
        XCTAssertEqual(backend.registered.count, 1)
        XCTAssertEqual(registry.bindings(owner: "a").count, 1)
        XCTAssertTrue(registry.remove(token))
        XCTAssertTrue(backend.registered.isEmpty)
        XCTAssertFalse(registry.remove(token))
    }

    func testTriggerRoutesToHandler() throws {
        let (registry, backend) = make()
        var fired: [String] = []
        try registry.register(GlobalCommandBinding(commandID: "one", combo: combo(kVK_ANSI_J)), owner: "a") { fired.append("one") }
        try registry.register(GlobalCommandBinding(commandID: "two", combo: combo(kVK_ANSI_K)), owner: "a") { fired.append("two") }
        let ids = backend.registered.sorted { $0.key < $1.key }.map(\.key)
        backend.onPressed?(ids[1])
        backend.onPressed?(ids[0])
        backend.onPressed?(9999)
        XCTAssertEqual(fired, ["two", "one"])
    }

    func testSystemReservedCombosRejected() {
        let (registry, backend) = make()
        let spotlight = combo(kVK_Space, UInt32(cmdKey))
        XCTAssertEqual(registry.check(spotlight), .systemReserved("Spotlight"))
        XCTAssertEqual(registry.check(combo(kVK_ANSI_Q, UInt32(cmdKey))), .systemReserved("Quit"))
        XCTAssertEqual(registry.check(combo(kVK_Tab, UInt32(cmdKey))), .systemReserved("App switcher"))
        XCTAssertThrowsError(try registry.register(GlobalCommandBinding(commandID: "x", combo: spotlight), owner: "a") {}) { error in
            XCTAssertEqual(error as? GlobalBindingError, .collision(.systemReserved("Spotlight")))
        }
        XCTAssertTrue(backend.registered.isEmpty)
    }

    func testReservedMatchIgnoresStrayModifierBits() {
        let (registry, _) = make()
        XCTAssertNotNil(registry.check(HotKeyCombo(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey | alphaLock))))
    }

    func testRequiresControlOrCommand() {
        let (registry, _) = make()
        XCTAssertNotNil(registry.check(combo(kVK_ANSI_J, UInt32(optionKey))))
        XCTAssertNotNil(registry.check(combo(kVK_ANSI_J, UInt32(shiftKey | optionKey))))
        XCTAssertNotNil(registry.check(combo(kVK_ANSI_J, 0)))
        XCTAssertNil(registry.check(combo(kVK_ANSI_J, UInt32(cmdKey | shiftKey))))
    }

    func testCollisionWithGlobalHotKey() {
        let mine = combo(kVK_ANSI_N)
        let (registry, _) = make(appReserved: [mine])
        XCTAssertEqual(registry.check(mine), .globalHotKey)
        XCTAssertThrowsError(try registry.register(GlobalCommandBinding(commandID: "x", combo: mine), owner: "a") {})
        XCTAssertNil(registry.check(combo(kVK_ANSI_M)))
    }

    func testCollisionBetweenMods() throws {
        let (registry, backend) = make()
        let c = combo(kVK_ANSI_J)
        let token = try registry.register(GlobalCommandBinding(commandID: "first", combo: c), owner: "a") {}
        XCTAssertThrowsError(try registry.register(GlobalCommandBinding(commandID: "second", combo: c), owner: "b") {}) { error in
            XCTAssertEqual(error as? GlobalBindingError, .collision(.modBinding(owner: "a", commandID: "first")))
        }
        XCTAssertThrowsError(try registry.register(GlobalCommandBinding(commandID: "dup", combo: c), owner: "a") {})
        XCTAssertEqual(backend.registered.count, 1)
        XCTAssertNil(registry.check(c, ignoring: token))
        registry.remove(token)
        XCTAssertNoThrow(try registry.register(GlobalCommandBinding(commandID: "second", combo: c), owner: "b") {})
    }

    func testBackendFailureLeavesNoBinding() {
        let (registry, backend) = make()
        backend.failNext = -9878
        XCTAssertThrowsError(try registry.register(GlobalCommandBinding(commandID: "x", combo: combo(kVK_ANSI_J)), owner: "a") {}) { error in
            XCTAssertEqual(error as? GlobalBindingError, .registrationFailed(-9878))
        }
        XCTAssertTrue(registry.bindings().isEmpty)
        XCTAssertNil(registry.check(combo(kVK_ANSI_J)))
    }

    func testRemoveAllByOwner() throws {
        let (registry, backend) = make()
        try registry.register(GlobalCommandBinding(commandID: "1", combo: combo(kVK_ANSI_J)), owner: "a") {}
        try registry.register(GlobalCommandBinding(commandID: "2", combo: combo(kVK_ANSI_K)), owner: "a") {}
        try registry.register(GlobalCommandBinding(commandID: "3", combo: combo(kVK_ANSI_L)), owner: "b") {}
        XCTAssertEqual(registry.removeAll(owner: "a"), 2)
        XCTAssertEqual(backend.registered.count, 1)
        XCTAssertEqual(registry.bindings().map(\.owner), ["b"])
    }
}

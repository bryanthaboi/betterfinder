import XCTest
@testable import Updates

final class ETagTests: XCTestCase {
    var defaults: UserDefaults!
    var suite = ""
    var prefs: UpdatePreferences!
    let feed = URL(string: "https://example.test/releases/latest")!

    override func setUp() {
        (defaults, suite) = makeDefaults()
        prefs = UpdatePreferences(defaults: defaults)
        MockURLProtocol.reset()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        MockURLProtocol.reset()
    }

    func makeChecker(current: String = "0.1.1", token: (@Sendable () -> String?)? = nil) -> UpdateChecker {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return UpdateChecker(
            configuration: UpdateCheckerConfiguration(feedURL: feed, currentVersion: current, tokenProvider: token, sessionConfiguration: config),
            preferences: prefs
        )
    }

    func testStoresETagAndSendsIfNoneMatch() async throws {
        let body = try fixtureData("release")
        MockURLProtocol.handler = { req in
            (MockURLProtocol.response(req.url!, status: 200, headers: ["ETag": "W/\"abc\""]), body)
        }
        let checker = makeChecker()
        let first = try await checker.check()
        guard case .updateAvailable(let release) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(release.versionString, "0.1.42")
        XCTAssertEqual(prefs.etag, "W/\"abc\"")
        XCTAssertNotNil(prefs.lastChecked)
        XCTAssertNil(MockURLProtocol.requests[0].value(forHTTPHeaderField: "If-None-Match"))

        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "If-None-Match"), "W/\"abc\"")
            return (MockURLProtocol.response(req.url!, status: 304), Data())
        }
        let second = try await checker.check()
        XCTAssertEqual(second, first)
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
    }

    func testNotModifiedWithoutCacheThrowsAndClears() async {
        prefs.etag = "\"stale\""
        MockURLProtocol.handler = { req in (MockURLProtocol.response(req.url!, status: 304), Data()) }
        do {
            _ = try await makeChecker().check()
            XCTFail("expected throw")
        } catch {
            XCTAssertNil(prefs.etag)
        }
        XCTAssertNil(MockURLProtocol.requests[0].value(forHTTPHeaderField: "If-None-Match"))
    }

    func testNotFoundIsGracefulNoInfo() async throws {
        prefs.etag = "\"old\""
        prefs.cachedReleaseData = try fixtureData("release")
        MockURLProtocol.handler = { req in
            (MockURLProtocol.response(req.url!, status: 404), Data(#"{"message":"Not Found"}"#.utf8))
        }
        let result = try await makeChecker().check()
        XCTAssertEqual(result, .noInfo(.notAccessible(404)))
        XCTAssertNil(prefs.etag)
        XCTAssertNil(prefs.cachedReleaseData)
        XCTAssertNotNil(prefs.lastChecked)
    }

    func testUnauthorizedIsNoInfo() async throws {
        MockURLProtocol.handler = { req in (MockURLProtocol.response(req.url!, status: 401), Data()) }
        let result = try await makeChecker().check()
        XCTAssertEqual(result, .noInfo(.notAccessible(401)))
    }

    func testRateLimitThrows() async {
        MockURLProtocol.handler = { req in
            (MockURLProtocol.response(req.url!, status: 403, headers: ["X-RateLimit-Remaining": "0"]), Data())
        }
        do {
            _ = try await makeChecker().check()
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? UpdateError, .rateLimited)
        }
    }

    func testTokenAndHeaders() async throws {
        let body = try fixtureData("release")
        MockURLProtocol.handler = { req in (MockURLProtocol.response(req.url!, status: 200), body) }
        _ = try await makeChecker(token: { "tok123" }).check()
        let req = MockURLProtocol.requests[0]
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok123")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertTrue(req.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("betterfinder-updater/") ?? false)
    }

    func testNoTokenNoAuthorizationHeader() async throws {
        let body = try fixtureData("release")
        MockURLProtocol.handler = { req in (MockURLProtocol.response(req.url!, status: 200), body) }
        _ = try await makeChecker(token: { nil }).check()
        XCTAssertNil(MockURLProtocol.requests[0].value(forHTTPHeaderField: "Authorization"))
    }

    func testServerErrorThrows() async {
        MockURLProtocol.handler = { req in (MockURLProtocol.response(req.url!, status: 500), Data()) }
        do {
            _ = try await makeChecker().check()
            XCTFail("expected throw")
        } catch {
            XCTAssertTrue(error is UpdateError)
        }
    }

    func testSkippedRespectedThroughCheck() async throws {
        let body = try fixtureData("release")
        MockURLProtocol.handler = { req in (MockURLProtocol.response(req.url!, status: 200), body) }
        prefs.skippedVersion = SemanticVersion("0.1.42")
        let auto = try await makeChecker().check(userInitiated: false)
        guard case .skipped = auto else { return XCTFail("\(auto)") }
        let manual = try await makeChecker().check(userInitiated: true)
        guard case .updateAvailable = manual else { return XCTFail("\(manual)") }
    }
}

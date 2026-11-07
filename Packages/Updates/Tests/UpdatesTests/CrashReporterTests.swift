import XCTest
@testable import Updates

final class CrashReporterTests: XCTestCase {
    var tmp: URL!
    var defaults: UserDefaults!
    var suite = ""

    override func setUpWithError() throws {
        tmp = try makeTempDirectory()
        (defaults, suite) = makeDefaults()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        defaults.removePersistentDomain(forName: suite)
    }

    @discardableResult
    func touch(_ name: String, at date: Date, content: String = "crash") throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    func testDiscoveryFiltersByPrefixExtensionAndDate() throws {
        let now = Date()
        try touch("betterfinder-2026-11-05-101010.ips", at: now.addingTimeInterval(-100))
        try touch("BetterFinderIndexer-2026-11-05-111111.ips", at: now.addingTimeInterval(-50))
        try touch("Finder-2026-11-05-101010.ips", at: now)
        try touch("betterfinder-old.ips", at: now.addingTimeInterval(-10_000))
        try touch("betterfinder-note.txt", at: now)
        try touch("betterfinder_legacy.crash", at: now.addingTimeInterval(-10))
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("Retired"), withIntermediateDirectories: true)
        try touch("Retired/betterfinder-retired.ips", at: now)

        let found = CrashDiscovery.find(in: tmp, newerThan: now.addingTimeInterval(-200))
        XCTAssertEqual(found.map(\.url.lastPathComponent), [
            "betterfinder_legacy.crash",
            "BetterFinderIndexer-2026-11-05-111111.ips",
            "betterfinder-2026-11-05-101010.ips",
        ])
        XCTAssertEqual(found[0].processName, "betterfinder_legacy")
        XCTAssertEqual(found[1].processName, "BetterFinderIndexer")
        XCTAssertEqual(found[2].processName, "betterfinder")
    }

    func testDiscoveryWithNoBaselineAndMissingDirectory() throws {
        try touch("betterfinder-a.ips", at: Date())
        XCTAssertEqual(CrashDiscovery.find(in: tmp, newerThan: nil).count, 1)
        XCTAssertTrue(CrashDiscovery.find(in: tmp.appendingPathComponent("nope"), newerThan: nil).isEmpty)
    }

    func testRedactsHomeDirectory() {
        let text = "/Users/alice/Library/Foo and /Users/alice\n/Users/bob/x \"/Users/carol/y\" /Users/Shared/z"
        let out = CrashRedactor.redact(text, homeDirectory: "/Users/alice")
        XCTAssertEqual(out, "~/Library/Foo and ~\n~/x \"~/y\" /Users/Shared/z")
    }

    func testRedactIgnoresRootHome() {
        XCTAssertEqual(CrashRedactor.redact("/a/b", homeDirectory: "/"), "/a/b")
    }

    func testExcerptLimitsLinesRedactsAndTruncates() {
        let lines = (0..<100).map { "line \($0) /Users/alice/file" }
        let out = CrashIssueBuilder.excerpt(from: lines.joined(separator: "\n"), maxLines: 60, homeDirectory: "/Users/alice")
        let split = out.components(separatedBy: "\n")
        XCTAssertEqual(split.count, 60)
        XCTAssertEqual(split[0], "line 0 ~/file")
        XCTAssertFalse(out.contains("alice"))
        let long = CrashIssueBuilder.excerpt(from: String(repeating: "x", count: 1000), maxLineLength: 50)
        XCTAssertEqual(long.count, 51)
    }

    func testSummaryParsesIpsBody() {
        let header = #"{"app_name":"betterfinder"}"#
        let body = #"{"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV","subtype":"KERN_INVALID_ADDRESS"},"termination":{"namespace":"SIGNAL","indicator":"Segmentation fault: 11"},"faultingThread":0,"usedImages":[{"name":"betterfinder"},{"name":"libsystem_kernel.dylib"}],"threads":[{"triggered":true,"frames":[{"imageIndex":0,"symbol":"FileList.reload","symbolLocation":44},{"imageIndex":1,"imageOffset":4096}]}]}"#
        let lines = CrashSummary.summarize(header + "\n" + body)
        XCTAssertEqual(lines[0], "Exception: EXC_BAD_ACCESS (SIGSEGV) KERN_INVALID_ADDRESS")
        XCTAssertEqual(lines[1], "Termination: SIGNAL Segmentation fault: 11")
        XCTAssertEqual(lines[2], "Crashed thread 0:")
        XCTAssertEqual(lines[3], "0  betterfinder  FileList.reload+44")
        XCTAssertEqual(lines[4], "1  libsystem_kernel.dylib  0x1000")
        XCTAssertTrue(CrashSummary.summarize("not json").isEmpty)
    }

    func testIssueURLIsEncodedAndBounded() throws {
        let report = CrashReport(url: tmp.appendingPathComponent("betterfinder-x.ips"), modified: Date(), processName: "betterfinder")
        let big = (0..<80).map { _ in String(repeating: "a&b+c d#e?", count: 24) }.joined(separator: "\n")
        let issue = CrashIssueBuilder.build(report: report, crashText: big, appVersion: "0.1.42", buildNumber: "42", osVersion: "Version 26.3", homeDirectory: "/Users/alice")
        XCTAssertLessThanOrEqual(issue.url.absoluteString.count, CrashIssueBuilder.maxURLLength)
        XCTAssertEqual(issue.title, "Crash: betterfinder 0.1.42")
        XCTAssertTrue(issue.body.contains("**App:** betterfinder 0.1.42 (42)"))
        XCTAssertTrue(issue.body.contains("**macOS:** Version 26.3"))
        let comps = URLComponents(url: issue.url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.host, "github.com")
        XCTAssertEqual(comps.path, "/bryanthaboi/betterfinder/issues/new")
        XCTAssertEqual(comps.queryItems?.first(where: { $0.name == "title" })?.value, issue.title)
        XCTAssertEqual(comps.queryItems?.first(where: { $0.name == "body" })?.value, issue.body)
        XCTAssertFalse(issue.url.absoluteString.contains("+"))
    }

    @MainActor
    func reporter(presentResult: Bool, opened: UnsafeMutablePointer<[URL]>, presented: UnsafeMutablePointer<Int>) -> CrashReporter {
        CrashReporter(
            directory: tmp,
            preferences: UpdatePreferences(defaults: defaults),
            openURL: { opened.pointee.append($0) },
            present: { _, _ in presented.pointee += 1; return presentResult },
            appVersion: { "0.1.42" },
            buildNumber: { "42" },
            osVersion: { "macOS test" }
        )
    }

    @MainActor
    func testFirstRunSetsBaselineWithoutPrompting() async throws {
        try touch("betterfinder-old.ips", at: Date().addingTimeInterval(-5000))
        var opened: [URL] = []
        var presented = 0
        let r = reporter(presentResult: true, opened: &opened, presented: &presented)
        let result = await r.checkNow()
        XCTAssertNil(result)
        XCTAssertEqual(presented, 0)
        XCTAssertNotNil(r.preferences.lastSeenCrash)
    }

    @MainActor
    func testNewCrashPromptsAndOpensOnlyOnAccept() async throws {
        var opened: [URL] = []
        var presented = 0
        let r = reporter(presentResult: false, opened: &opened, presented: &presented)
        r.preferences.lastSeenCrash = Date().addingTimeInterval(-1000)
        try touch("betterfinder-new.ips", at: Date().addingTimeInterval(-10), content: "hello /Users/alice/x")

        let declined = await r.checkNow()
        XCTAssertNotNil(declined)
        XCTAssertEqual(presented, 1)
        XCTAssertTrue(opened.isEmpty)

        let again = await r.checkNow()
        XCTAssertNil(again)
        XCTAssertEqual(presented, 1)

        r.present = { _, _ in presented += 1; return true }
        r.preferences.lastSeenCrash = Date().addingTimeInterval(-1000)
        _ = await r.checkNow()
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(opened[0].host, "github.com")
        XCTAssertFalse(opened[0].absoluteString.contains("alice"))
    }

    @MainActor
    func testDisabledNeverPrompts() async throws {
        var opened: [URL] = []
        var presented = 0
        let r = reporter(presentResult: true, opened: &opened, presented: &presented)
        r.isEnabled = false
        r.preferences.lastSeenCrash = Date().addingTimeInterval(-1000)
        try touch("betterfinder-new.ips", at: Date())
        let result = await r.checkNow()
        XCTAssertNil(result)
        XCTAssertEqual(presented, 0)
        XCTAssertTrue(opened.isEmpty)
    }
}

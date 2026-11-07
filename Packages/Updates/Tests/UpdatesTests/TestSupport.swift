import Foundation
import XCTest
@testable import Updates

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        handler = nil
        requests = []
    }

    static func response(_ url: URL, status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }
}

func makeDefaults() -> (UserDefaults, String) {
    let name = "updates-tests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

func makeTempDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("updates-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func fixtureData(_ name: String) throws -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
    return try Data(contentsOf: url)
}

func makeFakeApp(at url: URL, bundleID: String, version: String, marker: String = "x") throws {
    let contents = url.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
    let plist: [String: Any] = [
        "CFBundleIdentifier": bundleID,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": "1",
        "CFBundleExecutable": "app",
        "CFBundlePackageType": "APPL",
    ]
    try (plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
    try marker.write(to: contents.appendingPathComponent("MacOS/app"), atomically: true, encoding: .utf8)
}

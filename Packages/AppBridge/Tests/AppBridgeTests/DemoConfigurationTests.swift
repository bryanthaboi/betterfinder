import XCTest
import ModHost
import Settings
@testable import AppBridge

final class DemoConfigurationTests: XCTestCase {
    @MainActor
    func testDemoDoesNotUseXPCOrRealSecrets() throws {
        let saved = ProcessInfo.processInfo.environment["BETTERFINDER_DEMO"]
        defer {
            if let saved { setenv("BETTERFINDER_DEMO", saved, 1) } else { unsetenv("BETTERFINDER_DEMO") }
        }
        setenv("BETTERFINDER_DEMO", "1", 1)
        let config = AppModRuntime.Configuration.standard
        XCTAssertTrue(try config.transport.makeTransport() is InProcessModHostTransport)
        XCTAssertTrue(try config.checkTransport?.makeTransport() is InProcessModHostTransport)
        XCTAssertTrue(config.secrets is InMemorySecretStore)
        XCTAssertTrue(config.credentials is InMemorySecretStore)
        XCTAssertFalse(config.globalKeybindings)
    }
}

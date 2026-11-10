import Foundation
import Security

public enum UpdateRequirement {
    public static let bundleIdentifier = "com.bryanthaboi.betterfinder"
    public static let teamIdentifier = "2239U5J89G"

    public static func requirementString(bundleIdentifier: String = UpdateRequirement.bundleIdentifier, teamIdentifier: String = UpdateRequirement.teamIdentifier) -> String {
        "anchor apple generic and identifier \"\(escape(bundleIdentifier))\" and certificate leaf[subject.OU] = \"\(escape(teamIdentifier))\""
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

public struct UpdateVerifier: Sendable {
    public var expectedBundleIdentifier: String
    public var teamIdentifier: String
    public var currentVersion: SemanticVersion?

    public init(expectedBundleIdentifier: String = UpdateRequirement.bundleIdentifier, teamIdentifier: String = UpdateRequirement.teamIdentifier, currentVersion: SemanticVersion?) {
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.currentVersion = currentVersion
    }

    public var requirement: String {
        UpdateRequirement.requirementString(bundleIdentifier: expectedBundleIdentifier, teamIdentifier: teamIdentifier)
    }

    public func verify(appURL: URL, release: UpdateRelease?, checkNotarization: Bool = true, checkSignature: Bool = true) throws {
        let info = try verifyIdentity(appURL: appURL)
        if let release, info.version < release.version {
            throw UpdateError.verificationFailed("app version \(info.version) is older than release \(release.version)")
        }
        if checkSignature { try verifySignature(appURL: appURL) }
        if checkNotarization { try verifyNotarization(appURL: appURL) }
    }

    @discardableResult
    public func verifyIdentity(appURL: URL) throws -> (bundleIdentifier: String, version: SemanticVersion) {
        guard let bundle = Bundle(url: appURL), let id = bundle.bundleIdentifier else {
            throw UpdateError.verificationFailed("the downloaded app has no bundle identifier")
        }
        guard id == expectedBundleIdentifier else {
            throw UpdateError.verificationFailed("bundle identifier \(id) is not \(expectedBundleIdentifier)")
        }
        guard let versionString = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let version = SemanticVersion(versionString) else {
            throw UpdateError.verificationFailed("the downloaded app has no readable version")
        }
        if let currentVersion, version <= currentVersion {
            throw UpdateError.verificationFailed("version \(version) is not newer than \(currentVersion)")
        }
        return (id, version)
    }

    public func verifySignature(appURL: URL) throws {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode)
        guard status == errSecSuccess, let code = staticCode else {
            throw UpdateError.verificationFailed("couldn't read code signature (\(status))")
        }
        var req: SecRequirement?
        status = SecRequirementCreateWithString(requirement as CFString, [], &req)
        guard status == errSecSuccess, let req else {
            throw UpdateError.verificationFailed("invalid signing requirement (\(status))")
        }
        var errors: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        status = SecStaticCodeCheckValidityWithErrors(code, flags, req, &errors)
        if status != errSecSuccess {
            let detail = errors?.takeRetainedValue().localizedDescription ?? "status \(status)"
            throw UpdateError.verificationFailed("code signature check failed: \(detail)")
        }
    }

    public func verifyNotarization(appURL: URL) throws {
        let result = Self.run("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=4", appURL.path])
        guard result.status == 0 else {
            throw UpdateError.verificationFailed("Gatekeeper rejected the app: \(Self.firstLine(result.output))")
        }
        guard result.output.contains("Notarized Developer ID") else {
            throw UpdateError.verificationFailed("the app is not notarized")
        }
    }

    static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "no details"
    }

    static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error.localizedDescription)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

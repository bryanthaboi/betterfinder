import Foundation

public struct PreparedUpdate: Sendable {
    public let release: UpdateRelease
    public let appURL: URL
    public let stagingDirectory: URL
}

public enum InstallLocation {
    public static func validate(bundleURL: URL, fileManager: FileManager = .default) throws {
        let path = bundleURL.standardizedFileURL.path
        guard bundleURL.pathExtension == "app" else {
            throw UpdateError.notInstallable("betterfinder isn't running from an app bundle, so it can't update itself.")
        }
        if path.contains("/AppTranslocation/") {
            throw UpdateError.notInstallable("betterfinder is running from a quarantined location. Move betterfinder.app to /Applications, open it from there, then check for updates again.")
        }
        if path.hasPrefix("/Volumes/"), !fileManager.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path) {
            throw UpdateError.notInstallable("betterfinder is running from a read-only disk image. Drag it to /Applications and open it from there.")
        }
        let parent = bundleURL.deletingLastPathComponent().path
        guard fileManager.isWritableFile(atPath: parent) else {
            throw UpdateError.notInstallable("betterfinder can't replace itself because \((parent as NSString).abbreviatingWithTildeInPath) isn't writable. Move betterfinder.app to /Applications or ~/Applications and try again.")
        }
        guard fileManager.isDeletableFile(atPath: path) else {
            throw UpdateError.notInstallable("betterfinder can't be replaced at \((path as NSString).abbreviatingWithTildeInPath). Move it to /Applications or ~/Applications and try again.")
        }
    }
}

public protocol UpdateInstalling: Sendable {
    func prepare(_ release: UpdateRelease, progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedUpdate
    func install(_ prepared: PreparedUpdate) throws
}

public final class UpdateInstaller: UpdateInstalling, @unchecked Sendable {
    public static let relaunchScript = """
    trap '' HUP
    PID="$1"; NEW="$2"; DEST="$3"; STAGE="$4"; LOG="$5"
    OPENER="${BF_OPEN:-/usr/bin/open}"
    exec >>"$LOG" 2>&1
    echo "$(date) waiting for $PID"
    i=0
    while kill -0 "$PID" 2>/dev/null; do
      i=$((i+1))
      if [ "$i" -gt 1500 ]; then echo "timed out waiting for app to quit"; rm -rf "$STAGE"; exit 1; fi
      sleep 0.2
    done
    PARENT="$(dirname "$DEST")"
    NAME="$(basename "$DEST" .app)"
    TMP="$PARENT/.$NAME.update.$$.app"
    TRASH="$HOME/.Trash"
    mkdir -p "$TRASH"
    OLD="$TRASH/$NAME $(date +%Y-%m-%d-%H%M%S).app"
    rm -rf "$TMP"
    if ! /usr/bin/ditto "$NEW" "$TMP"; then echo "ditto failed"; rm -rf "$TMP"; "$OPENER" "$DEST"; exit 1; fi
    if ! mv "$DEST" "$OLD"; then echo "could not move old app aside"; rm -rf "$TMP"; "$OPENER" "$DEST"; exit 1; fi
    if ! mv "$TMP" "$DEST"; then echo "swap failed, restoring"; mv "$OLD" "$DEST"; rm -rf "$TMP"; "$OPENER" "$DEST"; exit 1; fi
    /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
    rm -rf "$STAGE"
    echo "$(date) installed, relaunching"
    "$OPENER" "$DEST"
    """

    public let verifier: UpdateVerifier
    public let cachesDirectory: URL
    public let bundleURL: URL
    public let processID: Int32
    private let tokenProvider: (@Sendable () -> String?)?
    private let sessionConfiguration: URLSessionConfiguration
    private let checkNotarization: Bool

    public init(
        verifier: UpdateVerifier,
        tokenProvider: (@Sendable () -> String?)? = nil,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        cachesDirectory: URL = UpdateInstaller.defaultCachesDirectory(),
        bundleURL: URL = Bundle.main.bundleURL,
        processID: Int32 = ProcessInfo.processInfo.processIdentifier,
        checkNotarization: Bool = true
    ) {
        self.verifier = verifier
        self.tokenProvider = tokenProvider
        self.sessionConfiguration = sessionConfiguration
        self.cachesDirectory = cachesDirectory
        self.bundleURL = bundleURL
        self.processID = processID
        self.checkNotarization = checkNotarization
    }

    public static func defaultCachesDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("com.bryanthaboi.betterfinder", isDirectory: true).appendingPathComponent("Updates", isDirectory: true)
    }

    public func downloadRequest(for asset: UpdateAsset) -> URLRequest {
        let token = tokenProvider?().flatMap { $0.isEmpty ? nil : $0 }
        var request: URLRequest
        if let token, let api = asset.apiURL {
            request = URLRequest(url: api)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            request = URLRequest(url: asset.downloadURL)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        }
        request.setValue("betterfinder-updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        return request
    }

    public func prepare(_ release: UpdateRelease, progress: @escaping @Sendable (Double) -> Void) async throws -> PreparedUpdate {
        try InstallLocation.validate(bundleURL: bundleURL)
        guard let asset = release.zipAsset else { throw UpdateError.noZipAsset }
        let fm = FileManager.default
        let stage = cachesDirectory.appendingPathComponent(release.versionString, isDirectory: true)
        try? fm.removeItem(at: cachesDirectory)
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)

        let zip = stage.appendingPathComponent(asset.name)
        let downloader = UpdateDownloader(configuration: sessionConfiguration, destination: zip, expectedSize: asset.size, progress: progress)
        _ = try await downloader.download(downloadRequest(for: asset))
        try Task.checkCancellation()

        if let expected = asset.sha256 {
            let actual = try UpdateDownloader.sha256(of: zip)
            guard actual == expected else { throw UpdateError.checksumMismatch }
        }

        let unpacked = stage.appendingPathComponent("unpacked", isDirectory: true)
        let app = try unpack(zip: zip, into: unpacked)
        try verifier.verify(appURL: app, release: release, checkNotarization: checkNotarization)
        try? fm.removeItem(at: zip)
        return PreparedUpdate(release: release, appURL: app, stagingDirectory: cachesDirectory)
    }

    public func unpack(zip: URL, into directory: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = UpdateVerifier.run("/usr/bin/ditto", ["-x", "-k", zip.path, directory.path])
        guard result.status == 0 else {
            throw UpdateError.extractionFailed(UpdateVerifier.firstLine(result.output))
        }
        let items = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let apps = items.filter { $0.pathExtension == "app" }
        guard apps.count == 1, let app = apps.first else {
            throw UpdateError.extractionFailed("expected exactly one app in the archive")
        }
        return app
    }

    public func relaunchArguments(for prepared: PreparedUpdate, logURL: URL? = nil) -> [String] {
        let log = logURL ?? cachesDirectory.deletingLastPathComponent().appendingPathComponent("update.log")
        return ["-c", Self.relaunchScript, "betterfinder-update", String(processID), prepared.appURL.path, bundleURL.path, prepared.stagingDirectory.path, log.path]
    }

    public func install(_ prepared: PreparedUpdate) throws {
        try InstallLocation.validate(bundleURL: bundleURL)
        let fm = FileManager.default
        try? fm.createDirectory(at: cachesDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = relaunchArguments(for: prepared)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .userInitiated
        do { try process.run() } catch {
            throw UpdateError.installFailed(error.localizedDescription)
        }
    }
}

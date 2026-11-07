// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "ModIndex", platforms: [.macOS(.v14)], products: [
    .library(name: "ModIndex", targets: ["ModIndex"]),
    .executable(name: "mod-index-tool", targets: ["ModIndexTool"])
], dependencies: [.package(path: "../ModKit"), .package(path: "../Settings")], targets: [
    .target(name: "ModIndex", dependencies: ["ModKit", "Settings"]),
    .executableTarget(name: "ModIndexTool", dependencies: ["ModIndex", "ModKit"]),
    .testTarget(name: "ModIndexTests", dependencies: ["ModIndex", "ModKit"])
], swiftLanguageModes: [.v5])

// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ModKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ModKit", targets: ["ModKit"])],
    targets: [
        .target(name: "ModKit", resources: [.copy("Resources")]),
        .testTarget(name: "ModKitTests", dependencies: ["ModKit"], exclude: ["Snapshots"], linkerSettings: [.linkedFramework("JavaScriptCore")]),
    ],
    swiftLanguageModes: [.v5]
)

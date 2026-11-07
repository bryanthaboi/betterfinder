// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Integration",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Integration", targets: ["Integration"])],
    targets: [
        .target(name: "Integration"),
        .testTarget(name: "IntegrationTests", dependencies: ["Integration"]),
    ],
    swiftLanguageModes: [.v5]
)

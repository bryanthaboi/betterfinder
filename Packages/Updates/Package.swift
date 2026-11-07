// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Updates",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Updates", targets: ["Updates"])],
    targets: [
        .target(name: "Updates"),
        .testTarget(
            name: "UpdatesTests",
            dependencies: ["Updates"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)

// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Remote",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Remote", targets: ["Remote"])],
    dependencies: [.package(path: "../FSCore"), .package(path: "../FileOps")],
    targets: [
        .target(
            name: "Remote",
            dependencies: [.product(name: "FSCore", package: "FSCore")],
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("CryptoKit")]
        ),
        .testTarget(
            name: "RemoteTests",
            dependencies: ["Remote", .product(name: "FSCore", package: "FSCore"), .product(name: "FileOps", package: "FileOps")],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)

// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MCPServer",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MCPServer", targets: ["MCPServer"]),
    ],
    dependencies: [
        .package(path: "../ModKit"),
        .package(path: "../ModValidation"),
    ],
    targets: [
        .target(
            name: "MCPServer",
            dependencies: [
                .product(name: "ModKit", package: "ModKit"),
                .product(name: "ModValidation", package: "ModValidation"),
            ]
        ),
        .testTarget(
            name: "MCPServerTests",
            dependencies: [
                "MCPServer",
                .product(name: "ModKit", package: "ModKit"),
                .product(name: "ModValidation", package: "ModValidation"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)

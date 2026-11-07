// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ModValidation",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ModValidation", targets: ["ModValidation"]),
        .executable(name: "betterfinder-mod", targets: ["betterfinder-mod"]),
    ],
    dependencies: [
        .package(path: "../ModKit"),
        .package(path: "../ModScriptTS"),
        .package(path: "../MCPServer"),
        .package(path: "../ModHost"),
    ],
    targets: [
        .target(
            name: "ModValidation",
            dependencies: [
                .product(name: "ModKit", package: "ModKit"),
                .product(name: "ModScriptTS", package: "ModScriptTS"),
            ]
        ),
        .executableTarget(
            name: "betterfinder-mod",
            dependencies: [
                "ModValidation",
                .product(name: "ModKit", package: "ModKit"),
                .product(name: "MCPServer", package: "MCPServer"),
                .product(name: "ModHost", package: "ModHost"),
                .product(name: "ModHostRuntime", package: "ModHost"),
                .product(name: "ModHostProtocol", package: "ModHost"),
            ]
        ),
        .testTarget(
            name: "ModValidationTests",
            dependencies: [
                "ModValidation",
                .product(name: "ModKit", package: "ModKit"),
                .product(name: "ModScriptTS", package: "ModScriptTS"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)

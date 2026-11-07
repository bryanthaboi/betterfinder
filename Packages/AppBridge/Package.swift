// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AppBridge",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AppBridge", targets: ["AppBridge"])],
    dependencies: [
        .package(path: "../FSCore"),
        .package(path: "../FileOps"),
        .package(path: "../Theming"),
        .package(path: "../Integration"),
        .package(path: "../Browser"),
        .package(path: "../Settings"),
        .package(path: "../ModKit"),
        .package(path: "../ModHost"),
        .package(path: "../ModIndex"),
    ],
    targets: [
        .target(
            name: "AppBridge",
            dependencies: [
                .product(name: "FSCore", package: "FSCore"),
                .product(name: "FileOps", package: "FileOps"),
                .product(name: "Theming", package: "Theming"),
                .product(name: "Integration", package: "Integration"),
                .product(name: "Browser", package: "Browser"),
                .product(name: "Settings", package: "Settings"),
                .product(name: "ModKit", package: "ModKit"),
                .product(name: "ModHost", package: "ModHost"),
                .product(name: "ModHostProtocol", package: "ModHost"),
                .product(name: "ModHostRuntime", package: "ModHost"),
                .product(name: "ModIndex", package: "ModIndex"),
            ],
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("CoreServices")]
        ),
        .testTarget(
            name: "AppBridgeTests",
            dependencies: [
                "AppBridge",
                .product(name: "FSCore", package: "FSCore"),
                .product(name: "Browser", package: "Browser"),
                .product(name: "Settings", package: "Settings"),
                .product(name: "ModKit", package: "ModKit"),
                .product(name: "ModHost", package: "ModHost"),
                .product(name: "ModIndex", package: "ModIndex"),
                .product(name: "Integration", package: "Integration"),
                .product(name: "FileOps", package: "FileOps"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)

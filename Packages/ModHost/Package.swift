// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ModHost",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ModHost", targets: ["ModHost"]),
        .library(name: "ModHostRuntime", targets: ["ModHostRuntime"]),
        .library(name: "ModHostProtocol", targets: ["ModHostProtocol"]),
        .executable(name: "bf-modhost-runner", targets: ["ModHostRunner"]),
    ],
    dependencies: [
        .package(path: "../ModKit"),
        .package(path: "../ModScriptTS"),
        .package(path: "../ModValidation"),
        .package(path: "../FileOps"),
        .package(path: "../Theming"),
        .package(path: "../Settings"),
        .package(path: "../Integration"),
    ],
    targets: [
        .target(
            name: "ModHostProtocol",
            dependencies: [.product(name: "ModKit", package: "ModKit")]
        ),
        .target(
            name: "ModHostRuntime",
            dependencies: ["ModHostProtocol", .product(name: "ModKit", package: "ModKit")],
            linkerSettings: [.linkedFramework("JavaScriptCore"), .linkedFramework("Security")]
        ),
        .target(
            name: "ModHost",
            dependencies: [
                "ModHostProtocol",
                "ModHostRuntime",
                .product(name: "ModKit", package: "ModKit"),
                .product(name: "ModScriptTS", package: "ModScriptTS"),
                .product(name: "ModValidation", package: "ModValidation"),
                .product(name: "FileOps", package: "FileOps"),
                .product(name: "Theming", package: "Theming"),
                .product(name: "Settings", package: "Settings"),
                .product(name: "Integration", package: "Integration"),
            ],
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("ImageIO")]
        ),
        .executableTarget(
            name: "ModHostRunner",
            dependencies: ["ModHostRuntime", "ModHostProtocol"]
        ),
        .executableTarget(
            name: "ModHostHTTPProbe",
            dependencies: ["ModHost", "ModHostProtocol"]
        ),
        .testTarget(
            name: "ModHostTests",
            dependencies: [
                "ModHost", "ModHostRuntime", "ModHostProtocol", "ModHostRunner", "ModHostHTTPProbe",
                .product(name: "ModKit", package: "ModKit"),
                .product(name: "ModValidation", package: "ModValidation"),
                .product(name: "ModScriptTS", package: "ModScriptTS"),
                .product(name: "FileOps", package: "FileOps"),
                .product(name: "Settings", package: "Settings"),
                .product(name: "Integration", package: "Integration"),
                .product(name: "Theming", package: "Theming"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)

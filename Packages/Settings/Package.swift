// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Settings",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Settings", targets: ["Settings"])],
    dependencies: [
        .package(path: "../Integration"),
        .package(path: "../Theming"),
        .package(path: "../FSCore"),
        .package(path: "../Updates"),
    ],
    targets: [
        .target(
            name: "Settings",
            dependencies: [
                .product(name: "Integration", package: "Integration"),
                .product(name: "Theming", package: "Theming"),
                .product(name: "FSCore", package: "FSCore"),
                .product(name: "Updates", package: "Updates"),
            ]
        ),
        .testTarget(name: "SettingsTests", dependencies: ["Settings"]),
    ],
    swiftLanguageModes: [.v5]
)

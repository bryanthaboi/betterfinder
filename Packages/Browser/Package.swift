// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Browser",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Browser", targets: ["Browser"])],
    dependencies: [
        .package(path: "../FSCore"),
        .package(path: "../FileOps"),
        .package(path: "../Theming"),
        .package(path: "../Integration"),
        .package(path: "../Remote"),
    ],
    targets: [
        .target(name: "Browser", dependencies: ["FSCore", "FileOps", "Theming", "Integration", "Remote"]),
        .testTarget(name: "BrowserTests", dependencies: ["Browser", "Remote"]),
    ],
    swiftLanguageModes: [.v5]
)

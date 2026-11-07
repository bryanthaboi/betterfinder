// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FileOps",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FileOps", targets: ["FileOps"])],
    dependencies: [.package(path: "../FSCore")],
    targets: [
        .target(name: "FileOps", dependencies: ["FSCore"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "FileOpsTests", dependencies: ["FileOps"]),
    ],
    swiftLanguageModes: [.v5]
)

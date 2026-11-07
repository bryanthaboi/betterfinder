// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FSCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "FSCore", targets: ["FSCore"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "FSCore", dependencies: ["CSQLite"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "SizeIndexBench", dependencies: ["FSCore"]),
        .testTarget(name: "FSCoreTests", dependencies: ["FSCore", "SizeIndexBench"]),
    ],
    swiftLanguageModes: [.v5]
)

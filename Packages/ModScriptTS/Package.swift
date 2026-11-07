// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ModScriptTS",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ModScriptTS", targets: ["ModScriptTS"])],
    targets: [
        .target(name: "ModScriptTS", resources: [.copy("Resources")], linkerSettings: [.linkedFramework("JavaScriptCore")]),
        .testTarget(name: "ModScriptTSTests", dependencies: ["ModScriptTS"])
    ],
    swiftLanguageModes: [.v5]
)

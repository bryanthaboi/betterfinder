// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Theming",
    platforms: [.macOS(.v14)],
    products: [.library(name: "Theming", targets: ["Theming"])],
    targets: [
        .target(name: "Theming", resources: [.copy("BuiltInThemes")]),
        .testTarget(name: "ThemingTests", dependencies: ["Theming"]),
    ],
    swiftLanguageModes: [.v5]
)

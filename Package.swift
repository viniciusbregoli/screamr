// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Screamr",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(name: "Screamr", path: "Sources/Screamr", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ScreamrTests", dependencies: ["Screamr"]),
    ]
)

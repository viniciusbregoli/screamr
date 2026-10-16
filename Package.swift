// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Screamr",
    platforms: [.macOS("14.4")],
    dependencies: [
        // On-device speaker embeddings (Core ML) for recognizing people across meetings.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7"),
    ],
    targets: [
        .executableTarget(
            name: "Screamr",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Screamr",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "ScreamrTests", dependencies: ["Screamr"]),
    ]
)

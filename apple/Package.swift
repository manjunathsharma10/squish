// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Squish",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Squish",
            path: "Sources/Squish",
            swiftSettings: [.unsafeFlags(["-Osize"], .when(configuration: .release))],
            linkerSettings: [.linkedLibrary("z")]
        )
    ]
)

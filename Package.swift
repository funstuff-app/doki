// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Doki",
    platforms: [.macOS(.v13)],
    targets: [
        // The Doki app + CLI.
        .executableTarget(name: "Doki", path: "Sources/Doki"),
        // Bundled helper that bounces its own Dock icon (for the self-demo).
        .executableTarget(name: "bouncer", path: "Sources/bouncer"),
    ],
    swiftLanguageModes: [.v5]
)

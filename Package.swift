// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeLimits",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClaudeLimits", path: "Sources/ClaudeLimits")
    ]
)

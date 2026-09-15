// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Doorbell",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "DoorbellApp",
            path: "Sources/DoorbellApp"
        )
    ]
)

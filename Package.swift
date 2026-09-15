// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Doorbell",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.55.0"),
        .package(url: "https://github.com/livekit/client-sdk-swift.git", from: "2.17.0"),
    ],
    targets: [
        .executableTarget(
            name: "DoorbellApp",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ],
            path: "Sources/DoorbellApp",
            exclude: ["Info.plist"],
            // `.copy` keeps Assets/Portraits/ as a folder; `.process` would flatten it.
            resources: [.copy("Assets/Portraits")],
            linkerSettings: [
                // Embed Info.plist so TCC has usage strings for camera/mic while we
                // run as a bare executable. An .app bundle replaces this later.
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", "Sources/DoorbellApp/Info.plist"])
            ]
        ),
        .testTarget(name: "DoorbellTests", dependencies: ["DoorbellApp"], path: "Tests/DoorbellTests")
    ]
)

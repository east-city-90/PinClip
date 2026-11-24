// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PinClip",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PinClip",
            path: "Sources/PinClip",
            resources: [
                .copy("Resources/AndroidSync")
            ]
        )
    ]
)

// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "sound-control-mac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "sound-control-mac",
            targets: ["SoundControlMac"]
        )
    ],
    targets: [
        .executableTarget(
            name: "SoundControlMac",
            path: "Sources/SoundControlMac"
        ),
        .testTarget(
            name: "SoundControlMacTests",
            dependencies: ["SoundControlMac"],
            path: "Tests/SoundControlMacTests"
        )
    ]
)

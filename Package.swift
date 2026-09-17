// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexProfiles",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "CodexProfiles", targets: ["CodexProfiles"]),
    ],
    targets: [
        .executableTarget(name: "CodexProfiles"),
        .testTarget(
            name: "CodexProfilesTests",
            dependencies: ["CodexProfiles"]
        ),
    ]
)

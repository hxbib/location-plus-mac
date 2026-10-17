// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocationPlus",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "LocationPlus",
            path: "Sources/LocationPlus",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

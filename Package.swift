// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flightdeck",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Flightdeck",
            path: "Sources/Flightdeck",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)

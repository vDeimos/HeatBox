// swift-tools-version:6.0
import PackageDescription

// The product is "HeatBox" (ADR-004, ADR-011). This is the executable's name,
// which cannot contain spaces; the display name is `Engine.productName`.
let productName = "StudioXPhobos"

let package = Package(
    name: productName,
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Engine", targets: ["Engine"]),
        .executable(name: productName, targets: ["App"]),
    ],
    targets: [
        // Foundation (and later SQLite3) only. Owns every decision.
        .target(name: "Engine", path: "Sources/Engine", swiftSettings: [.swiftLanguageMode(.v6)]),
        // SwiftUI + AppKit. Renders state, forwards intent.
        .executableTarget(name: "App", dependencies: ["Engine"], path: "Sources/App", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "EngineTests", dependencies: ["Engine"], path: "Tests/EngineTests", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Real yt-dlp, FFmpeg and ffprobe against generated media. Needs the tools installed.
        .testTarget(name: "IntegrationTests", dependencies: ["Engine", "QueueHarness"], path: "Tests/IntegrationTests", swiftSettings: [.swiftLanguageMode(.v5)]),
        // A stand-in for the app that the integration tests start and then kill
        // outright, to check what the next launch finds. Not part of the product.
        .executableTarget(name: "QueueHarness", dependencies: ["Engine"], path: "Tests/QueueHarness", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Toolbelt",
    platforms: [.macOS(.v26)],
    targets: [
        // Rules and data logic with no SwiftUI, so tests run without the app.
        .target(name: "ToolbeltKit"),
        .executableTarget(
            name: "Toolbelt",
            dependencies: ["ToolbeltKit"],
            // App code runs on the main thread unless you say otherwise.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "ToolbeltKitTests", dependencies: ["ToolbeltKit"]),
    ]
)

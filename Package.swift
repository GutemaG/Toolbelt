// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Toolbelt",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Installs updates in place. See Releases in CLAUDE.md.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Rules and data logic with no SwiftUI, so tests run without the app.
        .target(name: "ToolbeltKit"),
        .executableTarget(
            name: "Toolbelt",
            dependencies: ["ToolbeltKit", .product(name: "Sparkle", package: "Sparkle")],
            // App code runs on the main thread unless you say otherwise.
            swiftSettings: [.defaultIsolation(MainActor.self)],
            // build.sh copies Sparkle.framework into the app's Frameworks folder.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "ToolbeltKitTests", dependencies: ["ToolbeltKit"]),
    ]
)

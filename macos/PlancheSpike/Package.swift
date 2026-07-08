// swift-tools-version: 5.9
import PackageDescription

// Spike A: minimal embedding of our self-built GhosttyKit (from vendor/ghostty).
// Build the framework first:
//   cd vendor/ghostty && ../../.tooling/zig/zig build -Demit-macos-app=false -Dxcframework-target=native -Doptimize=ReleaseFast
//   cp -R vendor/ghostty/macos/GhosttyKit.xcframework macos/PlancheSpike/
let package = Package(
    name: "PlancheSpike",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "PlancheSpike",
            dependencies: ["GhosttyKit"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Carbon"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("UserNotifications"),
                .linkedLibrary("c++"),
            ]
        )
    ]
)

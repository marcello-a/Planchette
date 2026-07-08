// swift-tools-version: 5.9
import PackageDescription

// Planchette macOS app. GhosttyKit is our own build from vendor/ghostty:
//   cd vendor/ghostty && ../../.tooling/zig/zig build -Demit-macos-app=false -Dxcframework-target=native -Doptimize=ReleaseFast
//   cp -R vendor/ghostty/macos/GhosttyKit.xcframework macos/Planchette/
let package = Package(
    name: "Planchette",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "Planchette",
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

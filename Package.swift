// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GlassToolbar",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GlassToolbar", targets: ["GlassToolbar"]),
    ],
    targets: [
        .target(name: "GlassToolbar"),
        // A window to try the items in, next to the system's own for comparison: `swift run GlassToolbarDemo`.
        .executableTarget(name: "GlassToolbarDemo", dependencies: ["GlassToolbar"]),
        .testTarget(name: "GlassToolbarTests", dependencies: ["GlassToolbar"]),
    ]
)

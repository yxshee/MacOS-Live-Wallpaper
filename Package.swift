// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LiveWallpaper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "LiveWallpaper", path: "Sources/LiveWallpaper"),
        .testTarget(name: "LiveWallpaperTests", dependencies: ["LiveWallpaper"], path: "Tests/LiveWallpaperTests"),
    ]
)

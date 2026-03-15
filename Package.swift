// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BrightBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BrightBar",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
            ]
        ),
    ]
)

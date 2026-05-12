// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BrightBar",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/waydabber/AppleSiliconDDC.git", revision: "97af3818b9803e51412fb50cac1506db1d73b5bf"),
    ],
    targets: [
        .executableTarget(
            name: "BrightBar",
            dependencies: [
                .product(name: "AppleSiliconDDC", package: "AppleSiliconDDC"),
            ],
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreDisplay"),
            ]
        ),
    ]
)

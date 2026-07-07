// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "screenoff",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "ScreenOffKit", targets: ["ScreenOffKit"]),
        .executable(name: "screenoff", targets: ["screenoff"]),
        .executable(name: "ScreenOffApp", targets: ["ScreenOffApp"])
    ],
    targets: [
        .target(
            name: "ScreenOffKit"
        ),
        .executableTarget(
            name: "screenoff",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "ScreenOffApp",
            dependencies: ["ScreenOffKit"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "ScreenOffKitTests",
            dependencies: ["ScreenOffKit"]
        )
    ]
)

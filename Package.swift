// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "screenoff",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "screenoff", targets: ["screenoff"]),
        .executable(name: "ScreenOffApp", targets: ["ScreenOffApp"])
    ],
    targets: [
        .executableTarget(
            name: "screenoff",
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        ),
        .executableTarget(
            name: "ScreenOffApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)

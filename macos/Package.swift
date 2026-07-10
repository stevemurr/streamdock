// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "StreamDockMac",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StreamDockCore", targets: ["StreamDockCore"]),
        .executable(name: "StreamDockApp", targets: ["StreamDockApp"]),
        .executable(name: "StreamDockCoreChecks", targets: ["StreamDockCoreChecks"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
    ],
    targets: [
        .target(
            name: "StreamDockCore",
            dependencies: ["Yams"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "StreamDockApp",
            dependencies: ["StreamDockCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "StreamDockCoreChecks",
            dependencies: ["StreamDockCore"]
        ),
        .testTarget(
            name: "StreamDockCoreTests",
            dependencies: ["StreamDockCore"]
        ),
    ]
)

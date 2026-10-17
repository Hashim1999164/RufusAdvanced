// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "RufusAdvanced",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BootKit", targets: ["BootKit"]),
        .executable(name: "rufusadv-helper", targets: ["RufusHelper"]),
        .executable(name: "RufusAdvanced", targets: ["RufusAdvanced"]),
    ],
    targets: [
        .target(
            name: "CBootKit",
            path: "Sources/CBootKit"
        ),
        .target(
            name: "BootKit",
            dependencies: ["CBootKit"],
            path: "Sources/BootKit",
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
                .linkedFramework("Security"),
                .linkedLibrary("z"),
            ]
        ),
        .executableTarget(
            name: "RufusHelper",
            dependencies: ["BootKit"],
            path: "Sources/RufusHelper"
        ),
        .executableTarget(
            name: "RufusAdvanced",
            dependencies: ["BootKit"],
            path: "Sources/RufusAdvanced"
        ),
        .testTarget(
            name: "BootKitTests",
            dependencies: ["BootKit"],
            path: "Tests/BootKitTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)

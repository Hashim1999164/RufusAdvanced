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
            name: "CNTFS",
            path: "Sources/CNTFS",
            exclude: ["COPYING-ntfs-3g.txt", "README-ntfs-3g.txt"],
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("ntfs-3g-include"),
                .headerSearchPath("ntfs-3g-include/ntfs-3g"),
                .headerSearchPath("ntfsprogs"),
                .unsafeFlags(["-w"]),
            ]
        ),
        .target(
            name: "BootKit",
            dependencies: ["CBootKit", "CNTFS"],
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

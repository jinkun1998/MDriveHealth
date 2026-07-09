// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MDriveHealthCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MDriveHealthCore", targets: ["MDriveHealthCore"]),
        .executable(name: "mdrivehealth-cli", targets: ["mdrivehealth-cli"]),
    ],
    targets: [
        .target(
            name: "CSMART",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(
            name: "MDriveHealthCore",
            dependencies: ["CSMART"],
            resources: [.copy("Resources/drivedb.json")]
        ),
        .executableTarget(
            name: "mdrivehealth-cli",
            dependencies: ["MDriveHealthCore"]
        ),
        .testTarget(
            name: "MDriveHealthCoreTests",
            dependencies: ["MDriveHealthCore"]
        ),
    ]
)

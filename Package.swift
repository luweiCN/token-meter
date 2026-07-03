// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TokenMeter",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "TokenMeterCore",
            targets: ["TokenMeterCore"]
        ),
        .executable(
            name: "TokenMeterApp",
            targets: ["TokenMeterApp"]
        )
    ],
    dependencies: [],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            providers: [
                .brew(["sqlite"])
            ]
        ),
        .target(
            name: "TokenMeterCore",
            dependencies: ["CSQLite"],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "TokenMeterApp",
            dependencies: [
                "TokenMeterCore"
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "TokenMeterCoreTests",
            dependencies: ["TokenMeterCore"]
        ),
        .testTarget(
            name: "TokenMeterAppTests",
            dependencies: ["TokenMeterApp", "TokenMeterCore"]
        )
    ]
)

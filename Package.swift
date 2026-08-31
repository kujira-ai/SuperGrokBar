// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SuperGrokBar",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SuperGrokBar", targets: ["SuperGrokBar"])
    ],
    targets: [
        .executableTarget(
            name: "SuperGrokBar",
            path: "Sources/SuperGrokBar",
            resources: [
                .copy("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security")
            ]
        )
    ]
)

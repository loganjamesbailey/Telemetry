// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TelemetryCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SMCKit", targets: ["SMCKit"]),
        .library(name: "HIDSensors", targets: ["HIDSensors"]),
        .library(name: "TelemetryShared", targets: ["TelemetryShared"]),
        .executable(name: "smcspike", targets: ["smcspike"]),
    ],
    targets: [
        .target(
            name: "SMCKit",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(name: "CHIDShim"),
        .target(
            name: "HIDSensors",
            dependencies: ["CHIDShim"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .target(name: "TelemetryShared"),
        .executableTarget(
            name: "smcspike",
            dependencies: ["SMCKit", "HIDSensors"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TelemetryCoreTests",
            dependencies: ["SMCKit"]
        ),
    ]
)

// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SweepKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SweepKit", targets: ["SweepKit"]),
        .library(name: "SweepMetrics", targets: ["SweepMetrics"]),
        .library(name: "SweepAnalyze", targets: ["SweepAnalyze"]),
        .library(name: "SweepJunk", targets: ["SweepJunk"]),
        .library(name: "SweepUninstall", targets: ["SweepUninstall"]),
        .library(name: "SweepOptimize", targets: ["SweepOptimize"]),
        .library(name: "SweepDesign", targets: ["SweepDesign"]),
        .library(name: "StatusUI", targets: ["StatusUI"]),
        .library(name: "AnalyzeUI", targets: ["AnalyzeUI"]),
        .library(name: "JunkUI", targets: ["JunkUI"]),
        .library(name: "UninstallUI", targets: ["UninstallUI"]),
        .library(name: "OptimizeUI", targets: ["OptimizeUI"]),
        .library(name: "SweepCLI", targets: ["SweepCLI"]),
        .executable(name: "housekeeping", targets: ["housekeeping"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Engine: catalog, resolver, sizer, guard, executor, ledger, projects.
        .target(name: "SweepKit", resources: [.process("Resources")]),

        // Feature engines. Each depends only on the core.
        .target(name: "SweepMetrics", dependencies: ["SweepKit"]),
        .target(name: "SweepAnalyze", dependencies: ["SweepKit"]),
        .target(name: "SweepJunk", dependencies: ["SweepKit"]),
        .target(name: "SweepUninstall", dependencies: ["SweepKit"]),
        .target(name: "SweepOptimize", dependencies: ["SweepKit"]),

        // Fixture homes and fake tools shared by every test target.
        .target(name: "SweepTestSupport", dependencies: ["SweepKit"]),

        // Shared SwiftUI building blocks (glass, risk colours, size text).
        .target(name: "SweepDesign", dependencies: ["SweepKit"]),

        // Feature views.
        .target(name: "StatusUI", dependencies: ["SweepKit", "SweepMetrics", "SweepDesign"]),
        .target(name: "AnalyzeUI", dependencies: ["SweepKit", "SweepAnalyze", "SweepDesign"]),
        .target(name: "JunkUI", dependencies: ["SweepKit", "SweepJunk", "SweepDesign"]),
        .target(name: "UninstallUI", dependencies: ["SweepKit", "SweepUninstall", "SweepDesign"]),
        .target(name: "OptimizeUI", dependencies: ["SweepKit", "SweepOptimize", "SweepDesign"]),

        // CLI.
        .target(
            name: "SweepCLI",
            dependencies: [
                "SweepKit", "SweepMetrics",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "housekeeping", dependencies: ["SweepCLI"]),

        .testTarget(name: "SweepKitTests", dependencies: ["SweepKit", "SweepTestSupport"]),
        .testTarget(name: "SweepMetricsTests", dependencies: ["SweepMetrics", "SweepTestSupport"]),
        .testTarget(name: "SweepAnalyzeTests", dependencies: ["SweepAnalyze", "SweepTestSupport"]),
        .testTarget(name: "SweepJunkTests", dependencies: ["SweepJunk", "SweepTestSupport"]),
        .testTarget(name: "SweepUninstallTests", dependencies: ["SweepUninstall", "SweepTestSupport"]),
        .testTarget(name: "SweepOptimizeTests", dependencies: ["SweepOptimize", "SweepTestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)

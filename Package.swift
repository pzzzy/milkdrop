// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MilkDropMac",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MilkDropCore", targets: ["MilkDropCore"]),
        .executable(name: "MilkDropMac", targets: ["MilkDropMac"])
    ],
    targets: [
        .target(name: "MilkDropCore"),
        .executableTarget(
            name: "MilkDropMac",
            dependencies: ["MilkDropCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("MetalKit"),
                .linkedFramework("MetalPerformanceShaders"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Accelerate")
            ]
        ),
        .executableTarget(name: "MilkDropCoreCheck", dependencies: ["MilkDropCore"]),
        .testTarget(name: "MilkDropCoreTests", dependencies: ["MilkDropCore"])
    ],
    swiftLanguageModes: [.v5]
)

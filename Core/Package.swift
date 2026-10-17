// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MwoyeoCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MwoyeoCore", targets: ["MwoyeoCore"]),
        .library(name: "MwoyeoEngines", targets: ["MwoyeoEngines"]),
    ],
    targets: [
        .target(name: "MwoyeoCore"),
        .target(name: "MwoyeoEngines", dependencies: ["MwoyeoCore"]),
        .testTarget(name: "MwoyeoCoreTests", dependencies: ["MwoyeoCore"]),
        .testTarget(name: "MwoyeoEnginesTests", dependencies: ["MwoyeoEngines", "MwoyeoCore"]),
    ]
)

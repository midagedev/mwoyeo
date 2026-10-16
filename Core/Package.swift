// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MwoyeoCore",
    platforms: [.macOS("26.0")],
    products: [.library(name: "MwoyeoCore", targets: ["MwoyeoCore"])],
    targets: [
        .target(name: "MwoyeoCore"),
        .testTarget(name: "MwoyeoCoreTests", dependencies: ["MwoyeoCore"]),
    ]
)

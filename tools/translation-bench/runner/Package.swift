// swift-tools-version: 6.2
import PackageDescription

// The bench runner: replays the sequences against an engine under one condition. It builds today's requests with
// MwoyeoCore's protocol code (the same bodies the app sends) and does the HTTP itself, to keep the raw reply, the
// usage and the latency of every request.
let package = Package(
    name: "translation-bench-runner",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../../../Core")],
    targets: [
        .target(name: "BenchKit", dependencies: [.product(name: "MwoyeoCore", package: "Core")]),
        .executableTarget(name: "bench-run", dependencies: ["BenchKit"]),
        .testTarget(name: "BenchKitTests", dependencies: ["BenchKit"]),
    ]
)

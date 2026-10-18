// swift-tools-version: 6.2
import PackageDescription

// `read` runs Vision (VN lines and RecognizeDocumentsRequest) once per page and keeps the answer as JSON; it links no code of ours,
// so rebuilding `probe` leaves its binary, and the Neural Engine's compile cache for it, as it was. `probe` measures the crops.
let package = Package(
    name: "inline-math-probe",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../../Core")],
    targets: [
        .executableTarget(name: "read", path: "Sources/read", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "probe", dependencies: [.product(name: "MwoyeoCore", package: "Core")], path: "Sources/probe",
                          swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)

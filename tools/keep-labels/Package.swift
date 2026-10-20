// swift-tools-version: 6.2
import PackageDescription

// Tools of the keep-labels round (no part of the app):
//   pdfglyphs  every glyph of a PDF with its font, from the content stream (PDFKit gives no real font names)
//   ocrdump    the app's two Vision reads (Shared/VisionExec.swift, linked in) of a page picture, as JSON
//   keeprules  today's Core rules (InlineMath, TranslationFilter) run on labelled units
//   regionfeed the inputs of CodeRegion (block rects, line rects, background colours) read off the labelled pictures
//   snap       draws an HTML case to a PNG (the same recipe the use-case pictures were made with)
//   littime    times InlineLiteral.spans against InlineMath.spans and TranslationFilter.needsTranslation on the labelled blocks
let package = Package(
    name: "KeepLabels",
    platforms: [.macOS("26.0")],
    dependencies: [.package(path: "../../Core")],
    targets: [
        .executableTarget(name: "pdfglyphs"),
        .executableTarget(name: "ocrdump", dependencies: [.product(name: "MwoyeoCore", package: "Core")],
                          swiftSettings: [.define("READER_SERVICE")]),
        .executableTarget(name: "keeprules", dependencies: [.product(name: "MwoyeoCore", package: "Core")]),
        .executableTarget(name: "regionfeed", dependencies: [.product(name: "MwoyeoCore", package: "Core")]),
        .executableTarget(name: "snap"),
        .executableTarget(name: "littime", dependencies: [.product(name: "MwoyeoCore", package: "Core")]),
    ]
)

// The raw structure of RecognizeDocumentsRequest for page pictures (D1, 2026-10-19; I1 promoted it from /tmp). Prints, in image
// pixels (top-left origin): the object counts of the document, every paragraph (lines, its boundingRegion polygon), tables and lists.
// Tells whether a "page-sized block" is a container, a table, a list or an ordinary paragraph that goes on in the next column
// (docs/design/recognition.md section 11: it is the last).
//   build: swiftc -O structure.swift -o structure      usage: structure <png> [more pngs]
// A paragraph of seven or more lines also prints its line boxes. The first request on a new bundle id compiles the document model
// (~100 s); the binary is its own bundle, so it has a cold cache of its own.
import CoreGraphics
import Foundation
import ImageIO
import Vision

func px(_ p: NormalizedPoint, _ w: Double, _ h: Double) -> (Double, Double) { (p.x * w, (1 - p.y) * h) }
func bbox(_ pts: [NormalizedPoint], _ w: Double, _ h: Double) -> String {
    guard !pts.isEmpty else { return "-" }
    let xs = pts.map { $0.x * w }, ys = pts.map { (1 - $0.y) * h }
    return String(format: "%.0f,%.0f %.0fx%.0f", xs.min()!, ys.min()!, xs.max()! - xs.min()!, ys.max()! - ys.min()!)
}
func poly(_ pts: [NormalizedPoint], _ w: Double, _ h: Double) -> String {
    pts.prefix(12).map { let (x, y) = px($0, w, h); return String(format: "(%.0f,%.0f)", x, y) }.joined() + (pts.count > 12 ? "…+\(pts.count - 12)" : "")
}

for path in CommandLine.arguments.dropFirst() {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("cannot read \(path)"); continue }
    let w = Double(image.width), h = Double(image.height)
    var req = RecognizeDocumentsRequest()
    req.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: "en")]
    let t0 = Date()
    let docs = try await req.perform(on: image)
    print("== \(path) \(image.width)x\(image.height): \(docs.count) document observation(s) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
    for (di, obs) in docs.enumerated() {
        let d = obs.document
        print("doc \(di): paragraphs=\(d.paragraphs.count) tables=\(d.tables.count) lists=\(d.lists.count) title=\(d.title.map { "'\($0.transcript.prefix(40))'" } ?? "nil") barcodes=\(d.barcodes.count)")
        print("doc \(di) text container: lines=\(d.text.lines.count) bbox=\(bbox(d.text.boundingRegion.points, w, h)) chars=\(d.text.transcript.count)")
        print("doc \(di) container region: \(bbox(d.boundingRegion.points, w, h))")
        for (pi, p) in d.paragraphs.enumerated() {
            let ls = p.lines.map { l -> String in
                let r = l.boundingBox.cgRect
                return String(format: "%.0f,%.0f,%.0f,%.0f", r.minX * w, (1 - r.maxY) * h, r.width * w, r.height * h)
            }
            print("para \(pi) lines=\(p.lines.count) region=\(bbox(p.boundingRegion.points, w, h)) polygon=\(poly(p.boundingRegion.points, w, h)) align=\(p.textAlignment.map { "\($0)" } ?? "-") '\(p.transcript.prefix(48))'")
            if p.lines.count >= 7 { print("     lines: \(ls.joined(separator: " | "))") }
        }
        for (ti, t) in d.tables.enumerated() {
            print("table \(ti) rows=\(t.rows.count) cols=\(t.columns.count) region=\(bbox(t.boundingRegion.points, w, h))")
            for (ri, row) in t.rows.enumerated() {
                print("   row \(ri): " + row.map { c in "[\(c.rowRange.lowerBound)-\(c.rowRange.upperBound),\(c.columnRange.lowerBound)-\(c.columnRange.upperBound) paras=\(c.content.paragraphs.count) '\(c.content.text.transcript.prefix(14))']" }.joined(separator: " "))
            }
        }
        for (li, l) in d.lists.enumerated() {
            print("list \(li) items=\(l.items.count) region=\(bbox(l.boundingRegion.points, w, h))")
            for it in l.items { print("   item marker='\(it.markerString)' paras=\(it.content.paragraphs.count) lines=\(it.content.text.lines.count) '\(it.itemString.prefix(40))'") }
        }
        // does any paragraph's text also sit inside a table cell or a list item (a flat list that repeats nested content)?
        let nested = (d.tables.flatMap { $0.rows.flatMap { $0 } }.map { $0.content.text.transcript } + d.lists.flatMap { $0.items.map { $0.content.text.transcript } })
        let inPara = Set(d.paragraphs.map(\.transcript))
        print("nested containers' texts that equal a top-level paragraph transcript: \(nested.filter { inPara.contains($0) }.count) of \(nested.count)")
    }
}

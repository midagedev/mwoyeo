import Foundation
import MwoyeoCore

// usage: keeprules <labels.jsonl>...        (stdout: one JSON line per block record)
// Today's Core rules run on the text of every labelled block, exactly as the app runs them on a block (TextRecognizer.verdict,
// TranslationService.translate, ProtectedSpans): InlineMath.spans, isFormula, isMathHeavy, isIdentifier, isLiteral, needsTranslation.
// {"id","spans":[[start,end]...] (Characters, as InlineMath counts), "formula","mathHeavy","identifier","literal","needs","share","signs"}
// `needs` is TranslationFilter.needsTranslation(text, cjkSource) with cjkSource true for a block whose "lang" is ko, ja or zh*.
// With KEEP_FEED=<regionfeed output> every record also carries "region": CodeRegion.keep run on the blocks of the block's read (one picture, one
// read, in reading-list order), the reason it keeps the block or null.

func json(_ s: String) -> String {
    var o = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": o += "\\\""
        case "\\": o += "\\\\"
        default: o += u.value < 32 ? String(format: "\\u%04x", u.value) : String(u)
        }
    }
    return o + "\""
}

/// CodeRegion on every (picture, read) of the feed: block id -> reason, and the ids the feed holds (a labelled block whose picture the feed lacks is
/// reported as "nofeed", not as a block CodeRegion left alone: a run without its pictures must not read as a rule that never fires).
func regions(feedPath: String) -> (verdicts: [String: String], fed: Set<String>) {
    guard let data = FileManager.default.contents(atPath: feedPath), let text = String(data: data, encoding: .utf8) else {
        FileHandle.standardError.write(Data("cannot read \(feedPath)\n".utf8)); exit(1)
    }
    struct Row { var idx: Int; var id: String; var block: CodeRegion.Block; var frame: RGBA }
    var groups: [String: [Row]] = [:]
    for line in text.split(separator: "\n") {
        guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = o["id"] as? String, let pic = o["pic"] as? String,
              let read = o["read"] as? String, let idx = o["idx"] as? Int, let r = o["r"] as? [Double], let t = o["t"] as? String,
              let bg = o["bg"] as? [Int], let frame = o["frame"] as? [Int], let ls = o["lines"] as? [[String: Any]] else { continue }
        let lines = ls.compactMap { l -> CodeRegion.Line? in
            guard let lr = l["r"] as? [Double], let lt = l["t"] as? String else { return nil }
            let words = (l["w"] as? [[Any]] ?? []).compactMap { w -> CodeRegion.Word? in
                guard w.count == 5, let x = w[0] as? Double, let y = w[1] as? Double, let ww = w[2] as? Double, let hh = w[3] as? Double, let wt = w[4] as? String else { return nil }
                return CodeRegion.Word(text: wt, rect: CGRect(x: x, y: y, width: ww, height: hh))
            }
            return CodeRegion.Line(text: lt, rect: CGRect(x: lr[0], y: lr[1], width: lr[2], height: lr[3]), words: words)
        }
        let block = CodeRegion.Block(text: t, rect: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]), lines: lines,
                                     background: RGBA(UInt8(bg[0]), UInt8(bg[1]), UInt8(bg[2])))
        groups["\(pic)|\(read)", default: []].append(Row(idx: idx, id: id, block: block, frame: RGBA(UInt8(frame[0]), UInt8(frame[1]), UInt8(frame[2]))))
    }
    var out: [String: String] = [:]
    var fed = Set<String>()
    for rows in groups.values {
        for row in rows { fed.insert(row.id) }
        let sorted = rows.sorted { $0.idx < $1.idx }
        let verdicts = CodeRegion.keep(blocks: sorted.map(\.block), frameBackground: sorted[0].frame)
        for (row, v) in zip(sorted, verdicts) { if let v { out[row.id] = v.rawValue } }
    }
    return (out, fed)
}

let regionOf = ProcessInfo.processInfo.environment["KEEP_FEED"].map(regions(feedPath:))

var out = ""
for path in CommandLine.arguments.dropFirst() {
    guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
        FileHandle.standardError.write(Data("cannot read \(path)\n".utf8)); exit(1)
    }
    for line in text.split(separator: "\n") {
        guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], obj["kind"] as? String == "block",
              let id = obj["id"] as? String, let t = obj["text"] as? String else { continue }
        let lang = obj["lang"] as? String ?? "en"
        let cjk = ["ja", "ko"].contains(lang) || lang.hasPrefix("zh")
        let spans = InlineMath.spans(in: t).map { "[\($0.range.lowerBound),\($0.range.upperBound)]" }.joined(separator: ",")
        let share = TranslationFilter.mathShare(of: t)
        out += "{\"id\":\(json(id)),\"spans\":[\(spans)],\"formula\":\(TranslationFilter.isFormula(t)),\"mathHeavy\":\(TranslationFilter.isMathHeavy(t)),"
            + "\"identifier\":\(TranslationFilter.isIdentifier(t)),\"literal\":\(TranslationFilter.isLiteral(t)),"
            + "\"needs\":\(TranslationFilter.needsTranslation(t, cjkSource: cjk)),\"share\":\(String(format: "%.3f", share.share)),\"signs\":\(share.signs)"
            + (regionOf.map { ",\"region\":" + ($0.verdicts[id].map(json) ?? ($0.fed.contains(id) ? "null" : "\"nofeed\"")) } ?? "") + "}\n"
    }
}
FileHandle.standardOutput.write(Data(out.utf8))

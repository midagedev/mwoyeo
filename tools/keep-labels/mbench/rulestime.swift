import Foundation
import MwoyeoCore

// usage: rulestime <labels.jsonl> <feed.jsonl> [reps]        (stdout: one JSON object)
// Times judge 1 in process, without the process start and JSON parse of keeprules: the labels' blocks (text, lang) and the regionfeed feed are read first, then
//   filter_ns  per block: TranslationFilter.needsTranslation + isFormula... as keeprules calls them, alone, batch=1 (median over reps)
//   spans_ns   per block: InlineMath.spans, alone, batch=1
//   region_ns  per (picture, read) group: CodeRegion.keep over all blocks of the group (the call the app makes on a read), and the group's block count
// Compile: swiftc -O -I <build>/release rulestime.swift <build>/release/MwoyeoCore.o -o rulestime   (run.sh does it)

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: rulestime <labels.jsonl> <feed.jsonl> [reps]"); exit(2) }
let reps = args.count > 3 ? Int(args[3]) ?? 3 : 3

func readLines(_ path: String) -> [Substring] {
    guard let d = FileManager.default.contents(atPath: path), let s = String(data: d, encoding: .utf8) else { FileHandle.standardError.write(Data("cannot read \(path)\n".utf8)); exit(1) }
    return s.split(separator: "\n")
}

struct B { var id: String; var text: String; var cjk: Bool }
var blocks: [B] = []
for line in readLines(args[1]) {
    guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], o["kind"] as? String == "block", let id = o["id"] as? String, let t = o["text"] as? String else { continue }
    let lang = o["lang"] as? String ?? "en"
    blocks.append(B(id: id, text: t, cjk: ["ja", "ko"].contains(lang) || lang.hasPrefix("zh")))
}

struct Row { var idx: Int; var block: CodeRegion.Block; var frame: RGBA }
var groups: [String: [Row]] = [:]
for line in readLines(args[2]) {
    guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let pic = o["pic"] as? String,
          let read = o["read"] as? String, let idx = o["idx"] as? Int, let r = o["r"] as? [Double], let t = o["t"] as? String,
          let bg = o["bg"] as? [Int], let frame = o["frame"] as? [Int], let ls = o["lines"] as? [[String: Any]] else { continue }
    let lines = ls.compactMap { l -> CodeRegion.Line? in
        guard let lr = l["r"] as? [Double], let lt = l["t"] as? String else { return nil }
        return CodeRegion.Line(text: lt, rect: CGRect(x: lr[0], y: lr[1], width: lr[2], height: lr[3]))
    }
    let block = CodeRegion.Block(text: t, rect: CGRect(x: r[0], y: r[1], width: r[2], height: r[3]), lines: lines, background: RGBA(UInt8(bg[0]), UInt8(bg[1]), UInt8(bg[2])))
    groups["\(pic)|\(read)", default: []].append(Row(idx: idx, block: block, frame: RGBA(UInt8(frame[0]), UInt8(frame[1]), UInt8(frame[2]))))
}

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func median(_ v: [UInt64]) -> UInt64 { v.sorted()[v.count / 2] }

var sink = 0
var filterNs: [UInt64] = [], spansNs: [UInt64] = []
for b in blocks {
    var f: [UInt64] = [], s: [UInt64] = []
    for _ in 0..<reps {
        let t0 = now()
        let n = TranslationFilter.needsTranslation(b.text, cjkSource: b.cjk)
        let t1 = now()
        let sp = InlineMath.spans(in: b.text)
        let t2 = now()
        sink &+= (n ? 1 : 0) &+ sp.count
        f.append(t1 - t0); s.append(t2 - t1)
    }
    filterNs.append(median(f)); spansNs.append(median(s))
}
var regionNs: [UInt64] = [], regionBlocks: [Int] = []
for (_, rows) in groups {
    let sorted = rows.sorted { $0.idx < $1.idx }
    var ts: [UInt64] = []
    for _ in 0..<reps {
        let t0 = now()
        let v = CodeRegion.keep(blocks: sorted.map(\.block), frameBackground: sorted[0].frame)
        ts.append(now() - t0)
        sink &+= v.count
    }
    regionNs.append(median(ts)); regionBlocks.append(sorted.count)
}
func arr(_ v: [UInt64]) -> String { "[" + v.map(String.init).joined(separator: ",") + "]" }
print("{\"blocks\":\(blocks.count),\"reps\":\(reps),\"filter_ns\":\(arr(filterNs)),\"spans_ns\":\(arr(spansNs)),\"region_ns\":\(arr(regionNs)),\"region_blocks\":[\(regionBlocks.map(String.init).joined(separator: ","))],\"sink\":\(sink)}")

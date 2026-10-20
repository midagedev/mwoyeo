import Foundation
import MwoyeoCore

// usage: littime [labels.jsonl...]   (default: labels-h2/h2.jsonl and labels/code.jsonl beside the package)
// Times InlineLiteral.spans over the block texts 20 times and prints the per-block and per-word median and p95 in ns, the
// first-call (table compile) cost in ms, and the same for InlineMath.spans and TranslationFilter.needsTranslation.
// Word count = whitespace-separated tokens of the block text.

struct Block {
    let text: String
    let words: Int
    let cjk: Bool
}

func load(_ path: String) -> [Block] {
    guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
        FileHandle.standardError.write(Data("cannot read \(path)\n".utf8)); exit(1)
    }
    var out: [Block] = []
    for line in text.split(separator: "\n") {
        guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              o["kind"] as? String == "block", let t = o["text"] as? String else { continue }
        let lang = o["lang"] as? String ?? "en"
        out.append(Block(text: t, words: max(1, t.split(whereSeparator: \.isWhitespace).count),
                         cjk: ["ja", "ko"].contains(lang) || lang.hasPrefix("zh")))
    }
    return out
}

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func percentile(_ sorted: [Double], _ p: Double) -> Double {
    if sorted.isEmpty { return 0 }
    let at = min(sorted.count - 1, Int((p * Double(sorted.count)).rounded(.up)) - 1)
    return sorted[max(0, at)]
}

func median(_ xs: [Double]) -> Double { percentile(xs.sorted(), 0.5) }

func run(_ name: String, _ blocks: [Block], _ f: (Block) -> Int) {
    var checksum = 0
    let first = now()
    checksum &+= f(blocks[0])
    let firstMs = Double(now() - first) / 1_000_000
    var perBlock: [Double] = []
    var total = 0
    for b in blocks {
        var times: [Double] = []
        for _ in 0..<20 {
            let t0 = now()
            checksum &+= f(b)
            times.append(Double(now() - t0))
        }
        perBlock.append(median(times))
        total += b.words
    }
    var byWord = zip(perBlock, blocks.map(\.words)).map { $0 / Double($1) }
    perBlock.sort()
    byWord.sort()
    let padded = name.padding(toLength: 28, withPad: " ", startingAt: 0)
    print("\(padded) first \(String(format: "%.3f", firstMs)) ms   per block: median \(String(format: "%.0f", median(perBlock))) ns  "
        + "p95 \(String(format: "%.0f", percentile(perBlock, 0.95))) ns   per word: median \(String(format: "%.0f", median(byWord))) ns  "
        + "p95 \(String(format: "%.0f", percentile(byWord, 0.95))) ns   blocks \(blocks.count) words \(total)  (checksum \(checksum))")
}

let args = Array(CommandLine.arguments.dropFirst())
let paths = args.isEmpty ? ["labels-h2/h2.jsonl", "labels/code.jsonl"] : args
var blocks: [Block] = []
for p in paths { blocks += load(p) }
print("littime: \(blocks.count) blocks from \(paths.joined(separator: " "))")
run("InlineLiteral.spans", blocks) { InlineLiteral.spans(in: $0.text).count }
run("InlineMath.spans", blocks) { InlineMath.spans(in: $0.text).count }
run("needsTranslation", blocks) { TranslationFilter.needsTranslation($0.text, cjkSource: $0.cjk) ? 1 : 0 }

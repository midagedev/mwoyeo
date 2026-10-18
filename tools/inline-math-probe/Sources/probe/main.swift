// inline-math-probe: how clean are the crops of InlineMath spans made from Vision's word boxes? See README.md.
import CoreGraphics
import Foundation
import ImageIO

func fail(_ s: String) -> Never { print(s); exit(2) }

let args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }

switch args.first {
case "locate":
    guard args.count >= 2 else { fail("usage: probe locate <bench dir> [-v]") }
    let pages = option("--pages").map { $0.split(separator: ",").map(String.init) } ?? ["p3", "p4", "p5", "p6"]
    Locate.run(dir: args[1], pages: pages, verbose: args.contains("-v"))
case "blocks":
    // probe blocks --ocr <dir> --names p3,p4 --out <prefix>: the texts of the prose blocks that hold a span, as the app sends them
    guard let ocr = option("--ocr"), let out = option("--out") else { fail("usage: probe blocks --ocr <dir> --names p3,p4 --out <prefix>") }
    var texts: [String] = [], names: [String] = [], seen = Set<String>()
    for name in (option("--names") ?? "p3,p4,p5,p6").split(separator: ",").map(String.init) {
        for path in ["docs", "vn"] {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: ocr).appendingPathComponent("\(path)-\(name).json")),
                  let page = try? JSONDecoder().decode(JPage.self, from: data) else { continue }
            for block in blocks(of: page) {
                // Only prose is translated: at least five words, and formulas are under 40 % of the characters.
                let found = spans(of: block, index: 0)
                let math = found.reduce(0) { $0 + $1.text.count }
                guard !found.isEmpty, block.text.split(separator: " ").count >= 5, Double(math) < 0.4 * Double(block.text.count),
                      seen.insert(block.text).inserted else { continue }
                texts.append(block.text); names.append("\(name)/\(path)")
            }
        }
    }
    try JSONEncoder().encode(texts).write(to: URL(fileURLWithPath: out + "-src.json"))
    try JSONEncoder().encode(names).write(to: URL(fileURLWithPath: out + "-pages.json"))
    print("blocks: \(texts.count) blocks with spans -> \(out)-src.json")
case "locate-json":
    // probe locate-json <prefix> <translations.json> [-v]
    guard args.count >= 3 else { fail("usage: probe locate-json <prefix> <translations.json> [-v]") }
    // the page list holds "p5/docs": the page is what counts
    let all = Locate.pairs(sources: args[1] + "-src.json", targets: args[2], pages: args[1] + "-pages.json")
        .map { Locate.Pair(page: String($0.page.split(separator: "/")[0]), source: $0.source, target: $0.target) }
    let pages = Array(Set(all.map(\.page))).sorted { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) }
    Locate.report(label: args[2], all: all, pages: pages, verbose: args.contains("-v"))
case "measure":
    Run.measure(args)
case "dump":
    Run.dump(args)
default:
    fail("""
    usage: probe locate <bench dir> [-v]
           probe measure --ocr <dir of read's json> --pages <dir of pngs> [--names p3,p4,p5,p6] [--mutate shrink|grow]
                         [--threshold 170] [--dilate 2] [--pad 0] [--tol 1] [--out <dir for montages and tsv>] [--sens] [-v]
    """)
}

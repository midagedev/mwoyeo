import CoreGraphics
import Foundation

// Replays the decider on recognized lines traced by `LINES=1 bench.sh <binary> auto`: for every <name>-auto.err it prints the
// layout features and the reader the decider (Core/Sources/MwoyeoCore/ParagraphReader.swift) would pick, so the rules can be fitted
// without rendering again. Built and run by tune.sh. Usage: tune <out dir> [bundleID category]
let out = CommandLine.arguments[1]
let context = ReaderContext(bundleID: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil,
                            category: CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : nil)
let names = ((try? FileManager.default.contentsOfDirectory(atPath: out + "/out")) ?? []).filter { $0.hasSuffix("-auto.err") }.sorted()
for file in names {
    let text = (try? String(contentsOfFile: out + "/out/" + file, encoding: .utf8)) ?? ""
    guard let line = text.split(separator: "\n").last(where: { $0.contains("reader lines ") }) else { continue }
    let body = line.components(separatedBy: "reader lines ")[1]
    let size = body.prefix { $0 != " " }.split(separator: "x").compactMap { Double($0) }
    let rects = body.components(separatedBy: "[").dropFirst().compactMap { part -> CGRect? in
        let v = part.prefix { $0 != "]" }.split(separator: ",").compactMap { Double($0) }
        return v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : nil
    }
    let layout = LineLayout(lines: rects, in: CGSize(width: size[0], height: size[1]))
    let pick = ReaderDecider.decide(layout, context: context)
    let l = layout
    print(String(format: "%@ n=%d aspect=%.2f col=%d mates=%.2f lowAligned=%d centredLow=%d -> %@ (%@)",
                 String(file.dropLast(9)), l.lineCount, l.aspect, l.columns, l.rowMates, l.lowAligned, l.centredLow,
                 pick.reader.rawValue, pick.reason))
}

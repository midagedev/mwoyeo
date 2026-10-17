// Apple on-device Translation benchmark. Run: swift apple.swift [out.jsonl]   (macOS 26.4+, language packs installed)
// Rows match bench.py: {engine, model, pair, batch, run, ms, lines_out, error, out}. Run 0 = cold (first call of a new session).
import Foundation
import Translation

let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : dir.appendingPathComponent("raw-apple.jsonl").path
let root = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("data.json"))) as! [String: Any]
let pairs = root["pairs"] as! [String: [String: Any]]
FileManager.default.createFile(atPath: outPath, contents: nil)
let fh = FileHandle(forWritingAtPath: outPath)!

func emit(_ row: [String: Any]) {
    fh.write(try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8))
}
func row(_ engine: String, _ pair: String, _ batch: Int, _ run: Int, _ ms: Int?, _ out: [String]?, _ err: String?) -> [String: Any] {
    ["engine": engine, "model": engine, "pair": pair, "batch": batch, "run": run,
     "ms": ms as Any? ?? NSNull(), "lines_out": out?.count as Any? ?? NSNull(), "error": err as Any? ?? NSNull(), "out": out as Any? ?? NSNull()]
}

for pair in pairs.keys.sorted() {
    let p = pairs[pair]!
    let src = Locale.Language(identifier: p["source"] as! String), tgt = Locale.Language(identifier: p["target"] as! String)
    let batches = p["batches"] as! [[String]]
    let status = await LanguageAvailability().status(from: src, to: tgt)
    for (engine, strategy) in [("apple-low-latency", TranslationSession.Strategy.lowLatency), ("apple-high-fidelity", .highFidelity)] {
        if status != .installed {
            emit(row(engine, pair, 0, 0, nil, nil, "pack not installed (\(status))")); continue
        }
        let s = TranslationSession(installedSource: src, target: tgt, preferredStrategy: strategy)
        func go(_ b: Int, _ run: Int) async {
            let t = Date()
            do {
                let r = try await s.translations(from: batches[b].map { TranslationSession.Request(sourceText: $0) })
                emit(row(engine, pair, b, run, Int(Date().timeIntervalSince(t) * 1000), r.map(\.targetText), nil))
            } catch { emit(row(engine, pair, b, run, nil, nil, "\(error)".prefix(80).description)) }
        }
        await go(0, 0)
        for b in 0..<batches.count { for run in 1...3 { await go(b, run) } }
    }
}
print("done", outPath)

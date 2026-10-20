import Foundation
import MwoyeoCore
import Translation

// Does Apple Translation carry a literal inside prose through as written?
// usage: literal-survival <in.json> <out.jsonl>
// in.json:  [{"id","text","spans":[[start,end,reason]],"src","dst"}]   (spans are Character offsets, as InlineLiteral counts)
// out.jsonl: one line per block per mode per strategy:
//   {"kind":"block","id","src","dst","mode":"plain|marked","strategy":"lowLatency|highFidelity","target","target_raw","ms",
//    "spans":[{"reason","start","end","text","verbatim","verbatim_ci","verbatim_raw","verbatim_ci_raw","returned"}]}
//   plus one {"kind":"summary",...,"ms","blocks","spans"} per pair per mode per strategy.
// Modes: plain = one translate(batch:) per pair (what the app does); marked = one translate(_: AttributedString) per block, every
// InlineLiteral span marked skipsTranslation and carrying the marker link literal:<n> (the app's ProtectedRequest shape). The
// marked requests run at once, at most 8 at a time (the app's own marked path runs them in a task group).
// The app's casing fix (TranslationCleanup.restoreSourceTokens) is applied to the target before the verbatim test, as the app does
// on both paths; target_raw keeps the engine's own text and verbatim_raw the measurement against it.
// Built against MwoyeoCore (not a copy of restoreSourceTokens):
//   swift build -c release --scratch-path /tmp/lit-survival/core --package-path Core
//   swiftc -O -I /tmp/lit-survival/core/release -L /tmp/lit-survival/core/release -lMwoyeoCore \
//           tools/apple-translation-probe/literal-survival.swift -o /tmp/lit-survival/literal-survival

let args = CommandLine.arguments
guard args.count > 2 else {
    FileHandle.standardError.write(Data("usage: literal-survival <in.json> <out.jsonl>\n".utf8))
    exit(1)
}

/// One span: [start, end, reason] — start and end are Character offsets, the reason is InlineLiteral's name.
struct Span {
    let start: Int
    let end: Int
    let reason: String

    init?(_ raw: [Any]) {
        guard raw.count >= 2, let start = raw[0] as? Int, let end = raw[1] as? Int else { return nil }
        self.start = start
        self.end = end
        self.reason = raw.count > 2 ? (raw[2] as? String ?? "") : ""
    }
}

struct Block {
    let id: String
    let text: String
    let spans: [Span]
    let src: String
    let dst: String
}

func decodeBlocks(_ data: Data) throws -> [Block] {
    let raw = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    return raw.compactMap { o in
        guard let id = o["id"] as? String, let text = o["text"] as? String,
              let src = o["src"] as? String, let dst = o["dst"] as? String else { return nil }
        let spans = (o["spans"] as? [[Any]] ?? []).compactMap(Span.init)
        return Block(id: id, text: text, spans: spans, src: src, dst: dst)
    }
}

let items = try decodeBlocks(Data(contentsOf: URL(fileURLWithPath: args[1])))
let outURL = URL(fileURLWithPath: args[2])
FileManager.default.createFile(atPath: outURL.path, contents: nil)
let out = FileHandle(forWritingAtPath: outURL.path)!

func emit(_ row: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
    out.write(data + Data("\n".utf8))
}

/// The span's own text in the source (Character offsets).
func spanText(_ text: String, _ span: Span) -> String {
    let chars = Array(text)
    guard span.start >= 0, span.end <= chars.count, span.start < span.end else { return "" }
    return String(chars[span.start..<span.end])
}

/// The marker link the marked path puts on a span (the app's shape, the scheme the spec names).
func markerURL(_ n: Int) -> URL? { URL(string: "literal:\(n)") }

func marker(of url: URL) -> Int? {
    url.scheme == "literal" ? Int(url.absoluteString.dropFirst("literal:".count)) : nil
}

// One pair at a time: the app batches a group, not the whole page.
var pairs: [(String, String, [Block])] = []
for item in items where !pairs.contains(where: { $0.0 == item.src && $0.1 == item.dst }) {
    pairs.append((item.src, item.dst, items.filter { $0.src == item.src && $0.dst == item.dst }))
}

/// How many marked requests run at once.
let markedConcurrency = 8

for (src, dst, blocks) in pairs {
    let source = Locale.Language(identifier: src)
    let target = Locale.Language(identifier: dst)
    for strategy in [TranslationSession.Strategy.lowLatency, .highFidelity] {
        let strategyName = strategy == .lowLatency ? "lowLatency" : "highFidelity"
        let availability = await LanguageAvailability(preferredStrategy: strategy).status(from: source, to: target)
        guard availability == .installed else {
            emit(["kind": "note", "src": src, "dst": dst, "strategy": strategyName, "note": "pair not installed: \(availability)"])
            continue
        }
        let session = TranslationSession(installedSource: source, target: target, preferredStrategy: strategy)

        // MARK: plain — one batch for the pair, as the app does
        var plainTargets = [String: String]()
        let plainStart = Date()
        do {
            let requests = blocks.enumerated().map { TranslationSession.Request(sourceText: $1.text, clientIdentifier: String($0)) }
            for try await r in session.translate(batch: requests) {
                guard let id = r.clientIdentifier, let i = Int(id), i < blocks.count else { continue }
                plainTargets[blocks[i].id] = r.targetText
            }
        } catch {
            emit(["kind": "note", "src": src, "dst": dst, "mode": "plain", "strategy": strategyName, "error": "\(error)"])
        }
        let plainMs = Int(Date().timeIntervalSince(plainStart) * 1000)
        var plainSpans = 0, plainVerbatim = 0, plainVerbatimCI = 0, plainVerbatimRaw = 0, plainVerbatimRawCI = 0
        for block in blocks {
            guard let raw = plainTargets[block.id] else { continue }
            let fixed = TranslationCleanup.restoreSourceTokens(raw, source: block.text)
            var spanRows = [[String: Any]]()
            for span in block.spans {
                let text = spanText(block.text, span)
                let v = fixed.contains(text)
                let vci = fixed.lowercased().contains(text.lowercased())
                let vr = raw.contains(text)
                let vrci = raw.lowercased().contains(text.lowercased())
                plainSpans += 1
                if v { plainVerbatim += 1 }
                if vci { plainVerbatimCI += 1 }
                if vr { plainVerbatimRaw += 1 }
                if vrci { plainVerbatimRawCI += 1 }
                spanRows.append(["reason": span.reason, "start": span.start, "end": span.end, "text": text,
                                 "verbatim": v, "verbatim_ci": vci, "verbatim_raw": vr, "verbatim_ci_raw": vrci,
                                 "returned": NSNull()])
            }
            emit(["kind": "block", "id": block.id, "src": src, "dst": dst, "mode": "plain", "strategy": strategyName,
                  "target": fixed, "target_raw": raw, "spans": spanRows])
        }
        emit(["kind": "summary", "src": src, "dst": dst, "mode": "plain", "strategy": strategyName,
              "ms": plainMs, "blocks": blocks.count, "spans": plainSpans, "verbatim": plainVerbatim,
              "verbatim_ci": plainVerbatimCI, "verbatim_raw": plainVerbatimRaw, "verbatim_ci_raw": plainVerbatimRawCI])

        // MARK: marked — one attributed request per block, each literal span marked skipsTranslation
        let markedStart = Date()
        var markedRows = [[String: Any]]()
        var markedMs = 0
        await withTaskGroup(of: ([String: Any], Int).self) { group in
            var running = 0
            for block in blocks {
                if running >= markedConcurrency {
                    for await (row, ms) in group {
                        markedRows.append(row)
                        markedMs += ms
                        running -= 1
                    }
                }
                group.addTask {
                    var attributed = AttributedString(block.text)
                    for (n, span) in block.spans.enumerated() {
                        guard span.start >= 0, span.end <= block.text.count, span.start < span.end else { continue }
                        let lo = attributed.index(attributed.startIndex, offsetByCharacters: span.start)
                        let hi = attributed.index(attributed.startIndex, offsetByCharacters: span.end)
                        attributed[lo..<hi].translation.skipsTranslation = true
                        attributed[lo..<hi].link = markerURL(n)
                    }
                    let start = Date()
                    var raw = ""
                    var returnedMarkers = Set<Int>()
                    do {
                        let response = try await session.translate(attributed)
                        raw = response.targetText
                        if let t = response.attributedTargetText {
                            for run in t.runs {
                                if let url = run.link, let n = marker(of: url) { returnedMarkers.insert(n) }
                            }
                            raw = String(t.characters)
                        }
                    } catch {
                        let row: [String: Any] = ["kind": "note", "src": src, "dst": dst, "mode": "marked",
                                                  "strategy": strategyName, "id": block.id, "error": "\(error)"]
                        return (row, 0)
                    }
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    let fixed = TranslationCleanup.restoreSourceTokens(raw, source: block.text)
                    var spanRows = [[String: Any]]()
                    for (n, span) in block.spans.enumerated() {
                        let text = spanText(block.text, span)
                        spanRows.append(["reason": span.reason, "start": span.start, "end": span.end, "text": text,
                                         "verbatim": fixed.contains(text), "verbatim_ci": fixed.lowercased().contains(text.lowercased()),
                                         "verbatim_raw": raw.contains(text), "verbatim_ci_raw": raw.lowercased().contains(text.lowercased()),
                                         "returned": returnedMarkers.contains(n)])
                    }
                    let row: [String: Any] = ["kind": "block", "id": block.id, "src": src, "dst": dst, "mode": "marked",
                                              "strategy": strategyName, "target": fixed, "target_raw": raw, "ms": ms, "spans": spanRows]
                    return (row, ms)
                }
                running += 1
            }
            for await (row, ms) in group {
                markedRows.append(row)
                markedMs += ms
            }
        }
        let markedMsTotal = Int(Date().timeIntervalSince(markedStart) * 1000)
        var markedSpans = 0, markedVerbatim = 0, markedVerbatimCI = 0, markedVerbatimRaw = 0, markedVerbatimRawCI = 0, markedReturned = 0
        for row in markedRows {
            emit(row)
            guard let spanList = row["spans"] as? [[String: Any]] else { continue }
            for span in spanList {
                markedSpans += 1
                if span["verbatim"] as! Bool { markedVerbatim += 1 }
                if span["verbatim_ci"] as! Bool { markedVerbatimCI += 1 }
                if span["verbatim_raw"] as! Bool { markedVerbatimRaw += 1 }
                if span["verbatim_ci_raw"] as! Bool { markedVerbatimRawCI += 1 }
                if span["returned"] as! Bool { markedReturned += 1 }
            }
        }
        emit(["kind": "summary", "src": src, "dst": dst, "mode": "marked", "strategy": strategyName,
              "ms": markedMsTotal, "ms_sum_of_requests": markedMs, "blocks": blocks.count, "spans": markedSpans,
              "verbatim": markedVerbatim, "verbatim_ci": markedVerbatimCI, "verbatim_raw": markedVerbatimRaw,
              "verbatim_ci_raw": markedVerbatimRawCI, "returned": markedReturned])
    }
}
out.closeFile()

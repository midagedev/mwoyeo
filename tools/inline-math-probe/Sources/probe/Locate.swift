// Step 2: how often the text of an InlineMath span is found verbatim in the translation (design §3): spaces ignored, in order,
// only when the span text occurs as often in the translation as in the source. Reads the `.out` files of tools/paper-bench:
// a source line indented by two spaces, then its translation indented by four and an arrow.
import Foundation
import MwoyeoCore

enum Locate {
    struct Pair { var page: String; var source: String; var target: String }

    enum Verdict: String, CaseIterable {
        case located
        /// The span occurs in the translation, but not as often as in the source (or more often): which one is which is a guess.
        case count
        /// Every occurrence lies before the previous span's.
        case order
        /// The translation has it in another case ("Dk" at the start of a sentence).
        case caseChanged = "case"
        /// A prefix of at least half of it is there (a respaced or cut symbol, a particle glued into it).
        case partial
        /// Nothing of it: translated, dropped or rewritten.
        case gone
    }

    static func pairs(in dir: String, pages: [String]) -> [Pair] {
        var out: [Pair] = []
        for page in pages {
            guard let text = try? String(contentsOfFile: "\(dir)/\(page).out", encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: "\n")
            var i = 0
            while i + 1 < lines.count {
                let a = lines[i], b = lines[i + 1]
                if a.hasPrefix("  "), !a.hasPrefix("   "), b.hasPrefix("    → ") {
                    out.append(Pair(page: page, source: String(a.dropFirst(2)), target: String(b.dropFirst(6))))
                    i += 2
                } else {
                    i += 1
                }
            }
        }
        return out
    }

    static func stripped(_ s: String) -> [Character] { s.filter { !$0.isWhitespace } }

    /// Non-overlapping start offsets of `needle` in `hay`.
    static func occurrences(of needle: [Character], in hay: [Character]) -> [Int] {
        guard !needle.isEmpty, hay.count >= needle.count else { return [] }
        var at: [Int] = []
        var i = 0
        while i + needle.count <= hay.count {
            if hay[i] == needle[0], Array(hay[i..<i + needle.count]) == needle { at.append(i); i += needle.count } else { i += 1 }
        }
        return at
    }

    struct Result { var verdicts: [(span: String, verdict: Verdict)] }

    static func locate(_ pair: Pair) -> [(span: String, verdict: Verdict)] {
        let chars = Array(pair.source)
        let src = stripped(pair.source), tgt = stripped(pair.target)
        var cursor = 0
        var out: [(String, Verdict)] = []
        for span in InlineMath.spans(in: pair.source) {
            let text = String(chars[span.range])
            let key = stripped(text)
            let inSource = occurrences(of: key, in: src).count
            let at = occurrences(of: key, in: tgt)
            if at.count == inSource, !at.isEmpty {
                if let next = at.first(where: { $0 >= cursor }) {
                    cursor = next + key.count
                    out.append((text, .located))
                } else {
                    out.append((text, .order))
                }
            } else if !at.isEmpty {
                out.append((text, .count))
            } else if !occurrences(of: Array(String(key).lowercased()), in: Array(String(tgt).lowercased())).isEmpty {
                out.append((text, .caseChanged))
            } else if (1...max(1, key.count)).reversed().contains(where: { n in n * 2 >= key.count && n >= 2 && !occurrences(of: Array(key.prefix(n)), in: tgt).isEmpty }) {
                out.append((text, .partial))
            } else {
                out.append((text, .gone))
            }
        }
        return out
    }

    /// Pairs from a JSON list of sources and the JSON list of their translations (tools/apple-translation-probe/batch.swift's format);
    /// `page` names are kept in a third file, one per source.
    static func pairs(sources: String, targets: String, pages: String) -> [Pair] {
        func list(_ path: String) -> [String] { (try? JSONDecoder().decode([String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))) ?? [] }
        let s = list(sources), t = list(targets), p = list(pages)
        return s.indices.map { Pair(page: p.indices.contains($0) ? p[$0] : "?", source: s[$0], target: t.indices.contains($0) ? t[$0] : "") }
    }

    static func run(dir: String, pages: [String], verbose: Bool) {
        report(label: dir, all: pairs(in: dir, pages: pages), pages: pages, verbose: verbose)
    }

    static func report(label: String, all: [Pair], pages: [String], verbose: Bool) {
        print("locate \(label): \(all.count) source/translation pairs on \(pages.count) pages")
        var total: [Verdict: Int] = [:]
        var blocksWith = 0, blocksFull = 0, spansAll = 0
        for page in pages {
            var counts: [Verdict: Int] = [:]
            var withSpans = 0, full = 0, spans = 0
            for pair in all where pair.page == page {
                let r = locate(pair)
                guard !r.isEmpty else { continue }
                withSpans += 1
                if r.allSatisfy({ $0.verdict == .located }) { full += 1 }
                for (span, verdict) in r {
                    counts[verdict, default: 0] += 1
                    spans += 1
                    if verbose, verdict != .located { print("  \(page) \(verdict.rawValue): \(span)  <- \(pair.target.prefix(120))") }
                }
            }
            let kinds = Verdict.allCases.filter { $0 != .located && counts[$0, default: 0] > 0 }.map { "\($0.rawValue)=\(counts[$0]!)" }
            let rate = spans == 0 ? "n/a" : String(format: "%.0f%%", 100 * Double(counts[.located, default: 0]) / Double(spans))
            print("locate \(page): spans=\(spans) located=\(counts[.located, default: 0]) rate=\(rate) blocks_with_spans=\(withSpans) blocks_all_located=\(full)\(kinds.isEmpty ? "" : " failures: " + kinds.joined(separator: " "))")
            for (k, v) in counts { total[k, default: 0] += v }
            blocksWith += withSpans; blocksFull += full; spansAll += spans
        }
        let kinds = Verdict.allCases.filter { $0 != .located && total[$0, default: 0] > 0 }.map { "\($0.rawValue)=\(total[$0]!)" }
        let rate = spansAll == 0 ? "n/a" : String(format: "%.0f%%", 100 * Double(total[.located, default: 0]) / Double(spansAll))
        print("locate all: spans=\(spansAll) located=\(total[.located, default: 0]) rate=\(rate) blocks_with_spans=\(blocksWith) blocks_all_located=\(blocksFull)\(kinds.isEmpty ? "" : " failures: " + kinds.joined(separator: " "))")
    }
}

#if !MAS
import Foundation
import MwoyeoCore

/// What the first paint did over one headless `--render` (`--first-paint-log`; design first-lens §13): when the first translated line was drawn, when
/// each line's final text replaced its quick one, and whether the replacement changed the size or the height of the text drawn. Fed every snapshot the
/// pipeline makes (the way the lens window is), so what it saw is what a lens would have shown.
final class FirstPaintProbe: @unchecked Sendable {
    /// What one source looked like in a snapshot.
    private struct Look: Equatable { var fontSize: CGFloat; var height: CGFloat; var width: CGFloat }
    private struct Row {
        var firstDrawn: TimeInterval?
        var firstLook: Look?
        var finalAt: TimeInterval?
        var finalLook: Look?
        /// The first drawn state was a quick text (no translation in the block yet).
        var quickFirst = false
    }

    private let lock = NSLock()
    private var start: TimeInterval
    private var rows: [String: Row] = [:]
    private var order: [String] = []
    private var firstDrawnAt: TimeInterval?
    private var snapshots = 0

    init(start: TimeInterval) { self.start = start }

    /// The lens is added: times count from here.
    func begin() { lock.withLock { start = Trace.now } }

    func note(_ snapshot: OverlaySnapshot) {
        let now = Trace.now
        lock.withLock {
            snapshots += 1
            if firstDrawnAt == nil, !snapshot.blocks.isEmpty { firstDrawnAt = now }
            let translated = Set(snapshot.texts.filter { $0.translation != nil }.map(\.source))
            for d in snapshot.drawn {
                let look = Look(fontSize: d.fontSize, height: d.text.height, width: d.text.width)
                if rows[d.source] == nil { order.append(d.source) }
                var row = rows[d.source] ?? Row()
                if row.firstDrawn == nil {
                    row.firstDrawn = now
                    row.firstLook = look
                    row.quickFirst = !translated.contains(d.source)
                }
                if translated.contains(d.source), row.finalAt == nil {
                    row.finalAt = now
                    row.finalLook = look
                }
                rows[d.source] = row
            }
        }
    }

    /// The report lines: one summary, and one per source that was drawn. `lines` is the pipeline's own book (`RegionPipeline.firstPaintLines`).
    func report(lines: [String: FirstPaintBook.Line], stats: FirstPaintBook.Stats, firstFlightAt: TimeInterval?) -> [String] {
        lock.withLock {
            func ms(_ t: TimeInterval?) -> String { t.map { String(format: "%.0f", ($0 - start) * 1000) } ?? "-" }
            // A painted line's final text landed when the book settled it; a line kept as it was is not drawn again, so the snapshots do not show it.
            func landed(_ source: String, _ row: Row) -> TimeInterval? { row.quickFirst ? lines[source]?.settledAt ?? row.finalAt : row.finalAt }
            let finals = rows.compactMap { landed($0.key, $0.value) }
            var out = ["first-paint: start_uptime_ms=\(String(format: "%.0f", start * 1000)) first_request_ms=\(ms(firstFlightAt)) first_drawn_ms=\(ms(firstDrawnAt)) first_final_ms=\(ms(finals.min())) last_final_ms=\(ms(finals.max())) "
                       + "drawn=\(rows.count) snapshots=\(snapshots)"]
            var refit = 0, painted = 0
            for source in order {
                guard let row = rows[source] else { continue }
                let line = lines[source]
                var changed = ""
                if row.quickFirst, let a = row.firstLook, let b = row.finalLook {
                    painted += 1
                    let sizeMoved = abs(a.fontSize - b.fontSize) > 0.05, heightMoved = abs(a.height - b.height) > 1
                    if sizeMoved || heightMoved { refit += 1 }
                    changed = String(format: " size=%.1f>%.1f ink_h=%.0f>%.0f ink_w=%.0f>%.0f%@", a.fontSize, b.fontSize, a.height, b.height, a.width, b.width,
                                     sizeMoved || heightMoved ? " REFIT" : "")
                }
                let distance = line.flatMap { l in l.provisional.flatMap { p in l.final.map { FirstPaintBook.distance(p, $0) } } }
                out.append("fp-line: drawn_ms=\(ms(row.firstDrawn)) final_ms=\(ms(landed(source, row))) quick_first=\(row.quickFirst ? 1 : 0) "
                           + "shown_ms=\(line?.shownFor.map { String(format: "%.0f", $0 * 1000) } ?? "-") dist=\(distance.map(String.init) ?? "-")\(changed) "
                           + "src=\"\(source.prefix(40).replacingOccurrences(of: "\n", with: " "))\"")
            }
            let shown = stats.shownFor.sorted()
            out.append("fp-summary: lines=\(rows.count) painted=\(painted) repainted=\(stats.repainted) kept=\(stats.kept) open=\(stats.open) refit=\(refit) "
                       + "chars_changed=\(stats.charsChanged) chars_final=\(stats.charsFinal) "
                       + "shown_ms[p50=\(shown.isEmpty ? "-" : String(format: "%.0f", shown[shown.count / 2] * 1000)) "
                       + "max=\(shown.last.map { String(format: "%.0f", $0 * 1000) } ?? "-")]")
            return out
        }
    }
}
#endif

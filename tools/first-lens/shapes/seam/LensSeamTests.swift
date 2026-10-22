import CoreGraphics
import Testing
@testable import MwoyeoCore

/// 2026-10-22 shapes117: the seam between the reading column and the content shapes (docs/design/lens-shapes.md section 6). A page with a
/// reading column and, beside it, a list with its title (a shape). Two owners take one pointer: each lets go of it only `switchBy` beyond
/// where it would take it, and the choice never goes A, B, A under 2 pt of jitter. FAIL-first: `plain` is the seam without that rule.
@Suite struct LensSeamTests {
    private let display = CGRect(x: 0, y: 0, width: 900, height: 640)

    /// One read: the column rule's map and the shapes' map over the same blocks.
    private struct Page {
        let column: LensTarget.Map, shapes: LensShape.Map, bounds: CGRect
        init(_ blocks: [ColumnFit.Block], bounds: CGRect) {
            column = LensTarget.Map(blocks: blocks); shapes = LensShape.Map(blocks: blocks.map(LensShape.Block.init)); self.bounds = bounds
        }

        func seam(_ p: CGPoint, _ held: LensTarget.Target?) -> LensTarget.Target? {
            let map = shapes, bounds = bounds
            return LensTarget.choose(column, pointer: p, held: held, bounds: bounds) { q, h in LensShape.choose(map, pointer: q, bounds: bounds, held: h) }
        }

        /// The seam without the hold: the column's choice where there is one, else the shape's (what a bare `column ?? shape` does).
        func plain(_ p: CGPoint, _ held: LensTarget.Target?) -> LensTarget.Target? {
            LensTarget.choose(column, pointer: p, held: held?.shape == nil ? held : nil, bounds: bounds)
                ?? LensShape.choose(shapes, pointer: p, bounds: bounds, held: held?.shape).map(LensTarget.Target.init(shape:))
        }
    }

    private static func paragraphs(x: CGFloat, width: CGFloat, from y: CGFloat = 100, lines: [Int] = [3, 5, 4, 3, 5]) -> [ColumnFit.Block] {
        var out: [ColumnFit.Block] = [], y = y
        for n in lines {
            out.append(ColumnFit.Block(core: CGRect(x: x, y: y, width: width, height: CGFloat(n) * 14), lines: n))
            y += CGFloat(n) * 14 + 10
        }
        return out
    }

    /// Five paragraphs in a column 60..400, and a list with its title 50 pt to the right of it.
    private var page: Page {
        var blocks = Self.paragraphs(x: 60, width: 340)
        blocks.append(ColumnFit.Block(core: CGRect(x: 450, y: 100, width: 120, height: 14), lines: 1))
        for k in 0..<4 { blocks.append(ColumnFit.Block(core: CGRect(x: 466, y: 124 + CGFloat(k) * 22, width: 150, height: 14), lines: 1)) }
        return Page(blocks, bounds: display)
    }

    /// Two columns a gutter of 20 apart (the slack of each reaches into the other).
    private var gutter: Page { Page(Self.paragraphs(x: 60, width: 340) + Self.paragraphs(x: 420, width: 340, from: 80, lines: [4, 3, 5, 4]), bounds: display) }

    @Test func aShapeTakesThePointerWhereTheColumnHasNone() throws {
        let list = try #require(page.seam(CGPoint(x: 540, y: 150), nil))
        #expect(list.shape?.kind == .group && list.column == -1)
        #expect(list.rect == CGRect(x: 444, y: 94, width: 178, height: 116))
        let text = try #require(page.seam(CGPoint(x: 200, y: 160), nil))
        #expect(text.shape == nil && text.column >= 0)
        #expect(page.seam(CGPoint(x: 800, y: 600), nil) == nil)
    }

    /// A fresh pointer (nothing held) gets what the column rule gives, or the shape where it gives nothing; a fallback that finds nothing
    /// changes nothing.
    @Test func aFallbackThatFindsNothingChangesNothing() {
        let map = page
        var y: CGFloat = 5
        while y < display.height {
            var x: CGFloat = 5
            while x < display.width {
                let p = CGPoint(x: x, y: y)
                let none = LensTarget.choose(map.column, pointer: p, bounds: display, fallback: { _, _ in nil })
                #expect(none == LensTarget.choose(map.column, pointer: p, bounds: display), "\(p)")
                x += 5
            }
            y += 5
        }
    }

    /// The column holds a pointer 12 pt beyond its padded edge (418); held, it keeps it to 8 pt further, then lets go; a shape that holds the
    /// pointer gives it back to the column only 8 pt inside.
    @Test func eachOwnerLetsGoOnlySwitchByBeyond() throws {
        let held = try #require(page.seam(CGPoint(x: 200, y: 160), nil))
        #expect(LensTarget.choose(page.column, pointer: CGPoint(x: 419, y: 160), bounds: display) == nil, "the column rule alone ends at 418")
        #expect(page.seam(CGPoint(x: 419, y: 160), held) == held, "held, it keeps going")
        #expect(page.seam(CGPoint(x: 425, y: 160), held) == held)
        #expect(page.seam(CGPoint(x: 427, y: 160), held)?.column != held.column, "8 pt beyond, it lets go")
        // From the list, back toward the column: the column takes the pointer only deep inside its reach.
        let list = try #require(page.seam(CGPoint(x: 540, y: 150), nil))
        #expect(page.seam(CGPoint(x: 415, y: 107), list)?.shape != nil, "within the column's reach, not deep: the shape stays")
        #expect(page.seam(CGPoint(x: 395, y: 107), list)?.shape == nil, "deep inside: the column takes it")
    }

    private func reversals(_ choose: (CGPoint, LensTarget.Target?) -> LensTarget.Target?) -> (changes: Int, reversals: Int, at: String?) {
        var s: UInt64 = 1
        func next() -> CGFloat { s = s &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(s >> 11) / CGFloat(1 << 53) }
        func key(_ t: LensTarget.Target?) -> String { t.map { "\($0.shape?.kind.rawValue ?? "column") \($0.rect)" } ?? "ghost" }
        var changes = 0, count = 0, at: String?
        for vertical in [false, true] {
            var line: CGFloat = 5
            while line < (vertical ? display.width : display.height) {
                var held: LensTarget.Target?, last = "ghost", along: CGFloat = 0
                while along < (vertical ? display.height : display.width) {
                    let p = vertical ? CGPoint(x: line, y: along) : CGPoint(x: along, y: line)
                    let t = choose(p, held)
                    if key(t) != last {
                        changes += 1
                        var h = held, seq: [String] = []
                        for _ in 0..<30 {
                            let r = choose(CGPoint(x: p.x + next() * 4 - 2, y: p.y + next() * 4 - 2), h)
                            seq.append(key(r)); h = r
                        }
                        let rev = (2..<seq.count).filter { seq[$0] == seq[$0 - 2] && seq[$0] != seq[$0 - 1] }
                        count += rev.count
                        if at == nil, let i = rev.first { at = "\(p): \(seq[i - 1]) <-> \(seq[i])" }
                    }
                    held = t; last = key(t)
                    along += 3
                }
                line += 20
            }
        }
        return (changes, count, at)
    }

    @Test func theSeamDoesNotFlickerUnderJitter() {
        let p = page
        let held = reversals(p.seam), bare = reversals(p.plain)
        #expect(held.changes > 20)
        #expect(held.reversals == 0, "\(held.at ?? "")")
        #expect(bare.reversals > 0, "without the rule the same walk flickers (the measure's teeth)")
    }

    /// Where two columns' slack overlap the nearer takes the pointer; held, a column keeps it until the other is `switchBy` the nearer.
    @Test func aGutterBetweenColumnsDoesNotFlickerUnderJitter() {
        let g = gutter
        let held = reversals(g.seam), bare = reversals(g.plain)
        #expect(held.reversals == 0, "\(held.at ?? "")")
        #expect(bare.reversals > 0, "without the rule the same walk flickers (the measure's teeth)")
    }
}

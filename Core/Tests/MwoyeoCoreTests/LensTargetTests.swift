import CoreGraphics
import Testing
@testable import MwoyeoCore

/// A drawn two-column page, in points with y down: columns at 60..400 and 448..788 (a 48 pt gutter), paragraphs of 14 pt lines 10 pt
/// apart, and above the left column a one-line heading 66 pt clear of the first paragraph.
private enum DrawnPage {
    static let left: (CGFloat, CGFloat) = (60, 400), right: (CGFloat, CGFloat) = (448, 788)
    static let heading = ColumnFit.Block(core: CGRect(x: 60, y: 40, width: 240, height: 14), lines: 1)

    static func column(_ x: (CGFloat, CGFloat), from y: CGFloat, lines: [Int]) -> [ColumnFit.Block] {
        var out: [ColumnFit.Block] = [], y = y
        for n in lines {
            out.append(ColumnFit.Block(core: CGRect(x: x.0, y: y, width: x.1 - x.0, height: CGFloat(n) * 14), lines: n))
            y += CGFloat(n) * 14 + 10
        }
        return out
    }

    static var blocks: [ColumnFit.Block] {
        [heading] + column(left, from: 120, lines: [3, 5, 4, 3, 5, 4]) + column(right, from: 80, lines: [4, 3, 5, 4, 3, 4])
    }
}

/// 2026-10-22 oneclick117: the one-click lens's target (docs/design/first-lens.md 4.1, gates 1, 2 and 7 of section 7).
@Suite struct LensTargetTests {
    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)

    // MARK: Gate 1: the rule

    @Test func onPage10APointerInAParagraphGetsItsColumnByWholeParagraphs() throws {
        let map = LensTarget.Map(blocks: PaperPage10.blocks)
        #expect(map.readingColumns == 2)
        for (x, column) in [(200 as CGFloat, PaperPage10.leftColumn), (600, PaperPage10.rightColumn)] {
            for y in stride(from: 300 as CGFloat, through: 900, by: 50) {
                guard let t = LensTarget.choose(map, pointer: CGPoint(x: x, y: y), bounds: display) else { continue }
                let c = map.columns[t.column], members = c.members.map(\.core)
                // The rect is the column ± 6 pt (on the pixel grid), within 3 pt of the PDF's own column edges.
                #expect(abs(t.rect.minX - (c.left - 6)) <= 0.5 && abs(t.rect.maxX - (c.right + 6)) <= 0.5)
                #expect(abs(t.rect.minX - (column.left - 6)) <= 3 && abs(t.rect.maxX - (column.right + 6)) <= 3, "\(t.rect) for \(column)")
                // It starts at its anchor's top and ends on a block's bottom; where nothing within 44 pt follows its bottom, it may have
                // grown upward instead, by whole blocks.
                // 2026-10-23 (film5): the rect is the lines padded by `ColumnFit.pad` (6 pt) above and below, as at the sides.
                let top = t.rect.minY + 6, bottom = t.rect.maxY - 6
                let grewUp = !members.contains { $0.minY > bottom && $0.minY - bottom <= LensTarget.breakGap }
                #expect(abs(top - members[t.anchor].minY) <= 0.5 || (grewUp && members.contains { abs($0.minY - top) <= 0.5 }),
                        "\(t.rect) anchor \(members[t.anchor])")
                #expect(members.contains { abs($0.maxY - bottom) <= 0.5 || ($0.maxY + 6 > display.maxY && t.rect.maxY == display.maxY) }, "\(t.rect) ends inside a block")   // the pad stops at the display
            }
        }
        // Every pointer inside a paragraph of several lines has a target.
        for b in PaperPage10.blocks where b.lines >= 2 {
            #expect(LensTarget.choose(map, pointer: CGPoint(x: b.core.midX, y: b.core.midY), bounds: display) != nil, "\(b.core)")
        }
    }

    @Test func theDrawnPageGetsBothColumnsAndNothingInTheGutterOrOverALoneHeading() throws {
        let map = LensTarget.Map(blocks: DrawnPage.blocks)
        #expect(map.readingColumns == 2)
        let left = try #require(LensTarget.choose(map, pointer: CGPoint(x: 200, y: 140), bounds: display))
        #expect(left.rect.minX == 54 && left.rect.maxX == 406 && left.rect.minY == 114)   // 2026-10-23 (film5): 120 less the 6 pt pad
        let right = try #require(LensTarget.choose(map, pointer: CGPoint(x: 600, y: 100), bounds: display))
        #expect(right.rect.minX == 442 && right.rect.maxX == 794 && right.rect.minY == 74)
        // The gutter's middle is more than 12 pt from both padded edges.
        #expect(LensTarget.choose(map, pointer: CGPoint(x: 424, y: 200), bounds: display) == nil)
        // The heading is one line with nothing within 44 pt below it.
        #expect(LensTarget.choose(map, pointer: CGPoint(x: 100, y: 47), bounds: display) == nil)
        // Far below every paragraph, and in the margin far left of every column.
        #expect(LensTarget.choose(map, pointer: CGPoint(x: 200, y: 900), bounds: display) == nil)
        #expect(LensTarget.choose(map, pointer: CGPoint(x: 20, y: 200), bounds: display) == nil)
        // Within 12 pt of a padded edge, the column still holds the pointer.
        #expect(LensTarget.choose(map, pointer: CGPoint(x: 400 + 6 + 11, y: 140), bounds: display)?.column == left.column)
    }

    @Test func aColumnNarrowerThan160PointsIsNotAReadingColumn() {
        let narrow = (0..<4).map { ColumnFit.Block(core: CGRect(x: 100, y: 100 + CGFloat($0) * 40, width: 150, height: 28), lines: 2) }
        let map = LensTarget.Map(blocks: narrow)
        #expect(map.columns.count == 1 && map.readingColumns == 0)
        // 2026-10-23 (film5): not a reading column, but a group (a list): its target is the group's, column -1.
        #expect(LensTarget.choose(map, pointer: CGPoint(x: 170, y: 150), bounds: display)?.column == -1)
        let wide = (0..<4).map { ColumnFit.Block(core: CGRect(x: 100, y: 100 + CGFloat($0) * 40, width: 160, height: 28), lines: 2) }
        #expect(LensTarget.choose(LensTarget.Map(blocks: wide), pointer: CGPoint(x: 170, y: 150), bounds: display) != nil)
    }

    @Test func theHeightIsTheBudgetInWholeParagraphs() throws {
        // Paragraphs 46 pt tall, 56 pt apart, in a 340 pt column: the budget is 560 × 320 / 352 = 509 pt. Nine paragraphs make 494 pt; the
        // tenth would end at 550 with 15 pt of budget left, less than half of it: it stays out.
        let blocks = (0..<14).map { ColumnFit.Block(core: CGRect(x: 60, y: 100 + CGFloat($0) * 56, width: 340, height: 46), lines: 3) }
        let map = LensTarget.Map(blocks: blocks)
        let t = try #require(LensTarget.choose(map, pointer: CGPoint(x: 200, y: 120), bounds: CGRect(x: 0, y: 0, width: 1512, height: 2000)))
        #expect(t.rect.minY == 94 && t.rect.height == 506)   // 2026-10-23 (film5): 100..594 padded 6 pt each way
        // A narrow column gets the taller budget (capped at 560), a wide one the shorter (at least 160).
        let narrow = (0..<14).map { ColumnFit.Block(core: CGRect(x: 60, y: 100 + CGFloat($0) * 56, width: 200, height: 46), lines: 3) }
        let n = try #require(LensTarget.choose(LensTarget.Map(blocks: narrow), pointer: CGPoint(x: 100, y: 120), bounds: CGRect(x: 0, y: 0, width: 1512, height: 2000)))
        #expect(n.rect.height <= 560 + 23 + 12 && n.rect.height > 506)
        let wide = (0..<14).map { ColumnFit.Block(core: CGRect(x: 60, y: 100 + CGFloat($0) * 56, width: 1300, height: 46), lines: 3) }
        let w = try #require(LensTarget.choose(LensTarget.Map(blocks: wide), pointer: CGPoint(x: 100, y: 120), bounds: CGRect(x: 0, y: 0, width: 1512, height: 2000)))
        #expect(w.rect.height == 170)   // budget 160: three paragraphs make 158 pt; the fourth would end at 214 with 2 pt left: out
    }

    @Test func theWindowAndTheDisplayClampItBelowTheTitleBar() throws {
        let map = LensTarget.Map(blocks: DrawnPage.blocks)
        // A window whose content starts at y 128 (its title bar 100..128) and ends at 600, narrower than the column on the left.
        let window = CGRect(x: 120, y: 100, width: 900, height: 500)
        let bounds = LensTarget.content(of: window, on: display)
        #expect(bounds == CGRect(x: 120, y: 128, width: 900, height: 472))
        let t = try #require(LensTarget.choose(map, pointer: CGPoint(x: 200, y: 140), bounds: bounds))
        #expect(t.rect.minY == 128 && t.rect.minX == 120 && t.rect.maxX == 406 && t.rect.maxY <= 600)
        // A window of 120 pt or less has no title bar to keep clear of; the display clamps too.
        #expect(LensTarget.content(of: CGRect(x: 1400, y: 900, width: 300, height: 120), on: display) == CGRect(x: 1400, y: 900, width: 112, height: 82))
        #expect(LensTarget.content(of: nil, on: display) == display)
    }

    /// 2026-10-23 (film5 probe): a desktop of several windows. A window's own map keeps another window's blocks out of its columns, and a
    /// chat's messages (15.5 pt type, 48 pt apart) make one target, not one per message.
    @Test func aWindowsOwnMapAndAChatsMessagesMakeOneTarget() throws {
        // A chat window above a docs window, both with text at x 900..1270.
        let chat = (0..<5).map { ColumnFit.Block(core: CGRect(x: 900, y: 140 + CGFloat($0) * 92, width: 370, height: 44), lines: 2) }
        let table = (0..<3).map { ColumnFit.Block(core: CGRect(x: 900, y: 760 + CGFloat($0) * 40, width: 300, height: 36), lines: 2) }
        let whole = LensTarget.Map(blocks: chat + table)
        #expect(whole.columns.contains { c in c.members.contains { $0.core.minY >= 760 } && c.members.contains { $0.core.minY < 600 } })
        let own = whole.scoped { $0.y < 600 }
        #expect(own.columns.allSatisfy { c in c.members.allSatisfy { $0.core.minY < 600 } })
        let t = try #require(LensTarget.choose(own, pointer: CGPoint(x: 1000, y: 160), bounds: CGRect(x: 830, y: 100, width: 600, height: 470)))
        #expect(t.rect.minY == 134 && t.rect.maxY >= 140 + 2 * 92 + 44, "\(t.rect): the next messages are in it")
        // One's own message on the right, between two of the others': the outline takes it in. A paper's other column does not (the other tests).
        let mine = ColumnFit.Block(core: CGRect(x: 1180, y: 140 + 92 + 44 + 4, width: 230, height: 20), lines: 1)
        let thread = LensTarget.Map(blocks: chat + [mine])
        let u = try #require(LensTarget.choose(thread, pointer: CGPoint(x: 1000, y: 160), bounds: CGRect(x: 830, y: 100, width: 600, height: 470)))
        #expect(u.rect.maxX == 1416, "\(u.rect)")
    }

    @Test func shortOfRoomBelowItGrowsUpwardByWholeParagraphs() throws {
        let map = LensTarget.Map(blocks: DrawnPage.blocks)
        // The last paragraph of the left column (4 lines, 56 pt) is the anchor; nothing below it.
        let last = map.columns[0].members.last!.core
        let t = try #require(LensTarget.choose(map, pointer: CGPoint(x: 200, y: last.midY), bounds: display))
        #expect(t.rect.maxY == last.maxY + 6 && t.rect.minY + 6 < last.minY)   // 2026-10-23 (film5): padded 6 pt
        #expect(map.columns[0].members.contains { $0.core.minY == t.rect.minY + 6 }, "it grows by whole members")
        // A window that ends inside a paragraph: the lens ends at the window, and grows upward instead.
        let cut = CGRect(x: 0, y: 0, width: 1512, height: 200)
        let u = try #require(LensTarget.choose(map, pointer: CGPoint(x: 200, y: 180), bounds: cut))
        #expect(u.rect.maxY == 200 && u.rect.minY == 114)
    }

    /// Fails with the anchor not held: `data/hover-paper.txt` counts 107 to 1253 reversals per column on the paper pages without the 8 pt rule.
    @Test func jitterOfTwoPointsAtEveryBoundaryNeverFlipsTheTarget() {
        var rng = SplitMix(seed: 1)
        var reversals = 0, boundaries = 0, targets = 0
        for blocks in [PaperPage10.blocks, DrawnPage.blocks] {
            let map = LensTarget.Map(blocks: blocks)
            for c in map.columns where c.width >= LensTarget.minWidth {
                let x = (c.left + c.right) / 2
                for (a, b) in zip(c.members, c.members.dropFirst()) {
                    boundaries += 1
                    let mid = (a.core.maxY + b.core.minY) / 2
                    var held: LensTarget.Target?, seen: [Int?] = []
                    for _ in 0..<200 {
                        held = LensTarget.choose(map, pointer: CGPoint(x: x, y: mid + rng.uniform(-2, 2)), held: held, bounds: display)
                        seen.append(held?.anchor)
                        targets += held == nil ? 0 : 1
                    }
                    reversals += (2..<seen.count).filter { seen[$0] == seen[$0 - 2] && seen[$0] != seen[$0 - 1] }.count
                }
            }
        }
        #expect(boundaries > 20 && targets > boundaries * 100, "\(targets) targets at \(boundaries) boundaries")
        #expect(reversals == 0, "\(reversals) reversals at \(boundaries) boundaries")
    }

    @Test func theSameAnchorGivesTheSameRectWhereverThePointerIsInsideIt() {
        for blocks in [PaperPage10.blocks, DrawnPage.blocks] {
            let map = LensTarget.Map(blocks: blocks)
            for c in map.columns where c.width >= LensTarget.minWidth {
                for m in c.members where m.lines >= 2 {
                    let rects = Set(stride(from: m.core.minY + 0.5, to: m.core.maxY, by: 3).compactMap {
                        LensTarget.choose(map, pointer: CGPoint(x: (c.left + c.right) / 2, y: $0), bounds: display)?.rect
                    }.map { "\($0)" })
                    #expect(rects.count == 1, "\(m.core): \(rects)")
                }
            }
        }
    }

    // MARK: Gate 2: the default is untouched

    /// `PickerView.clickLens(at:)` as it was before the one-click lens (main 3a2e86a), in the view's own space.
    private func before(_ p: CGPoint, window: CGRect?, bounds: CGRect) -> CGRect {
        var area = bounds
        if let w = window {
            let titleBar: CGFloat = w.height > 120 ? 28 : 0
            area = w.intersection(bounds)
            area.size.height -= titleBar // AppKit y is up: the title bar is the top strip
        }
        let size = CGSize(width: min(KeyboardLens.defaultSize.width, area.width), height: min(KeyboardLens.defaultSize.height, area.height))
        let x = min(max(p.x - size.width / 2, area.minX), area.maxX - size.width)
        let y = min(max(p.y - size.height / 2, area.minY), area.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    @Test func withNoTargetTheClickIsTodaysGhostByteForByte() {
        var rng = SplitMix(seed: 7)
        // A chat: one- and two-line messages of every width, no column of 4 lines.
        let chat = (0..<12).map { (i: Int) -> ColumnFit.Block in
            let two = i % 4 == 0
            let x: CGFloat = 40 + CGFloat(i % 3) * 30, y: CGFloat = 60 + CGFloat(i) * 70, width: CGFloat = 180 + CGFloat(i * 37 % 300)
            return ColumnFit.Block(core: CGRect(x: x, y: y, width: width, height: two ? 30 : 15), lines: two ? 2 : 1)
        }
        let maps = [LensTarget.Map(blocks: chat), LensTarget.Map(blocks: [])]
        #expect(maps.allSatisfy { $0.readingColumns == 0 })
        for i in 0..<500 {
            let p = CGPoint(x: rng.uniform(-20, 1532), y: rng.uniform(-20, 1002))
            let window: CGRect? = i % 5 == 0 ? nil : CGRect(x: rng.uniform(-200, 1400), y: rng.uniform(-100, 900), width: rng.uniform(40, 1600), height: rng.uniform(40, 1100))
            // 2026-10-23 (film5): a chat's messages may make a group target (column -1); never a column's.
            for map in maps { #expect(LensTarget.choose(map, pointer: p, bounds: display).map { $0.column == -1 } ?? true) }
            let ghost = LensTarget.ghost(at: p, window: window, in: display), old = before(p, window: window, bounds: display)
            let bits = { (r: CGRect) in [r.minX, r.minY, r.width, r.height].map(\.bitPattern) }
            #expect(bits(ghost) == bits(old), "pointer \(p) window \(String(describing: window))")
        }
    }

    // MARK: Gate 7: the glide, and Reduce Motion

    @Test func theGlideStartsWhereItWasEndsOnTheTargetAndNeverOvershoots() throws {
        let a = CGRect(x: 100, y: 100, width: 340, height: 400), b = CGRect(x: 448, y: 80, width: 352, height: 250)
        var g = LensTarget.Glide()
        g.move(to: a, at: 0, .glide)
        #expect(g.rect(at: 0) == a, "the first rect appears where it is")
        g.move(to: b, at: 1, .glide)
        #expect(g.rect(at: 1) == a)
        var last = a
        for f in 1...30 {
            let r = try #require(g.rect(at: 1 + Double(f) / 60))
            #expect(r.minX >= last.minX && r.minX <= b.minX && r.height <= last.height && r.height >= b.height)
            last = r
        }
        #expect(g.rect(at: 1 + LensTarget.glide) == b)
        #expect(g.moving(at: 1.1) && !g.moving(at: 1 + LensTarget.glide))
        // 90 % of the way at 130 ms (the motion contract's `quick`).
        g.move(to: a, at: 2, .glide)
        let at130 = try #require(g.rect(at: 2.13))
        #expect(abs((at130.minX - b.minX) / (a.minX - b.minX) - 0.9) < 0.02)
    }

    @Test func aChangeOfMindKeepsTheRectAndItsVelocity() throws {
        let a = CGRect(x: 0, y: 0, width: 300, height: 300), b = CGRect(x: 300, y: 0, width: 300, height: 300), c = CGRect(x: 300, y: 300, width: 300, height: 300)
        var g = LensTarget.Glide()
        g.move(to: a, at: 0, .jump)
        g.move(to: b, at: 0, .glide)
        let before = try #require(g.rect(at: 0.08)), course = (1...6).compactMap { g.rect(at: 0.08 + Double($0) / 120)?.minX }
        g.move(to: c, at: 0.08, .glide)
        let after = try #require(g.rect(at: 0.08))
        #expect(after == before, "no jump at the change")
        #expect((1...6).compactMap { g.rect(at: 0.08 + Double($0) / 120)?.minX } == course, "x goes on as it was going, speed and all")
        #expect(g.rect(at: 0.08 + LensTarget.glide) == c)
    }

    @Test func underReduceMotionItJumpsAndAFollowMovesAtOnce() {
        let a = CGRect(x: 0, y: 0, width: 300, height: 300), b = CGRect(x: 300, y: 40, width: 200, height: 100)
        var g = LensTarget.Glide()
        g.move(to: a, at: 0, .jump)
        g.move(to: b, at: 0, .jump)
        #expect(g.rect(at: 0) == b && !g.moving(at: 0))
        // Reduce Motion turned on in mid-glide: the next change jumps, and nothing of the glide is left.
        g.move(to: a, at: 0.5, .glide)
        g.move(to: b, at: 0.55, .jump)
        #expect(g.rect(at: 0.55) == b && !g.moving(at: 0.55))
        // The ghost under a moving pointer follows it frame for frame; a glide under way goes on.
        g.move(to: a, at: 1, .glide)
        g.move(to: a.offsetBy(dx: 10, dy: 0), at: 1.05, .follow)
        let mid = g.rect(at: 1.05)!
        #expect(g.target == a.offsetBy(dx: 10, dy: 0) && g.moving(at: 1.05) && mid != g.target)
        #expect(g.rect(at: 1 + LensTarget.glide) == a.offsetBy(dx: 10, dy: 0))
        g.clear()
        #expect(g.rect(at: 2) == nil)
    }
}

/// A seeded generator, so a failure names the same pointers every run.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat { lo + (hi - lo) * CGFloat(next() >> 11) / CGFloat(1 << 53) }
}

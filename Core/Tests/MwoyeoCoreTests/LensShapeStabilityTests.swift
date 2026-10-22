import CoreGraphics
import Testing
@testable import MwoyeoCore

/// The kind a pointer gets must not change with a point of the read (round shapestab, docs/design/lens-shapes.md section 13): hero2o found that
/// the film stage's table, heading and dialog changed kind when the stage was read again one point lower, and in the live take (`LensShapeHeroScenes`:
/// the picker's reads, five of them one point apart, and the zoom case and the live take at 0.888). The stops are the stage's five shapes under
/// the pointer, each with the kind it is meant to get and the panel it stands in (a lens never reaches into the next panel); the reads are
/// moved, scaled and jittered in the ways a re-read moves them.
/// FAIL-first: tools/first-lens/shapes/mutants.sh runs this file against LensShape without the rules of section 13 and against named mutants.
@Suite struct LensShapeStabilityTests {
    typealias Block = LensShape.Block

    /// The window's content on the screen (hero2o's hero window: the stage under a 28 pt title bar, 1512 x 839 pt).
    private static let bounds = CGRect(x: 0, y: 61, width: 1512, height: 839)

    /// A stop of the film stage (tools/first-lens/stage/path.json; hero.html moved the game 96 pt up, so its dialog stop is at 754, not 850): a
    /// stage point, the kind it is meant to get, and its panel: 0 the article, 1 the chat, 2 the table and the game.
    private struct Stop { let name: String, x: CGFloat, y: CGFloat, kind: LensShape.Kind, panel: Int }

    private static func stops(zoom: CGFloat) -> [Stop] {
        [Stop(name: "heading", x: 240, y: 64, kind: .group, panel: 0), Stop(name: "thread", x: 770, y: 176, kind: .thread, panel: 1),
         Stop(name: "table", x: 1236, y: 140, kind: .table, panel: 2), Stop(name: "subtitles", x: 1240, y: 492, kind: .subtitles, panel: 2),
         Stop(name: "dialog", x: 1180, y: zoom == 1 ? 754 : 850, kind: .dialog, panel: 2)]
    }

    /// Where the panels part: the middles of the stage's two gutters (594..646 and 936..1002 in hero.html, 618..659 and 921..974 at 0.888).
    private static func gutters(zoom: CGFloat) -> [CGFloat] { zoom == 1 ? [620, 969] : [638, 947] }

    /// The pointer is `zoom` times the stop's point, 61 pt below the screen's top, `dy` lower when the stage was read `dy` lower.
    private static func pointer(_ s: Stop, zoom: CGFloat, dy: CGFloat = 0) -> CGPoint { CGPoint(x: s.x * zoom, y: s.y * zoom + bounds.minY + dy) }

    /// What is wrong with the shape `blocks` give at the stop, or nil: its kind, and its rect inside the stop's panel (`gutters` as they stand in
    /// these blocks).
    private static func problem(_ blocks: [Block], _ s: Stop, gutters: [CGFloat], pointer p: CGPoint, want: LensShape.Kind?) -> String? {
        let got = LensShape.choose(blocks: blocks, pointer: p, bounds: bounds)
        guard got?.kind == want else { return "\(s.name): \(got?.kind.rawValue ?? "ghost"), want \(want?.rawValue ?? "ghost")" }
        guard let rect = got?.rect else { return nil }
        let left = s.panel == 0 ? -CGFloat.infinity : gutters[s.panel - 1], right = s.panel == 2 ? CGFloat.infinity : gutters[s.panel]
        return rect.minX >= left && rect.maxX <= right ? nil : "\(s.name): \(got!.kind.rawValue) \(rect) reaches out of its panel \(left)...\(right)"
    }

    /// The reads where Vision lost the paragraph under the heading (hc3 has the last line of it only): a heading alone is no group, and no
    /// geometry brings the paragraph back. Pinned as the ghost so that a change here is seen.
    private static let readLostText: [String: Set<String>] = ["hc3": ["heading"]]

    // MARK: - The picker's reads

    @Test func readsOfTheStageKeepTheirKinds() {
        for read in LensShapeHeroScenes.all {
            for s in Self.stops(zoom: read.zoom) {
                let lost = Self.readLostText[read.name]?.contains(s.name) == true
                let why = Self.problem(read.blocks, s, gutters: Self.gutters(zoom: read.zoom), pointer: Self.pointer(s, zoom: read.zoom, dy: read.dy), want: lost ? nil : s.kind)
                #expect(why == nil, "\(read.name) \(why ?? "")")
            }
        }
    }

    // MARK: - A re-read moves the blocks

    /// `blocks` with the stage moved by `dx`, `dy` and scaled by `zoom` about the window's top left (the zoom case of the film).
    private static func moved(_ blocks: [Block], dx: CGFloat = 0, dy: CGFloat = 0, zoom: CGFloat = 1) -> [Block] {
        func at(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * zoom + dx, y: (r.minY - bounds.minY) * zoom + bounds.minY + dy, width: r.width * zoom, height: r.height * zoom)
        }
        return blocks.map { Block(core: at($0.core), lines: $0.lines, head: $0.head.map(at)) }
    }

    /// The stage's read at 1:1 (`h0`).
    private static let stage = LensShapeHeroScenes.all.first { $0.name == "h0" }!

    @Test func stageKindsHoldWhenTheReadIsPlacedAFewPointsOff() {
        for dy in 0...7 {
            for dx in 0...3 {
                for zoom in [CGFloat(1), 0.887831] {
                    // The pointer stays where it was; the stage is read dx, dy off.
                    let blocks = Self.moved(Self.stage.blocks, dx: CGFloat(dx), dy: CGFloat(dy), zoom: zoom)
                    for s in Self.stops(zoom: 1) {
                        let why = Self.problem(blocks, s, gutters: Self.gutters(zoom: 1).map { $0 * zoom + CGFloat(dx) }, pointer: Self.pointer(s, zoom: zoom), want: s.kind)
                        #expect(why == nil, "dx \(dx) dy \(dy) zoom \(zoom) \(why ?? "")")
                    }
                }
            }
        }
    }

    /// Every edge of every block off by up to `amount` points, in a fixed pseudo-random sequence: what Vision does between two reads of one picture.
    private static func jittered(_ blocks: [Block], amount: CGFloat, seed: UInt64) -> [Block] {
        var rng = LensShapeTests.LCG(s: seed)
        func off() -> CGFloat { (rng.next() * 2 - 1) * amount }
        return blocks.map { b in
            let x = off(), y = off(), w = off(), h = off()
            let core = CGRect(x: b.core.minX + x, y: b.core.minY + y, width: b.core.width + w, height: b.core.height + h)
            return Block(core: core, lines: b.lines, head: b.head.map { CGRect(x: $0.minX + x, y: $0.minY + y, width: $0.width, height: $0.height) })
        }
    }

    /// Every read of the stage, each edge of each block a point off in 32 ways: the same kinds in the same panels.
    @Test func stageKindsHoldWhenEveryEdgeOfTheReadMovesAPoint() {
        for read in LensShapeHeroScenes.all {
            for seed in 1...32 {
                let blocks = Self.jittered(read.blocks, amount: 1, seed: UInt64(seed))
                for s in Self.stops(zoom: read.zoom) {
                    let lost = Self.readLostText[read.name]?.contains(s.name) == true
                    let why = Self.problem(blocks, s, gutters: Self.gutters(zoom: read.zoom), pointer: Self.pointer(s, zoom: read.zoom, dy: read.dy), want: lost ? nil : s.kind)
                    #expect(why == nil, "\(read.name) seed \(seed) \(why ?? "")")
                }
            }
        }
    }

    // MARK: - A name merged into its lines

    /// The dialog box of `h0` with its name joined to the first line of its body: one block of one line more, its first line the name's.
    private static func merged(_ blocks: [Block]) -> [Block] {
        let p = pointer(stops(zoom: 1)[4], zoom: 1)
        let body = blocks.first { $0.core.contains(p) }!
        let name = blocks.first { $0.lines == 1 && $0.core.maxY <= body.core.minY + 1 && body.core.minY - $0.core.maxY < 20 && $0.core.width < 60 && abs($0.core.minX - body.core.minX) < 12 }!
        let one = Block(core: name.core.union(body.core), lines: body.lines + 1, head: name.core)
        return blocks.filter { $0 != name && $0 != body } + [one]
    }

    @Test func nameMergedIntoItsLinesStillReadsAsADialog() throws {
        let blocks = Self.merged(Self.stage.blocks)
        let p = Self.pointer(Self.stops(zoom: 1)[4], zoom: 1)
        let whole = try #require(LensShape.choose(blocks: Self.stage.blocks, pointer: p, bounds: Self.bounds))
        let one = try #require(LensShape.choose(blocks: blocks, pointer: p, bounds: Self.bounds))
        #expect(whole.kind == .dialog)
        #expect(one.kind == .dialog, "merged: \(one.kind.rawValue)")
        // The merged block's lines are spread evenly over its box, so the body's height is a half point off the read of the two.
        let (a, b) = (one.rect, whole.rect)
        #expect(abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.maxX - b.maxX) <= 1 && abs(a.maxY - b.maxY) <= 1, "the lens is the same: \(a) and \(b)")
    }

    /// A subtitle of three lines is not a name over two: its first line is as wide as the others, whether or not the read says where it ends.
    @Test func threeLineSubtitleIsNoDialog() {
        let frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let lines = Block(core: CGRect(x: 380, y: 560, width: 520, height: 86), lines: 3)
        #expect(LensShape.choose(blocks: [lines], pointer: CGPoint(x: 640, y: 600), bounds: frame)?.kind == .subtitles)
        let wide = Block(core: lines.core, lines: 3, head: CGRect(x: 380, y: 560, width: 520, height: 22))
        #expect(LensShape.choose(blocks: [wide], pointer: CGPoint(x: 640, y: 600), bounds: frame)?.kind == .subtitles)
    }

    // MARK: - The rules one by one

    /// A table of three lanes in a window, and a column of cells beside it in another window (outside `bounds`) on the same rows: the lens is
    /// the window's table, not a table across both.
    @Test func contentIsWhatLiesInTheWindow() throws {
        func cell(_ x: CGFloat, _ r: Int, _ w: CGFloat) -> Block { Block(core: CGRect(x: x, y: 100 + CGFloat(r) * 30, width: w, height: 16), lines: 1) }
        let table = (0..<5).flatMap { r in [cell(300, r, 80), cell(450, r, 60), cell(580, r, 60)] }
        let elsewhere = (0..<5).map { cell(40, $0, 80) }
        let window = CGRect(x: 200, y: 0, width: 600, height: 600)
        let s = try #require(LensShape.choose(blocks: table + elsewhere, pointer: CGPoint(x: 330, y: 108), bounds: window))
        #expect(s.kind == .table)
        #expect(s.rect == table.map(\.core).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -LensShape.pad, dy: -LensShape.pad), "\(s.rect)")
        // The held anchor and the answer's are the read's own indices, whatever stands outside.
        let map = LensShape.Map(blocks: table + elsewhere)
        let again = try #require(LensShape.choose(map, pointer: CGPoint(x: 332, y: 110), bounds: window, held: s))
        #expect(again == s)
        #expect(map.blocks[s.anchor].core.minX >= window.minX, "the anchor indexes the read's map: \(map.blocks[s.anchor].core)")
    }

    /// A dialog box and, in another column, a block that ends just above the body's top: the name is the block that pairs, not the nearest above.
    @Test func dialogNameIsTheNearestBlockThatPairsNotTheNearest() throws {
        let screen = CGRect(x: 0, y: 0, width: 1280, height: 720)
        func text(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, em: CGFloat, lines: Int = 1) -> Block {
            Block(core: CGRect(x: x, y: y, width: w, height: em * (1 + LensShape.leading * CGFloat(lines - 1))), lines: lines)
        }
        let name = text(100, 520, 60, em: 20), body = text(100, 548, 700, em: 20, lines: 2)
        let plain = try #require(LensShape.choose(blocks: [name, body], pointer: CGPoint(x: 400, y: 560), bounds: screen))
        let beside = text(900, 537, 150, em: 14)   // ends at 551: lower than the name (540), still above the body's top (548) plus 0.2 em
        let s = try #require(LensShape.choose(blocks: [name, body, beside], pointer: CGPoint(x: 400, y: 560), bounds: screen))
        #expect(plain.kind == .dialog)
        #expect(s.kind == .dialog && s.rect == plain.rect, "\(s.kind.rawValue) \(s.rect)")
    }

    /// Bubbles down a pane and a heading over it, flush with the bubbles of one side: the heading is no message of the thread (a larger set of type),
    /// and the bubbles stay a thread.
    @Test func headingOverAChatIsNoMessageOfIt() throws {
        let pane = CGRect(x: 0, y: 0, width: 400, height: 700)
        let bubbles: [Block] = [
            Block(core: CGRect(x: 20, y: 60, width: 200, height: 14), lines: 1), Block(core: CGRect(x: 180, y: 90, width: 200, height: 32.9), lines: 2),
            Block(core: CGRect(x: 20, y: 140, width: 240, height: 32.9), lines: 2), Block(core: CGRect(x: 220, y: 190, width: 160, height: 14), lines: 1),
            Block(core: CGRect(x: 20, y: 220, width: 180, height: 14), lines: 1),
        ]
        let heading = Block(core: CGRect(x: 20, y: 10, width: 150, height: 30), lines: 1)
        #expect(LensShape.choose(blocks: bubbles + [heading], pointer: CGPoint(x: 60, y: 25), bounds: pane)?.kind != .thread, "the heading")
        let s = try #require(LensShape.choose(blocks: bubbles + [heading], pointer: CGPoint(x: 300, y: 105), bounds: pane))
        #expect(s.kind == .thread)
        #expect(s.rect == bubbles.map(\.core).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -LensShape.pad, dy: -LensShape.pad), "\(s.rect)")
    }

    // MARK: - Why a kind was chosen

    @Test func explainNamesTheKindAndWhatCameBeforeIt() throws {
        let stage = Self.stage
        let p = Self.pointer(Self.stops(zoom: 1)[4], zoom: 1)
        let map = LensShape.Map(blocks: stage.blocks)
        let lines = LensShape.explain(map, pointer: p, bounds: Self.bounds)
        let chosen = try #require(LensShape.choose(map, pointer: p, bounds: Self.bounds))
        #expect(lines.first?.hasPrefix("blocks \(map.within(Self.bounds).blocks.count) of \(map.blocks.count)") == true, "\(lines)")
        #expect(lines.contains { $0.contains("table: nothing recognised") && $0.hasPrefix("  ") }, "\(lines)")
        #expect(lines.last?.contains("\(chosen.kind.rawValue): ") == true && lines.last?.hasSuffix("chosen") == true, "\(lines)")
        #expect(LensShape.explain(map, pointer: CGPoint(x: 1490, y: 650), bounds: Self.bounds).last?.contains("no block") == true)
    }
}

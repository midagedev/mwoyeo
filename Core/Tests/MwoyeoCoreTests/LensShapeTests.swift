import CoreGraphics
import Testing
@testable import MwoyeoCore

/// The one-click lens's shapes (docs/design/lens-shapes.md, round shapes117): one synthetic layout per kind, the rules that keep a page
/// from passing for a game or a video, the hold, and the bench reads and the stage (`LensShapeScenes`) held to no cut, no flicker and their
/// kinds. FAIL-first: tools/first-lens/shapes/mutants.sh runs this file against a stub and named mutants.
@Suite struct LensShapeTests {
    typealias Block = LensShape.Block

    /// A block of `lines` lines `em` tall, as the read gives it (the lines' union).
    private func text(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, em: CGFloat, lines: Int = 1) -> Block {
        Block(core: CGRect(x: x, y: y, width: w, height: em * (1 + LensShape.leading * CGFloat(lines - 1))), lines: lines)
    }

    private func union(_ blocks: [Block]) -> CGRect { blocks.map(\.core).reduce(CGRect.null) { $0.union($1) } }

    /// Every block either inside `rect` (with the cut slack) or clear of it.
    private func assertWhole(_ rect: CGRect, _ blocks: [Block], _ what: String) {
        for b in blocks where LensShape.cuts(rect, b.core) { Issue.record("\(what): \(rect) cuts \(b.core)") }
    }

    // MARK: - One layout per kind

    /// A titled table: five rows of four one-line cells (a name lane and three number lanes).
    private let table: [Block] = {
        var b = [Block(core: CGRect(x: 100, y: 80, width: 200, height: 16), lines: 1)]
        for r in 0..<5 {
            let y = 110 + CGFloat(r) * 28
            b += [CGRect(x: 100, y: y, width: 120, height: 16), CGRect(x: 300, y: y, width: 60, height: 16),
                  CGRect(x: 420, y: y, width: 60, height: 16), CGRect(x: 540, y: y, width: 60, height: 16)].map { Block(core: $0, lines: 1) }
        }
        return b
    }()
    private let page = CGRect(x: 0, y: 0, width: 800, height: 600)

    @Test func kindsAreTriedInOrder() {
        #expect(LensShape.Kind.allCases == [.table, .thread, .dialog, .subtitles, .group])
    }

    @Test func tableTakesEveryRowAndLaneWithItsTitle() throws {
        for p in [CGPoint(x: 450, y: 175), CGPoint(x: 150, y: 88), CGPoint(x: 330, y: 230)] {
            let s = try #require(LensShape.choose(blocks: table, pointer: p, bounds: page), "\(p)")
            #expect(s.kind == .table, "\(p)")
            #expect(s.rect == union(table).insetBy(dx: -LensShape.pad, dy: -LensShape.pad), "\(p)")
        }
    }

    /// A label and its value on two lines (a form's two fields) are not a table: three rows at least.
    @Test func twoRowsOfCellsAreNoTable() {
        let form = [text(100, 100, 80, em: 16), text(300, 100, 100, em: 16), text(100, 130, 80, em: 16), text(300, 130, 100, em: 16)]
        for p in [CGPoint(x: 140, y: 108), CGPoint(x: 350, y: 138)] {
            #expect(LensShape.choose(blocks: form, pointer: p, bounds: page)?.kind != .table, "\(p)")
        }
    }

    /// Bubbles: three from the left edge, two to the right edge, one or two lines each.
    private let bubbles: [Block] = [
        Block(core: CGRect(x: 20, y: 40, width: 200, height: 14), lines: 1),
        Block(core: CGRect(x: 180, y: 70, width: 200, height: 32.9), lines: 2),
        Block(core: CGRect(x: 20, y: 120, width: 240, height: 32.9), lines: 2),
        Block(core: CGRect(x: 220, y: 170, width: 160, height: 14), lines: 1),
        Block(core: CGRect(x: 20, y: 200, width: 180, height: 14), lines: 1),
    ]

    @Test func threadTakesTheWholePaneOfBubbles() throws {
        let pane = CGRect(x: 0, y: 0, width: 400, height: 700)
        for p in [CGPoint(x: 300, y: 85), CGPoint(x: 60, y: 47)] {
            let s = try #require(LensShape.choose(blocks: bubbles, pointer: p, bounds: pane), "\(p)")
            #expect(s.kind == .thread, "\(p)")
            #expect(s.rect == union(bubbles).insetBy(dx: -LensShape.pad, dy: -LensShape.pad), "\(p)")
        }
    }

    @Test func dialogLeavesRoomForTheLineBeingTyped() throws {
        let screen = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let name = text(100, 520, 60, em: 20), body = text(100, 548, 700, em: 20, lines: 2)
        let s = try #require(LensShape.choose(blocks: [name, body], pointer: CGPoint(x: 400, y: 560), bounds: screen))
        #expect(s.kind == .dialog)
        // The name and the body, the body's lines widened to 28 ems from its left edge, three lines tall.
        let bottom: CGFloat = 548 + 20 * (1 + 2 * 1.35) + 6
        #expect(s.rect == CGRect(x: 94, y: 514, width: 806 - 94, height: bottom - 514))
        // The same from the name.
        #expect(LensShape.choose(blocks: [name, body], pointer: CGPoint(x: 120, y: 530), bounds: screen)?.rect == s.rect)
    }

    @Test func subtitleBandIsCentredOnTheLineAndTwoLinesTall() throws {
        let frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let line = text(440, 620, 400, em: 32)
        let s = try #require(LensShape.choose(blocks: [line], pointer: CGPoint(x: 640, y: 636), bounds: frame))
        #expect(s.kind == .subtitles)
        #expect(abs(s.rect.midX - line.core.midX) <= 0.5)
        #expect(abs(s.rect.width - 18 * 32) <= 1, "at least 18 ems wide")
        #expect(abs(s.rect.maxY - (line.core.maxY + LensShape.pad)) <= 0.5)
        #expect(abs(s.rect.height - (32 * (1 + 1.35) + 2 * LensShape.pad)) <= 0.5, "room for a second line above")
    }

    /// A list under its title.
    private let list: [Block] = [CGRect(x: 40, y: 40, width: 120, height: 14)].map { Block(core: $0, lines: 1) }
        + (0..<4).map { Block(core: CGRect(x: 56, y: 62 + CGFloat($0) * 22, width: 300, height: 14), lines: 1) }

    @Test func listIsOneGroupWithItsTitle() throws {
        let s = try #require(LensShape.choose(blocks: list, pointer: CGPoint(x: 200, y: 106), bounds: page))
        #expect(s.kind == .group)
        #expect(s.rect == union(list).insetBy(dx: -LensShape.pad, dy: -LensShape.pad))
    }

    @Test func nothingRecognisableKeepsTheGhost() {
        #expect(LensShape.choose(blocks: list, pointer: CGPoint(x: 600, y: 400), bounds: page) == nil, "empty space")
        #expect(LensShape.choose(blocks: [text(300, 300, 80, em: 14)], pointer: CGPoint(x: 340, y: 307), bounds: page) == nil, "a lone label")
        #expect(LensShape.choose(blocks: [], pointer: CGPoint(x: 340, y: 307), bounds: page) == nil)
    }

    // MARK: - A page is not a game or a video

    /// A doc's heading over a one-line paragraph, a paragraph's space apart (k01 "Usage": 1.2 ems): a group, not a speaker's name.
    @Test func headingOverAParagraphIsNoDialog() throws {
        let screen = CGRect(x: 0, y: 0, width: 860, height: 720)
        let heading = text(34.6, 365.9, 66.8, em: 20.1), paragraph = text(33.7, 408.8, 580.1, em: 19)
        let s = try #require(LensShape.choose(blocks: [heading, paragraph], pointer: CGPoint(x: 300, y: 418), bounds: screen))
        #expect(s.kind == .group)
    }

    /// A page's lone line in the lower half, a paragraph's space from the next (k03: 1.1 ems): not a subtitle. A subtitle with a player's
    /// small print right under it still is one (s06).
    @Test func loneLineOfAPageIsNoSubtitle() throws {
        let screen = CGRect(x: 0, y: 0, width: 900, height: 560)
        let line = text(26.2, 261.4, 341.2, em: 22.4), next = text(45.8, 308.8, 136.1, em: 20.9)
        #expect(LensShape.choose(blocks: [line, next], pointer: CGPoint(x: 200, y: 272), bounds: screen)?.kind != .subtitles)
        let frame = CGRect(x: 0, y: 0, width: 960, height: 540)
        let subtitle = text(170, 400, 620, em: 36, lines: 2), controls = text(20, 506, 160, em: 14)
        #expect(LensShape.choose(blocks: [subtitle, controls], pointer: CGPoint(x: 480, y: 430), bounds: frame)?.kind == .subtitles)
    }

    // MARK: - The hold

    /// The deterministic jitter of the gates (no Foundation randomness).
    struct LCG {
        var s: UInt64
        mutating func next() -> CGFloat { s = s &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(s >> 11) / CGFloat(1 << 53) }
    }

    private func key(_ s: LensShape.Shape?) -> String { s.map { "\($0.kind) \($0.rect)" } ?? "ghost" }

    /// Walks the pointer along rows and columns every `spacing` points in `step`s, holding the choice; at each change, `samples`
    /// positions within 2 points of it are chosen in turn (held, or not), and every A -> B -> A counts.
    private func reversals(_ map: LensShape.Map, _ bounds: CGRect, spacing: CGFloat, step: CGFloat, samples: Int, hold: Bool) -> (changes: Int, reversals: Int, at: String?) {
        var rng = LCG(s: 1), changes = 0, count = 0, at: String?
        for vertical in [false, true] {
            var line = spacing / 2
            while line < (vertical ? bounds.width : bounds.height) {
                var held: LensShape.Shape?, last = "ghost", along: CGFloat = 0
                while along < (vertical ? bounds.height : bounds.width) {
                    let p = vertical ? CGPoint(x: line, y: along) : CGPoint(x: along, y: line)
                    let s = LensShape.choose(map, pointer: p, bounds: bounds, held: held)
                    if key(s) != last {
                        changes += 1
                        var h = held, seq: [String] = []
                        for _ in 0..<samples {
                            let q = CGPoint(x: p.x + rng.next() * 4 - 2, y: p.y + rng.next() * 4 - 2)
                            let r = LensShape.choose(map, pointer: q, bounds: bounds, held: hold ? h : nil)
                            seq.append(key(r)); h = r
                        }
                        let rev = (2..<seq.count).filter { seq[$0] == seq[$0 - 2] && seq[$0] != seq[$0 - 1] }
                        count += rev.count
                        if at == nil, let i = rev.first { at = "\(p): \(seq[i - 1]) <-> \(seq[i])" }
                    }
                    held = s; last = key(s)
                    along += step
                }
                line += spacing
            }
        }
        return (changes, count, at)
    }

    /// Two lists a gutter apart and a lone label beside them: the pointer crossing the gutter or the edges switches once.
    @Test func heldShapeDoesNotFlickerUnderJitter() {
        let other = list.map { Block(core: $0.core.offsetBy(dx: 360, dy: 0), lines: $0.lines) }
        let map = LensShape.Map(blocks: list + other + [text(300, 220, 60, em: 14)])
        let held = reversals(map, page, spacing: 16, step: 2, samples: 40, hold: true)
        let loose = reversals(map, page, spacing: 16, step: 2, samples: 40, hold: false)
        #expect(held.changes > 40)
        #expect(held.reversals == 0, "\(held.at ?? "")")
        #expect(loose.reversals > 0, "the jitter must reach the edges (the measure's teeth)")
    }

    @Test func shapeIsTakenWithinReachAndLetGoSwitchByBeyond() throws {
        let map = LensShape.Map(blocks: list)
        let bottom = union(list).maxY
        // From afar: nothing until the pointer is within `reach` of a block.
        #expect(LensShape.choose(map, pointer: CGPoint(x: 200, y: bottom + 41), bounds: page) == nil)
        let s = try #require(LensShape.choose(map, pointer: CGPoint(x: 200, y: bottom + 39), bounds: page))
        // Held: kept to `reach + switchBy`, then let go.
        #expect(LensShape.choose(map, pointer: CGPoint(x: 200, y: bottom + 47), bounds: page, held: s) == s)
        #expect(LensShape.choose(map, pointer: CGPoint(x: 200, y: bottom + 49), bounds: page, held: s) == nil)
        // Held from any of its blocks: the title, farthest from where it was taken, still holds it.
        #expect(LensShape.choose(map, pointer: CGPoint(x: 100, y: 40 - 45), bounds: page, held: s)?.rect == s.rect)
    }

    @Test func loneLabelDoesNotTakeTheLensFromAHeldShape() throws {
        let label = text(400, 70, 50, em: 14)
        let map = LensShape.Map(blocks: list + [label])
        let s = try #require(LensShape.choose(map, pointer: CGPoint(x: 200, y: 70), bounds: page))
        let over = CGPoint(x: 402, y: 77) // on the label: 46 points from the list's items, beyond `reach` and within `reach + switchBy`
        #expect(LensShape.choose(map, pointer: over, bounds: page) == nil, "the label alone is nothing")
        #expect(LensShape.choose(map, pointer: over, bounds: page, held: s) == s, "it does not beat the held list")
    }

    @Test func shapeDependsOnTheBlockNotThePointer() {
        let a = LensShape.choose(blocks: table, pointer: CGPoint(x: 305, y: 140), bounds: page)
        let b = LensShape.choose(blocks: table, pointer: CGPoint(x: 355, y: 150), bounds: page)
        #expect(a != nil)
        #expect(a == b)
    }

    // MARK: - The bench reads and the stage

    /// Every scene chosen at every `gridStep` points, once for the tests below.
    private static let gridStep: CGFloat = 20
    private static let chosen: [(scene: LensShapeScenes.Scene, shapes: [(point: CGPoint, shape: LensShape.Shape?)])] = LensShapeScenes.all.map { scene in
        let map = LensShape.Map(blocks: scene.blocks), bounds = CGRect(origin: .zero, size: scene.size)
        var out: [(point: CGPoint, shape: LensShape.Shape?)] = []
        var y = gridStep / 2
        while y < bounds.height {
            var x = gridStep / 2
            while x < bounds.width {
                let p = CGPoint(x: x, y: y)
                out.append((p, LensShape.choose(map, pointer: p, bounds: bounds)))
                x += gridStep
            }
            y += gridStep
        }
        return (scene, out)
    }

    @Test func scenesNeverCutABlockAndStayInBounds() {
        var shapes = 0
        for (scene, grid) in Self.chosen {
            let bounds = CGRect(origin: .zero, size: scene.size)
            for case let (p, s?) in grid {
                shapes += 1
                assertWhole(s.rect, scene.blocks, "\(scene.name) at \(p)")
                #expect(bounds.contains(s.rect), "\(scene.name) at \(p): \(s.rect)")
                #expect(s.rect.width >= LensShape.minSize.width - 0.5, "\(scene.name) at \(p)")
                #expect(s.rect.height >= LensShape.minSize.height - 0.5, "\(scene.name) at \(p)")
            }
        }
        #expect(shapes > 5000)
    }

    @Test func scenesDoNotFlickerUnderJitter() {
        var changes = 0, loose = 0
        for scene in LensShapeScenes.all {
            let map = LensShape.Map(blocks: scene.blocks), bounds = CGRect(origin: .zero, size: scene.size)
            let held = reversals(map, bounds, spacing: 200, step: 6, samples: 12, hold: true)
            #expect(held.reversals == 0, "\(scene.name) \(held.at ?? "")")
            changes += held.changes
            // The control, on the scenes with the most shapes: without the hold the same walk flickers.
            if scene.blocks.count >= 15 { loose += reversals(map, bounds, spacing: 200, step: 6, samples: 12, hold: false).reversals }
        }
        #expect(changes > 150)
        #expect(loose > 0, "without the hold the same walk flickers (the measure's teeth)")
    }

    /// What each scene's reads are recognised as, over a 20 pt grid: the kinds it must claim somewhere, and the kinds it must not claim
    /// anywhere (the false claims the review found and closed; the open ones are listed in docs/design/lens-shapes.md, not here).
    @Test func scenesClaimTheirKinds() {
        let must: [String: Set<LensShape.Kind>] = [
            "c01-slack-en": [.thread], "c02-kakao-ko": [.thread], "c03-line-mixed": [.thread],
            "d01-spec-table-en": [.table], "d02-timetable-ja": [.table], "d05-settings-ja": [.table], "g03-rpg-inventory-ja": [.table],
            "g01-vn-dialogue-ja": [.dialog], "g02-vn-dialogue-en": [.dialog],
            "s01-sub-ja-bright-2line": [.subtitles], "s02-sub-en-dark-1line": [.subtitles], "s03-sub-ko-busy-2line": [.subtitles],
            "s04-sub-zh-boxed-2line": [.subtitles], "s05-sub-plus-sign-top": [.subtitles], "s06-player-controls": [.subtitles],
            "s07-karaoke-ja": [.subtitles], "s08-sub-en-busy-outline": [.subtitles], "s09-sub-ko-bright-1line": [.subtitles],
            "d04-lists-ko": [.group], "g04-item-popup-en": [.group], "g06-tutorial-popup-en": [.group],
            "stage": [.table, .thread, .dialog, .subtitles, .group],
        ]
        let page: Set<LensShape.Kind> = [.dialog, .subtitles]
        let mustNot: [String: Set<LensShape.Kind>] = [
            "k01-readme-en": page, "k02-readme-ko": page, "k03-stackoverflow-ja": page, "k04-stackoverflow-en": page,
            "k08-algorithm-zh": page, "k09-git-release-en": page, "k10-shortcuts-ko": page, "k11-traceback-ja": page, "k12-docker-zh": page,
            "d05-settings-ja": [.subtitles, .dialog], "g06-tutorial-popup-en": [.subtitles], "s06-player-controls": [.dialog, .thread, .table],
            "p01-paper-en-2col": [.thread, .dialog, .subtitles], "p03-paper-references": [.thread, .dialog, .subtitles, .table],
            "p05-paper-ja": [.thread, .dialog, .subtitles], "p06-paper-zh": [.thread, .dialog, .subtitles], "p07-paper-ko": [.thread, .dialog, .subtitles],
            "c02-kakao-ko": [.dialog, .subtitles, .table], "c03-line-mixed": [.dialog, .subtitles, .table],
            "g01-vn-dialogue-ja": [.subtitles, .thread], "g02-vn-dialogue-en": [.subtitles, .thread],
        ]
        for (scene, grid) in Self.chosen {
            let kinds = Set(grid.compactMap { $0.shape?.kind })
            for k in must[scene.name, default: []] where !kinds.contains(k) { Issue.record("\(scene.name) never claims \(k): \(kinds)") }
            for k in mustNot[scene.name, default: []] where kinds.contains(k) { Issue.record("\(scene.name) claims \(k)") }
        }
    }

    /// The stage's planned stops (tools/first-lens/stage/path.json): each its kind, and the rect a click there places.
    @Test func stageStopsPlaceTheirShapes() throws {
        let stage = try #require(LensShapeScenes.all.first { $0.name == "stage" })
        let map = LensShape.Map(blocks: stage.blocks), bounds = CGRect(origin: .zero, size: stage.size)
        let stops: [(CGPoint, LensShape.Kind, CGRect)] = [
            (CGPoint(x: 240, y: 64), .group, CGRect(x: 36, y: 42.5, width: 467.5 - 36, height: 153.5 - 42.5)),
            (CGPoint(x: 770, y: 176), .thread, CGRect(x: 653, y: 42.5, width: 942.5 - 653, height: 329.5 - 42.5)),
            (CGPoint(x: 1236, y: 140), .table, CGRect(x: 995.5, y: 31.5, width: 1467.5 - 995.5, height: 217 - 31.5)),
            (CGPoint(x: 1240, y: 492), .subtitles, CGRect(x: 1030.5, y: 458, width: 1448.5 - 1030.5, height: 525 - 458)),
            (CGPoint(x: 1180, y: 850), .dialog, CGRect(x: 1016, y: 796, width: 1399.5 - 1016, height: 907 - 796)),
        ]
        for (p, kind, rect) in stops {
            let s = try #require(LensShape.choose(map, pointer: p, bounds: bounds), "\(p)")
            #expect(s.kind == kind, "\(p)")
            #expect(s.rect == rect, "\(p)")
        }
    }

    /// The read's block order does not matter.
    @Test func orderOfTheReadDoesNotMatter() {
        for scene in LensShapeScenes.all where scene.blocks.count > 2 {
            let a = LensShape.Map(blocks: scene.blocks), b = LensShape.Map(blocks: Array(scene.blocks.reversed()))
            let bounds = CGRect(origin: .zero, size: scene.size)
            for block in scene.blocks {
                let p = CGPoint(x: block.core.midX, y: block.core.midY)
                let x = LensShape.choose(a, pointer: p, bounds: bounds), y = LensShape.choose(b, pointer: p, bounds: bounds)
                #expect(x?.kind == y?.kind, "\(scene.name) at \(p)")
                #expect(x?.rect == y?.rect, "\(scene.name) at \(p)")
            }
        }
    }
}

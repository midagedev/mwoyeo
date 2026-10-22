import CoreGraphics
import Foundation
import Testing
@testable import MwoyeoCore

/// The film4 take t1-hero (page 6 of the Mwoyeo method paper in Preview at 100 %, a 1512 x 982 display, the window at [0, 33, 1512, 858]), in points
/// with y down. The take's numbers (app.err, main 7c58403): `picker: map n=23 columns=2 [307..745 96..962] [769..1206 10..891] read=532 ms`, the
/// map arriving 7.449 s after the recording began, and the first target `column=0 anchor=1 rect=301,96 449x318`; the pointer travelled
/// (299, 357.5) -> (520, 372) -> (748, 330) -> (986, 330) -> (560, 600) -> (986, 330) from 6.971 s on. The page's left edge stands at x = 214
/// (the video), the columns' edges are the take's; the blocks are synthetic, made to give the take's first target and the second column's.
private enum FilmTake {
    static let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static let window = CGRect(x: 0, y: 33, width: 1512, height: 858)
    static let pageLeft: CGFloat = 214
    static let left: (CGFloat, CGFloat) = (307.25, 744.75), right: (CGFloat, CGFloat) = (769.25, 1205.75)
    static let path: [(CGPoint, CGPoint)] = [
        (CGPoint(x: 299, y: 357.5), CGPoint(x: 520, y: 372)), (CGPoint(x: 520, y: 372), CGPoint(x: 748, y: 330)),
        (CGPoint(x: 748, y: 330), CGPoint(x: 986, y: 330)), (CGPoint(x: 986, y: 330), CGPoint(x: 560, y: 600)),
        (CGPoint(x: 560, y: 600), CGPoint(x: 986, y: 330)),
    ]
    /// The take's pointer at the moment the map arrived (the end of the first leg, within a few points).
    static let atMap = CGPoint(x: 515, y: 371)

    private static func block(_ x: (CGFloat, CGFloat), _ y0: CGFloat, _ y1: CGFloat, lines: Int) -> ColumnFit.Block {
        ColumnFit.Block(core: CGRect(x: x.0, y: y0, width: x.1 - x.0, height: y1 - y0), lines: lines)
    }

    static var blocks: [ColumnFit.Block] {
        [block(left, 96, 236, lines: 7), block(left, 262, 414, lines: 8), block(left, 470, 765, lines: 14), block(left, 790, 887, lines: 5),
         block(right, 150, 210, lines: 4), block(right, 252, 400, lines: 7), block(right, 419, 500, lines: 3), block(right, 515, 640, lines: 6),
         block(right, 665, 687, lines: 1)]
    }

    static var content: CGRect { LensTarget.content(of: window, on: display) }
}

/// 2026-10-23 picktarget117: a target stays on the page it was built from, and the default lens does not show while the read is young.
@Suite struct LensTargetPreviewTests {
    // MARK: What the take's targets are

    @Test func theTakesFirstTargetIsTheTracedRectAndInsideItsColumn() throws {
        let map = LensTarget.Map(blocks: FilmTake.blocks)
        #expect(map.readingColumns == 2)
        let t = try #require(LensTarget.choose(map, pointer: FilmTake.atMap, bounds: FilmTake.content))
        #expect(t.column == 0)
        // `picker: target column=0 anchor=1 rect=301,96 449x318`
        #expect(abs(t.rect.minX - 301) <= 1 && abs(t.rect.minY - 96) <= 1 && abs(t.rect.width - 449) <= 1 && abs(t.rect.height - 318) <= 1, "\(t.rect)")
        let second = try #require(LensTarget.choose(map, pointer: CGPoint(x: 986, y: 330), bounds: FilmTake.content))
        // `picker: target column=1 anchor=2 rect=763,252 449x435`
        #expect(abs(second.rect.minX - 763) <= 1 && abs(second.rect.minY - 252) <= 1 && abs(second.rect.width - 449) <= 1 && abs(second.rect.height - 435) <= 1, "\(second.rect)")
    }

    @Test func noTargetOnTheTakesPathLeavesItsColumnOrThePage() {
        let map = LensTarget.Map(blocks: FilmTake.blocks)
        var seen = 0
        for (a, b) in FilmTake.path {
            let n = Int(max(abs(b.x - a.x), abs(b.y - a.y)) / 2)
            var held: LensTarget.Target?
            for i in 0...n {
                let f = CGFloat(i) / CGFloat(max(n, 1))
                let p = CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
                held = LensTarget.choose(map, pointer: p, held: held, bounds: FilmTake.content)
                guard let t = held else { continue }
                seen += 1
                let c = map.columns[t.column]
                #expect(t.rect.minX >= c.left - ColumnFit.pad - 0.5 && t.rect.maxX <= c.right + ColumnFit.pad + 0.5, "\(t.rect) for \(c.left)..\(c.right) at \(p)")
                #expect(t.rect.minX >= FilmTake.pageLeft, "\(t.rect) leaves the page at \(p)")
                #expect(FilmTake.content.contains(t.rect), "\(t.rect) leaves the window's content at \(p)")
            }
        }
        #expect(seen > 100)
    }

    /// The cause the film showed: what spilled was the default lens, which knows the window, not the page.
    @Test func theDefaultLensAtTheTakesPointerIsTheOneThatLeavesThePage() {
        // The picker view is AppKit (y up): the display's height less the take's y.
        let p = CGPoint(x: 299, y: FilmTake.display.height - 357.5)
        let window = CGRect(x: 0, y: FilmTake.display.height - (33 + 858), width: 1512, height: 858)
        let ghost = LensTarget.ghost(at: p, window: window, in: FilmTake.display)
        #expect(ghost.minX == 19 && ghost.width == 560)
        #expect(FilmTake.pageLeft - ghost.minX > 150, "the ghost stands \(FilmTake.pageLeft - ghost.minX) pt over the margin")
    }

    @Test func theDefaultLensIsKeptInsideTheWindowsContentBelowItsTitleBar() {
        // AppKit, y up: a 858 pt window whose top strip (y from 830) is the title bar; the pointer at the top of it, and at the window's left edge.
        let window = CGRect(x: 100, y: 100, width: 900, height: 858)
        let ghost = LensTarget.ghost(at: CGPoint(x: 100, y: 950), window: window, in: FilmTake.display)
        #expect(ghost.maxY <= window.maxY - LensTarget.titleBar && ghost.minX >= window.minX && ghost.maxX <= window.maxX, "\(ghost)")
        // A strip of a window (120 pt or less) has no title bar to keep clear of.
        let strip = CGRect(x: 100, y: 100, width: 900, height: 100)
        #expect(LensTarget.ghost(at: CGPoint(x: 500, y: 195), window: strip, in: FilmTake.display).maxY == strip.maxY)
    }

    // MARK: What shows while the read goes

    @Test func theTakesReadShowsNoDefaultLensAndTheTargetAppearsWhereItStands() {
        // The read began at 6.917 s and ended at 7.449 s (532 ms): at every frame of a 120 Hz take between them, nothing.
        let began: TimeInterval = 6.917
        var t = began
        while t < 7.449 {
            let p = LensTarget.preview(.reading(since: began), aimed: false, now: t)
            #expect(p.shown == .nothing, "at \(t) s: \(p)")
            t += 1.0 / 120
        }
        #expect(LensTarget.preview(.ready, aimed: true, now: 7.449).shown == .target)
        // A glide that was cleared while nothing showed has nowhere to come from: the first target is at its rect at once, no morph.
        var glide = LensTarget.Glide()
        glide.clear()
        let first = CGRect(x: 301, y: 96, width: 449, height: 318)
        glide.move(to: first, at: 7.449, .glide)
        let moving = glide.moving(at: 7.449)
        #expect(glide.rect(at: 7.449) == first && !moving)
    }

    @Test func theDefaultLensComesOnceTheReadHasTakenItsGraceOrGaveNothing() {
        let g = LensTarget.ghostGrace
        #expect(g > 0.61 && g < 1.5, "a grace between the slowest ordinary read (0.61 s) and a wait the person feels")
        // Young read: nothing, and the picker is told when to look again.
        let young = LensTarget.preview(.reading(since: 10), aimed: false, now: 10.25)
        #expect(young.shown == .nothing && abs((young.recheckIn ?? -1) - (g - 0.25)) < 1e-9, "\(young)")
        // At the grace and after: the default lens, nothing left to wait for.
        for age in [g, g + 0.001, 2.5, 4.0] {
            let old = LensTarget.preview(.reading(since: 10), aimed: false, now: 10 + age)
            #expect(old == LensTarget.Preview(shown: .ghost, recheckIn: nil), "age \(age): \(old)")
        }
        // The read gave nothing, or there is no reader: today's default lens at once.
        #expect(LensTarget.preview(.empty, aimed: false, now: 3) == LensTarget.Preview(shown: .ghost))
        #expect(LensTarget.preview(.unread, aimed: false, now: 3) == LensTarget.Preview(shown: .ghost))
        // A map without a column under the pointer (a figure, a margin): the default lens, as in 4.1.5.
        #expect(LensTarget.preview(.ready, aimed: false, now: 3) == LensTarget.Preview(shown: .ghost))
        // A target is a target in every phase; a closed picker shows nothing.
        #expect(LensTarget.preview(.ready, aimed: true, now: 3) == LensTarget.Preview(shown: .target))
        #expect(LensTarget.preview(.closed, aimed: false, now: 3).shown == .nothing)
    }

    @Test func aGraceOfZeroIsTodaysBehaviourForTheChecksThatInjectIt() {
        #expect(LensTarget.preview(.reading(since: 5), aimed: false, now: 5, grace: 0) == LensTarget.Preview(shown: .ghost))
        #expect(LensTarget.preview(.reading(since: 5), aimed: false, now: 5.4, grace: 0.5).shown == .nothing)
    }
}

/// 2026-10-23 picktarget117, A1: the first outline does not pop; it opens from the pointer on the glide's spring and stays inside its target.
@Suite struct LensTargetEntranceTests {
    private let first = CGRect(x: 301, y: 96, width: 449, height: 318)
    private let pointer = CGPoint(x: 515, y: 371)

    private func opened(_ pointer: CGPoint, _ rect: CGRect, how: LensTarget.Glide.Move = .glide) -> LensTarget.Glide {
        var g = LensTarget.Glide()
        g.appear(from: pointer, to: rect, at: 10, how)
        return g
    }

    @Test func theFirstTargetStartsAsASquareAtThePointerAndEndsOnItsRect() throws {
        var g = opened(pointer, first)
        let r0 = try #require(g.rect(at: 10))
        #expect(r0.width == LensTarget.seedSide && r0.height == LensTarget.seedSide && r0.midX == pointer.x && r0.midY == pointer.y, "\(r0)")
        let movingAtStart = g.moving(at: 10)
        #expect(movingAtStart)
        #expect(g.rect(at: 10 + LensTarget.glide) == first)
        let movingAtEnd = g.moving(at: 10 + LensTarget.glide)
        #expect(!movingAtEnd)
    }

    @Test func itIsNinetyPercentOpenAt130msAndNeverLeavesItsTarget() throws {
        let g = opened(pointer, first)
        let at130 = try #require(g.rect(at: 10.13))
        #expect((at130.width - LensTarget.seedSide) / (first.width - LensTarget.seedSide) >= 0.9, "\(at130)")
        let at20 = try #require(g.rect(at: 10.02))
        #expect((at20.width - LensTarget.seedSide) / (first.width - LensTarget.seedSide) < 0.25, "it is not there yet at 20 ms: \(at20)")
        var last = try #require(g.rect(at: 10))
        var t = 10.0
        while t <= 10.3 {
            let r = try #require(g.rect(at: t))
            #expect(first.insetBy(dx: -1e-9, dy: -1e-9).contains(r), "\(r) at \(t - 10) s leaves \(first)")
            #expect(r.width >= last.width - 1e-9 && r.height >= last.height - 1e-9, "it opens, never closes")
            last = r
            t += 1.0 / 240
        }
    }

    @Test func aPointerInTheGutterStillOpensInsideTheTarget() throws {
        // choose gives the column to a pointer up to `slack` outside its padded edge: the seed is moved inside.
        for x in [first.minX - 11, first.maxX + 11] {
            let g = opened(CGPoint(x: x, y: 371), first)
            let r0 = try #require(g.rect(at: 10))
            #expect(first.contains(r0) && r0.width == LensTarget.seedSide, "\(r0)")
        }
        // A rect smaller than the seed: the seed is the rect.
        let tiny = CGRect(x: 100, y: 100, width: 12, height: 40)
        #expect(opened(CGPoint(x: 106, y: 120), tiny).rect(at: 10)?.width == 12)
    }

    @Test func underReduceMotionItIsThereAtOnce() {
        var g = opened(pointer, first, how: .jump)
        let moving = g.moving(at: 10)
        #expect(g.rect(at: 10) == first && !moving)
    }

    @Test func aChangeOfMindWhileOpeningKeepsTheRectAndAddsItsStep() throws {
        var g = opened(pointer, first)
        let before = try #require(g.rect(at: 10.1))
        let next = CGRect(x: 763, y: 252, width: 449, height: 435)
        g.move(to: next, at: 10.1, .glide)
        let after = try #require(g.rect(at: 10.1))
        #expect(abs(after.minX - before.minX) < 1e-9 && abs(after.width - before.width) < 1e-9, "no jump at the change: \(before) -> \(after)")
        #expect(g.rect(at: 10.1 + LensTarget.glide + 0.3) == next)
    }
}

/// 2026-10-23 picktarget117, A2: the skinland117 take (/tmp/r117/skinland117/play.mp4 3.77 to 4.10 s): Preview's window [0, 33, 1512, 858] (its bottom
/// edge at y 891), the Dock below it (895 to 982), the pointer at (426, 914) over the Dock, and the map's column 0 `[307..749 210..962]`: the page's
/// text and, in the same x range, the Dock's icon labels down to y 962 (the map of that take: `columns=2 [307..749 210..962] [768..1206 254..891]`).
@Suite struct LensTargetBoundsTests {
    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let window = CGRect(x: 0, y: 33, width: 1512, height: 858)
    private let pointer = CGPoint(x: 514, y: 914)

    private var map: LensTarget.Map {
        func b(_ y0: CGFloat, _ y1: CGFloat, lines: Int, x: (CGFloat, CGFloat) = (307.25, 748.75)) -> ColumnFit.Block {
            ColumnFit.Block(core: CGRect(x: x.0, y: y0, width: x.1 - x.0, height: y1 - y0), lines: lines)
        }
        return LensTarget.Map(blocks: [b(210, 380, lines: 8), b(400, 590, lines: 9), b(613, 760, lines: 7), b(780, 891, lines: 5),
                                       b(900, 925, lines: 1, x: (497, 530)), b(935, 962, lines: 1, x: (560, 600))])
    }

    @Test func overTheDockTodaysClampLetsTheTargetReachOverIt() throws {
        // What the picker did: the pointer over no window, the display the clamp.
        let old = try #require(LensTarget.choose(map, pointer: pointer, bounds: LensTarget.content(of: nil, on: display)))
        #expect(old.rect.maxY > window.maxY + 50, "the target of the take reached \(old.rect.maxY) of a window ending at \(window.maxY)")
    }

    @Test func aPointerOverNoWindowGetsNoTargetAndOneInsideTheWindowNeverLeavesIt() throws {
        // The window list has windows and the pointer is over none: nothing to be had, so nothing outlined over the Dock.
        let bounds = LensTarget.targetBounds(over: nil, windowsKnown: true, on: display)
        #expect(bounds == nil)
        // Whatever the pointer does below the window, no target stands outside the window's content.
        for y in stride(from: 892 as CGFloat, through: 981, by: 3) {
            let p = CGPoint(x: 514, y: y)
            let t = LensTarget.targetBounds(over: nil, windowsKnown: true, on: display).flatMap { LensTarget.choose(map, pointer: p, bounds: $0) }
            #expect(t == nil, "a target at y \(y): \(String(describing: t?.rect))")
        }
        // Over the window: the content, below the title bar; every target of the page inside it.
        let content = try #require(LensTarget.targetBounds(over: window, windowsKnown: true, on: display))
        #expect(content == CGRect(x: 0, y: 61, width: 1512, height: 830))
        for y in stride(from: 70 as CGFloat, through: 890, by: 5) {
            guard let t = LensTarget.choose(map, pointer: CGPoint(x: 514, y: y), bounds: content) else { continue }
            #expect(content.contains(t.rect), "y \(y): \(t.rect)")
        }
        // No window list at all (no permission, a check): the display, as before.
        #expect(LensTarget.targetBounds(over: nil, windowsKnown: false, on: display) == display)
    }
}

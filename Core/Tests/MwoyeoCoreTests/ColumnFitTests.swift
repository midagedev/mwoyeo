import CoreGraphics
import Foundation
import Testing
@testable import MwoyeoCore

/// Where the columns of a page are, and what a lens does about them (round fit117, docs/design/lens-fit.md sections 5 and 12): the estimator on the
/// blocks of page 10 of our own paper (the measured cell: left error at most 0.6 pt, right at most 2.0, width within 3), what claims no column, which
/// column is under a lens, the unknown edges of a cut capture, the fitted rect, the snap with its hysteresis, the probe's band.
@Suite struct ColumnFitTests {
    private func column(_ left: CGFloat, _ right: CGFloat, top: CGFloat = 0, bottom: CGFloat = 1000, lines: Int = 20, known: Bool = true) -> ColumnFit.Column {
        ColumnFit.Column(left: left, right: right, top: top, bottom: bottom, blocks: 1, lines: lines,
                         cores: [CGRect(x: left, y: top, width: right - left, height: bottom - top)], leftKnown: known, rightKnown: known)
    }
    private func block(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, lines: Int) -> ColumnFit.Block {
        ColumnFit.Block(core: CGRect(x: x, y: y, width: w, height: h), lines: lines)
    }
    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let box = CGRect(x: 0, y: 0, width: 100, height: 100)

    // MARK: columns

    @Test func pageTenGivesItsTwoBodyColumnsAtThePDFEdges() {
        let columns = ColumnFit.columns(PaperPage10.blocks)
        #expect(columns.count == 2)
        guard columns.count == 2 else { return }
        for (found, truth) in zip(columns, [PaperPage10.leftColumn, PaperPage10.rightColumn]) {
            #expect(abs(found.left - truth.left) <= 1, "left \(found.left) vs \(truth.left)")
            #expect(abs(found.right - truth.right) <= 2.5, "right \(found.right) vs \(truth.right)")
            #expect(abs(found.width - (truth.right - truth.left)) <= 3)
        }
        #expect(columns.map(\.blocks) == [6, 6] && columns.map(\.lines) == [42, 37])
    }

    @Test func oneLineBlocksClaimNothing() {
        // A table's cells, headings, a subtitle bar: each is one line, whatever stands under it.
        let cells = (0..<8).map { block(100 + CGFloat($0 % 2) * 200, 100 + CGFloat($0 / 2) * 30, 120, 14, lines: 1) }
        #expect(ColumnFit.columns(cells).isEmpty)
        #expect(ColumnFit.columns([block(100, 100, 300, 40, lines: 3)]).isEmpty)   // three lines are under the support of four
        #expect(ColumnFit.columns([block(100, 100, 300, 40, lines: 2), block(100, 160, 300, 40, lines: 2)]).count == 1)
    }

    @Test func aFullWidthParagraphSharingTheLeftEdgeSplitsOffByItsRightEdge() {
        let half = [block(72, 300, 325, 200, lines: 12), block(72, 520, 325, 100, lines: 6)]
        let wide = [block(72, 100, 700, 60, lines: 4)]
        let columns = ColumnFit.columns(wide + half)
        #expect(columns.count == 2)
        #expect(Set(columns.map { $0.right.rounded() }) == [397, 772])
    }

    @Test func leftEdgesMoreThanSixPointsApartAreTwoStacks() {
        // An indent 10 pt in from the column stands in its own stack (and column) ...
        let indented = [block(72, 100, 325, 200, lines: 12), block(82, 320, 315, 100, lines: 6)]
        #expect(ColumnFit.columns(indented).count == 2)
        // ... and 5 pt in, it is the same column.
        let slight = [block(72, 100, 325, 200, lines: 12), block(77, 320, 320, 100, lines: 6)]
        #expect(ColumnFit.columns(slight).count == 1)
    }

    @Test func columnsComeBackLeftToRight() {
        let blocks = [block(420, 100, 325, 200, lines: 12), block(72, 100, 325, 200, lines: 12)]
        #expect(ColumnFit.columns(blocks).map(\.left) == [72, 420])
    }

    // MARK: under

    @Test func underAnswersTheColumnHoldingTheLensOrNothing() {
        let a = column(72, 397), b = column(420, 745)
        #expect(ColumnFit.under(CGRect(x: 100, y: 300, width: 200, height: 250), in: [a, b]) == a)
        #expect(ColumnFit.under(CGRect(x: 60, y: 300, width: 360, height: 250), in: [a, b]) == a)           // wider than the column
        #expect(ColumnFit.under(CGRect(x: 150, y: 300, width: 100, height: 250), in: [a, b]) == a)          // narrower
        #expect(ColumnFit.under(CGRect(x: 330, y: 300, width: 160, height: 250), in: [a, b]) == nil)        // across the gutter
        #expect(ColumnFit.under(CGRect(x: 60, y: 300, width: 700, height: 250), in: [a, b]) == nil)         // across both
        #expect(ColumnFit.under(CGRect(x: 100, y: 1200, width: 200, height: 250), in: [a, b]) == nil)       // below the page's text
        #expect(ColumnFit.under(CGRect(x: 900, y: 300, width: 200, height: 250), in: [a, b]) == nil)        // beside it
        #expect(ColumnFit.under(CGRect(x: 100, y: 300, width: 0, height: 250), in: [a]) == nil)
    }

    @Test func aLensNeedsFortyPercentOfItsWidthInAColumn() {
        let a = column(72, 397)
        #expect(ColumnFit.under(CGRect(x: 360, y: 300, width: 100, height: 250), in: [a]) == nil)     // 37 of 100
        #expect(ColumnFit.under(CGRect(x: 360, y: 300, width: 90, height: 250), in: [a]) == a)        // 37 of 90
    }

    @Test func aColumnTheCaptureCutDoesNotInflateARival() {
        // The capture ends at 260: the column is read as 72...260 though it goes on. Over a 300 wide lens it holds 160 of 300, a sliver of
        // another column holds 20: the share is of the lens's width, so the first wins (by the column's own width it would have been 0.85 against 0.2).
        let cut = column(72, 260, known: false), sliver = column(380, 745)
        #expect(ColumnFit.under(CGRect(x: 100, y: 300, width: 300, height: 250), in: [cut, sliver]) == cut)
    }

    // MARK: unknown edges

    @Test func anEdgeAtTheCapturesSideIsUnknownUnlessThatSideIsTheDisplays() {
        let capture = CGRect(x: 90, y: 200, width: 400, height: 500)
        let columns = ColumnFit.marked([column(90.5, 300), column(120, 489), column(130, 200)], capture: capture, display: display)
        #expect(columns.map(\.leftKnown) == [false, true, true])
        #expect(columns.map(\.rightKnown) == [true, false, true])
        // 3 pt from the capture's edge is the column's own: only 2.5 pt or less is where the capture ends.
        let near = ColumnFit.marked([column(93, 300), column(120, 487)], capture: capture, display: display)
        #expect(near.allSatisfy { $0.leftKnown && $0.rightKnown })
        // The capture reaches the display's edge: the page ends there, the edge is known.
        let atDisplay = ColumnFit.marked([column(1, 300), column(100, 1511.5)], capture: CGRect(x: 0, y: 0, width: 1512, height: 400), display: display)
        #expect(atDisplay.allSatisfy { $0.leftKnown && $0.rightKnown })
    }

    @Test func aBoxTouchesACapturesSideWithinTheTolerance() {
        #expect(CaptureEdge.touchesSide(CGRect(x: 2.5, y: 0, width: 10, height: 10), .left, in: box, tolerance: 2.5))
        #expect(!CaptureEdge.touchesSide(CGRect(x: 2.6, y: 0, width: 10, height: 10), .left, in: box, tolerance: 2.5))
        #expect(CaptureEdge.touchesSide(CGRect(x: 80, y: 0, width: 17.5, height: 10), .right, in: box, tolerance: 2.5))
        #expect(!CaptureEdge.touchesSide(CGRect(x: 80, y: 0, width: 17, height: 10), .right, in: box, tolerance: 2.5))
        // The default is the lines' tolerance (4 pixels).
        #expect(CaptureEdge.touchesSide(CGRect(x: 4, y: 0, width: 10, height: 10), .left, in: box))
        #expect(!CaptureEdge.touchesSide(CGRect(x: 4.5, y: 0, width: 10, height: 10), .left, in: box))
    }

    // MARK: fitted

    private let lens = CGRect(x: 150, y: 300, width: 200, height: 150)

    @Test func fittedPutsTheLensOnTheColumnWithItsPadAndKeepsItsRows() {
        guard case let .to(r, runsOff) = ColumnFit.fitted(lens, to: column(72, 398), within: display) else { Issue.record("no fit"); return }
        #expect(r == CGRect(x: 66, y: 300, width: 338, height: 150) && !runsOff)           // grow
        guard case let .to(s, _) = ColumnFit.fitted(CGRect(x: 0, y: 300, width: 700, height: 150), to: column(72, 398), within: display)
        else { Issue.record("no fit"); return }
        #expect(s == CGRect(x: 66, y: 300, width: 338, height: 150))                         // shrink: a manual fit takes both edges to the column
    }

    @Test func fittedStaysInsideTheDisplayAndTheWindow() {
        // A column that starts at the display's edge: the lens takes the edge, and says the column runs off.
        guard case let .to(r, runsOff) = ColumnFit.fitted(lens, to: column(1, 398), within: display) else { Issue.record("no fit"); return }
        #expect(r.minX == 0 && r.maxX == 404 && runsOff)
        // 5 pt in from the display's edge, the pad alone is clamped: not a column running off.
        guard case let .to(q, off) = ColumnFit.fitted(lens, to: column(5, 398), within: display) else { Issue.record("no fit"); return }
        #expect(q.minX == 0 && !off)
        // A window lens: the window's edge clamps.
        let window = CGRect(x: 40, y: 100, width: 340, height: 700)
        guard case let .to(w, windowOff) = ColumnFit.fitted(lens, to: column(72, 398), within: display.intersection(window)) else { Issue.record("no fit"); return }
        #expect(w.minX == 66 && w.maxX == 380 && windowOff)
    }

    @Test func fittedAlignsToTheScreensPixels() {
        guard case let .to(retina, _) = ColumnFit.fitted(lens, to: column(72.4, 398.3), within: display, scale: 2),
              case let .to(plain, _) = ColumnFit.fitted(lens, to: column(72.4, 398.3), within: display, scale: 1)
        else { Issue.record("no fit"); return }
        #expect(retina.minX == 66.5 && retina.maxX == 404.5)
        #expect(plain.minX == 66 && plain.maxX == 404)
    }

    @Test func aFitUnderTwoPointsIsNothingToDo() {
        #expect(ColumnFit.fitted(CGRect(x: 66, y: 300, width: 338, height: 150), to: column(72, 398), within: display) == .unchanged)
        #expect(ColumnFit.fitted(CGRect(x: 67.5, y: 300, width: 337, height: 150), to: column(72, 398), within: display) == .unchanged)
        guard case .to = ColumnFit.fitted(CGRect(x: 68, y: 300, width: 336, height: 150), to: column(72, 398), within: display) else { Issue.record("no fit at 2 pt"); return }
    }

    @Test func anUnknownEdgeIsAProbeNotAGuess() {
        var cut = column(72, 398)
        cut.rightKnown = false
        #expect(ColumnFit.fitted(lens, to: cut, within: display) == .probe([.right]))
        cut.leftKnown = false
        #expect(ColumnFit.fitted(lens, to: cut, within: display) == .probe([.left, .right]))
        // Only the edges that may move are asked about.
        #expect(ColumnFit.fitted(lens, to: cut, within: display, sides: .left) == .probe([.left]))
        #expect(ColumnFit.fitted(lens, to: cut, within: display, sides: [], growOnly: true) == .unchanged)
    }

    @Test func growOnlyNeverTakesAnEdgeInward() {
        #expect(ColumnFit.fitted(CGRect(x: 0, y: 300, width: 700, height: 150), to: column(72, 398), within: display, growOnly: true) == .unchanged)
        guard case let .to(r, _) = ColumnFit.fitted(CGRect(x: 0, y: 300, width: 300, height: 150), to: column(72, 398), within: display, growOnly: true)
        else { Issue.record("no fit"); return }
        #expect(r.minX == 0 && r.maxX == 404)      // the left edge stays where it was (outside the column), the right grows
    }

    // MARK: snap

    private var targets: ColumnFit.Targets { ColumnFit.Targets(columns: [column(72, 397), column(420, 745)]) }

    @Test func targetsStandOnTheColumnEdgesLessAndPlusThePad() {
        #expect(targets.lefts.map(\.x) == [66, 414] && targets.rights.map(\.x) == [403, 751])
    }

    /// film4 F4 (2026-10-22): the snap's right target was the edge of what had been read, 44 pt inside the column's true edge; at the true edge no guide showed.
    @Test func anEdgeTheReadEndedAtIsNotATarget() {
        let cut = ColumnFit.Column(left: 420, right: 745, top: 0, bottom: 1000, blocks: 1, lines: 20, rightKnown: false)
        let t = ColumnFit.Targets(columns: [column(72, 397), cut])
        #expect(t.lefts.map(\.x) == [66, 414] && t.rights.map(\.x) == [403])
        #expect(ColumnFit.snap(CGRect(x: 100, y: 0, width: 645, height: 100), edges: .right, targets: t) == nil)
        let leftCut = ColumnFit.Column(left: 420, right: 745, top: 0, bottom: 1000, blocks: 1, lines: 20, leftKnown: false)
        let u = ColumnFit.Targets(columns: [leftCut])
        #expect(u.lefts.isEmpty && u.rights.map(\.x) == [751])
    }

    @Test func snapPullsWithinEightAndLetsGoAtTwelve() {
        func snap(_ x: CGFloat, previous: ColumnFit.Snap? = nil) -> ColumnFit.Snap? {
            ColumnFit.snap(CGRect(x: x, y: 300, width: 200, height: 100), targets: targets, previous: previous)
        }
        #expect(snap(58)?.offset == 8 && snap(58)?.edge == .left)
        #expect(snap(57.9) == nil)                                                    // 8.1 away
        let held = snap(60)
        #expect(held?.offset == 6)
        #expect(snap(54, previous: held)?.offset == 12)                               // still held at 12
        #expect(snap(53.9, previous: held) == nil)                                    // let go beyond it
        #expect(snap(53.9) == nil && snap(54) == nil)                                 // and not caught from there
    }

    @Test func theLivePullTapersFromTheTargetToTheRelease() {
        // On the target: nothing to pull. Within the plateau the edge stands on the target (all of the pull). Beyond it less and less, none at 12.
        #expect(ColumnFit.livePull(0) == 0)
        #expect(ColumnFit.livePull(3) == 3 && ColumnFit.livePull(-3) == -3 && ColumnFit.livePull(ColumnFit.plateau) == ColumnFit.plateau)
        #expect(ColumnFit.livePull(8) == 2 && ColumnFit.livePull(-8) == -2)
        #expect(abs(ColumnFit.livePull(11.5) - 0.25) < 1e-9)
        #expect(ColumnFit.livePull(12) == 0 && ColumnFit.livePull(30) == 0 && ColumnFit.livePull(-12) == 0)
    }

    @Test func snapGoesLeftToLeftAndRightToRightOnly() {
        // The lens's right edge at 66 stands on a left target: no snap. Its left edge at 403 stands on a right target: no snap.
        #expect(ColumnFit.snap(CGRect(x: -134, y: 0, width: 200, height: 100), targets: targets) == nil)
        #expect(ColumnFit.snap(CGRect(x: 403, y: 0, width: 200, height: 100), targets: targets) == nil)
        #expect(ColumnFit.snap(CGRect(x: 203, y: 0, width: 200, height: 100), targets: targets)?.edge == .right)
    }

    @Test func theNearerEdgeWinsAndATieGoesToTheLeft() {
        // Left edge 5 from 66, right edge 2 from 403: the right edge wins.
        let near = ColumnFit.snap(CGRect(x: 71, y: 0, width: 334, height: 100), targets: targets)
        #expect(near?.edge == .right && near?.offset == -2)
        let tie = ColumnFit.snap(CGRect(x: 70, y: 0, width: 329, height: 100), targets: targets)       // 4 from the left target, 4 from the right
        #expect(tie?.edge == .left && tie?.offset == -4)
    }

    @Test func aTieGoesToTheLeftEdgeEvenWhenTheRightWasHeld() {
        let held = ColumnFit.Snap(edge: .right, target: targets.rights[0], offset: 4)
        let tie = ColumnFit.snap(CGRect(x: 70, y: 0, width: 329, height: 100), targets: targets, previous: held)
        #expect(tie?.edge == .left && tie?.offset == -4)
    }

    @Test func holdingCommandBypassesTheSnap() {
        #expect(ColumnFit.snap(CGRect(x: 60, y: 300, width: 200, height: 100), targets: targets, bypass: true) == nil)
    }

    @Test func aResizeMovesOnlyTheRightEdge() {
        // The left edge stands 3 from a left target; only the right edge of a resize may snap.
        #expect(ColumnFit.snap(CGRect(x: 63, y: 0, width: 200, height: 100), edges: .right, targets: targets) == nil)
        #expect(ColumnFit.snap(CGRect(x: 63, y: 0, width: 342, height: 100), edges: .right, targets: targets)?.offset == -2)
    }

    @Test func noTargetsNoSnap() {
        #expect(ColumnFit.snap(CGRect(x: 60, y: 300, width: 200, height: 100), targets: ColumnFit.Targets()) == nil)
    }

    // MARK: the probe's capture

    @Test func theBandIsTheDisplaysWidthAtTheLensRowsOnTheGrid() {
        let band = Overscan.band(around: CGRect(x: 400, y: 300, width: 300, height: 200), display: display)
        #expect(band == CGRect(x: 0, y: 220, width: 1512, height: 360))
        let top = Overscan.band(around: CGRect(x: 400, y: 20, width: 300, height: 200), display: display)
        #expect(top.minY == 0 && top.height == 360)
        let low = Overscan.band(around: CGRect(x: 400, y: 900, width: 300, height: 200), display: display)
        #expect(low.maxY == 982 && low.height == 360)
        for r in [band, top, low] {
            #expect(r.minX.truncatingRemainder(dividingBy: Overscan.grid) == 0 && r.width.truncatingRemainder(dividingBy: Overscan.grid) == 0)
            #expect(r.minY.truncatingRemainder(dividingBy: Overscan.grid) == 0 && r.height.truncatingRemainder(dividingBy: Overscan.grid) == 0)
            #expect(display.contains(r))
        }
        // A display of odd width: the band is cut down to the grid, never past the display.
        #expect(Overscan.band(around: CGRect(x: 10, y: 10, width: 50, height: 50), display: CGRect(x: 0, y: 0, width: 1511, height: 800)).width == 1510)
    }

    @Test func aProbingPlanWantsTheBandAndKeepsItOnceThere() {
        let l = CGRect(x: 400, y: 300, width: 300, height: 200), band = Overscan.band(around: l, display: display)
        let at = Overscan.rect(around: l, wide: false, display: display)
        #expect(Overscan.plan(lens: l, capture: at, wide: false, allowResize: false, display: display, band: band) == .resize(band))
        #expect(Overscan.plan(lens: l, capture: band, wide: false, allowResize: false, display: display, band: band) == .keep)
        // A lens that grows under a hand (a resize drag) leaves the band as it was taken: a band that followed it would resize the capture on every
        // frame and no read could end (film4 F4: the snap's targets come from one read of the band at the drag's start).
        let grown = CGRect(x: 400, y: 300, width: 520, height: 330)
        #expect(Overscan.band(around: grown, display: display) != band)
        #expect(Overscan.plan(lens: grown, capture: band, wide: false, allowResize: false, display: display, band: band) == .keep)
        // Done probing: the usual capture comes back.
        #expect(Overscan.plan(lens: l, capture: band, wide: false, allowResize: true, display: display) == .resize(at))
    }

    @Test func aChangeOfThePullIsAGuideAndOneTickOrTheirEnd() {
        let a = ColumnFit.Snap(edge: .right, target: .init(x: 403, top: 0, bottom: 900), offset: -3)
        let a2 = ColumnFit.Snap(edge: .right, target: .init(x: 403, top: 0, bottom: 900), offset: -5)         // the same target, nearer or further
        let b = ColumnFit.Snap(edge: .right, target: .init(x: 751, top: 0, bottom: 900), offset: 4)
        let l = ColumnFit.Snap(edge: .left, target: .init(x: 403, top: 0, bottom: 900), offset: 2)
        #expect(ColumnFit.change(from: nil, to: nil) == .none)
        #expect(ColumnFit.change(from: nil, to: a) == .enter(a))
        #expect(ColumnFit.change(from: a, to: a2) == .none)
        #expect(ColumnFit.change(from: a, to: b) == .enter(b))
        #expect(ColumnFit.change(from: a, to: l) == .enter(l))
        #expect(ColumnFit.change(from: a, to: nil) == .leave)
    }

    @Test func theUnknownEdgesAreThoseOfTheColumnsAtTheLensRows() {
        let cut = ColumnFit.Column(left: 420, right: 745, top: 100, bottom: 400, blocks: 1, lines: 20, rightKnown: false)
        let far = ColumnFit.Column(left: 900, right: 1200, top: 600, bottom: 900, blocks: 1, lines: 20, leftKnown: false)
        let lens = CGRect(x: 400, y: 200, width: 300, height: 100)
        #expect(ColumnFit.unknownEdges(near: lens, in: [cut, far]) == .right)
        #expect(ColumnFit.unknownEdges(near: lens, in: [column(72, 397), column(420, 745)]).isEmpty)
        #expect(ColumnFit.unknownEdges(near: CGRect(x: 400, y: 650, width: 300, height: 100), in: [cut, far]) == .left)
    }

    // MARK: against the other owner of a column's right edge

    @Test func theColumnsRightEdgeAgreesWithColumnEdge() {
        // `ColumnEdge.right(of:among:)` answers how far a block's translation may spill; the column estimator answers where the column ends. On the body
        // column of page 10 they say the same.
        let cores = PaperPage10.blocks.map(\.core)
        let columns = ColumnFit.columns(PaperPage10.blocks)
        guard let body = PaperPage10.blocks.first(where: { $0.lines == 21 }), let edge = ColumnEdge.right(of: body.core, among: cores) else { Issue.record("no edge"); return }
        guard let first = columns.first else { Issue.record("no column"); return }
        #expect(abs(edge - first.right) < 0.001)
    }
}

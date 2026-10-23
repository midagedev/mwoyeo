import CoreGraphics
import Foundation
import Testing
@testable import MwoyeoCore

/// Auto Fit's table (round fit117, docs/design/lens-fit.md section 7): every row is a case of (state, event, what the session saw) and what comes out.
/// No clock: the session's "content has stood still a second" is the context's `calm` flag.
@Suite struct AutoFitTests {
    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let page = ColumnFit.Column(left: 72, right: 398, top: 77, bottom: 966, blocks: 1, lines: 30,
                                        cores: [CGRect(x: 72, y: 300, width: 326, height: 300)])
    private let lens = CGRect(x: 150, y: 320, width: 200, height: 150)
    private let edges = AutoFit.Edges(left: 72, right: 398)
    private func context(_ lens: CGRect? = nil, column: ColumnFit.Column? = nil, calm: Bool = true, bounds: CGRect? = nil) -> AutoFit.Context {
        AutoFit.Context(calm: calm, lens: lens ?? self.lens, bounds: bounds ?? display, column: column ?? page)
    }
    private func armed() -> AutoFit.Machine { AutoFit.Machine(state: .armed) }
    private let grown = CGRect(x: 66, y: 320, width: 338, height: 150)

    @Test func turnedOnItWaitsForASettle() {
        let (m, a) = AutoFit.step(AutoFit.Machine(), .enable)
        #expect(m.state == .armed && a == .none)
    }

    @Test func aSettleThatCutsTheColumnGrowsTheLensToItOnce() {
        let (m, a) = AutoFit.step(armed(), .settled(context()))
        #expect(m.state == .fitting && a == .grow(grown))
        // The animation ends: the lens commits and holds the column.
        let (done, commit) = AutoFit.step(m, .animationDone(edges))
        #expect(done.state == .held && commit == .commit && done.lastFit == edges)
        // A second settle on the same column does nothing, whichever way the lens now stands.
        let (again, none) = AutoFit.step(done, .settled(context(grown)))
        #expect(again.state == .held && none == .none)
    }

    @Test func nothingHappensBeforeTheContentStandsStill() {
        let (m, a) = AutoFit.step(armed(), .settled(context(calm: false)))
        #expect(m.state == .armed && a == .none)
    }

    @Test func nothingHappensWithoutOneColumnUnderTheLens() {
        var c = context()
        c.column = nil
        let (m, a) = AutoFit.step(armed(), .settled(c))
        #expect(m.state == .armed && a == .none)
    }

    @Test func aLensThatHoldsTheColumnWhole_orIsWiderThanIt_isLeftAlone() {
        for l in [CGRect(x: 60, y: 320, width: 350, height: 150), CGRect(x: 0, y: 320, width: 700, height: 150)] {
            let (m, a) = AutoFit.step(armed(), .settled(context(l)))
            #expect(m.state == .armed && a == .none, "lens \(l)")
        }
    }

    @Test func aLensThatMissesTheColumnsTextVerticallyIsLeftAlone() {
        // Between two paragraphs: the column is under it by its extent, but no block of it meets the lens.
        let (m, a) = AutoFit.step(armed(), .settled(context(CGRect(x: 150, y: 620, width: 200, height: 150))))
        #expect(m.state == .armed && a == .none)
    }

    @Test func itNeverShrinksAndOnlyGrowsTheCutSide() {
        // The lens already reaches past the column on the right and cuts it on the left: only the left edge moves.
        let (m, a) = AutoFit.step(armed(), .settled(context(CGRect(x: 150, y: 320, width: 400, height: 150))))
        #expect(m.state == .fitting && a == .grow(CGRect(x: 66, y: 320, width: 484, height: 150)))
    }

    @Test func aCutEdgeTheCaptureEndedAtIsProbedFirst() {
        var cut = page
        cut.rightKnown = false
        let (m, a) = AutoFit.step(armed(), .settled(context(column: cut)))
        #expect(m.state == .probing([.right]) && a == .probe([.right]))
        // Its snapshot knows the edge: grow.
        let (fit, grow) = AutoFit.step(m, .probed(context()))
        #expect(fit.state == .fitting && grow == .grow(grown))
        // Still unknown (the read found no more): nothing, the capture goes back, never a second probe.
        let (stay, skip) = AutoFit.step(m, .probed(context(column: cut)))
        #expect(stay.state == .armed && skip == .skip(.unknown))
        // The snapshot never came, or the user took the lens: back to armed, the capture goes back.
        for event in [AutoFit.Event.probeLapsed, .dragged] {
            let (back, restore) = AutoFit.step(m, event)
            #expect(back.state == .armed && restore == .restoreCapture, "\(event)")
        }
    }

    @Test func aGrowthOnlyAHairLongIsSkippedAsTooSmall() {
        // The window ends 5 pt past the lens's right edge; the column goes on: the growth is under 6.
        let l = CGRect(x: 72, y: 320, width: 928, height: 150)
        let wide = ColumnFit.Column(left: 72, right: 1010, top: 77, bottom: 966, blocks: 1, lines: 30, cores: [CGRect(x: 72, y: 300, width: 938, height: 300)])
        let (m, a) = AutoFit.step(armed(), .settled(context(l, column: wide, bounds: CGRect(x: 0, y: 0, width: 1005, height: 982))))
        #expect(m.state == .armed && a == .skip(.small))
    }

    @Test func theEdgesOfTheDesignsTableAreExact() {
        // Cut: the column's text reaches beyond the lens's edge by more than 4 pt (right edge 398: a lens ending at 394 is at 4, at 393.9 it is cut).
        let at4 = AutoFit.step(armed(), .settled(context(CGRect(x: 60, y: 320, width: 334, height: 150))))
        let at5 = AutoFit.step(armed(), .settled(context(CGRect(x: 60, y: 320, width: 333.9, height: 150))))
        #expect(at4.action == .none && at4.machine.state == .armed)
        #expect(at5.machine.state == .fitting)
        // The same column: the edges of the last fit within 12 pt (12 held, 12.1 judged afresh: here it grows again).
        let held = AutoFit.Machine(state: .held, lastFit: AutoFit.Edges(left: 60, right: 386))
        let same = AutoFit.step(held, .settled(context(CGRect(x: 150, y: 320, width: 200, height: 150))))
        let other = AutoFit.step(AutoFit.Machine(state: .held, lastFit: AutoFit.Edges(left: 59.9, right: 386)), .settled(context(CGRect(x: 150, y: 320, width: 200, height: 150))))
        #expect(same.machine.state == .held && same.action == .none)
        #expect(other.machine.state == .fitting)
        // Growth: the target at most twice the lens (a lens of 169 reaches 338 at 2.0 x; 168 is over), and a change of 6 pt or more.
        let twice = AutoFit.step(armed(), .settled(context(CGRect(x: 150, y: 320, width: 169, height: 150))))
        let over = AutoFit.step(armed(), .settled(context(CGRect(x: 150, y: 320, width: 168.9, height: 150))))
        #expect(twice.machine.state == .fitting && over.action == .skip(.tooWide))
        let wide = ColumnFit.Column(left: 72, right: 1010, top: 77, bottom: 966, blocks: 1, lines: 30, cores: [CGRect(x: 72, y: 300, width: 938, height: 300)])
        // The window ends at 1005: a lens ending at 999.1 would grow by 5.9, one ending at 999 by exactly 6.
        let bounds = CGRect(x: 0, y: 0, width: 1005, height: 982)
        let five = AutoFit.step(armed(), .settled(context(CGRect(x: 72, y: 320, width: 927.1, height: 150), column: wide, bounds: bounds)))
        let six = AutoFit.step(armed(), .settled(context(CGRect(x: 72, y: 320, width: 927, height: 150), column: wide, bounds: bounds)))
        #expect(five.action == .skip(.small) && six.machine.state == .fitting)
    }

    @Test func aTargetOverTwiceTheLensIsSkipped() {
        let (m, a) = AutoFit.step(armed(), .settled(context(CGRect(x: 200, y: 320, width: 100, height: 150))))
        #expect(m.state == .armed && a == .skip(.tooWide))
    }

    @Test func aSideAlreadyAtTheBoundDoesNotMoveAndWithNothingElseToMoveItIsSkipped() {
        // A window lens at its window's right edge, the column going on past it, and cut on the left as well: the left edge moves.
        let l = CGRect(x: 150, y: 320, width: 230, height: 150)
        let (m, a) = AutoFit.step(armed(), .settled(context(l, bounds: CGRect(x: 40, y: 0, width: 340, height: 982))))
        #expect(m.state == .fitting && a == .grow(CGRect(x: 66, y: 320, width: 314, height: 150)))
        // Only the right is cut, and it stands on the bound: nothing to move.
        let (s, skip) = AutoFit.step(armed(), .settled(context(CGRect(x: 72, y: 320, width: 308, height: 150), bounds: CGRect(x: 72, y: 0, width: 308, height: 982))))
        #expect(s.state == .armed && skip == .skip(.atEdge))
    }

    @Test func aHeldLensStaysHeldOnTheSameColumnAndRearmsOnAnother() {
        let held = AutoFit.Machine(state: .held, lastFit: edges)
        let nearby = ColumnFit.Column(left: 75, right: 395, top: 0, bottom: 1000, blocks: 1, lines: 30, cores: page.cores)   // within 12
        let (same, none) = AutoFit.step(held, .settled(context(grown, column: nearby)))
        #expect(same.state == .held && none == .none)
        // The lens was dropped on the other column (or the column moved more than 12): armed again, and this settle is judged as an armed one.
        let other = ColumnFit.Column(left: 420, right: 746, top: 0, bottom: 1000, blocks: 1, lines: 30, cores: [CGRect(x: 420, y: 300, width: 326, height: 300)])
        let (m, a) = AutoFit.step(held, .settled(context(CGRect(x: 500, y: 320, width: 200, height: 150), column: other)))
        #expect(m.state == .fitting && a == .grow(CGRect(x: 414, y: 320, width: 338, height: 150)))
        // Over nothing at all: armed, nothing to do.
        var empty = context()
        empty.column = nil
        let (idle, nothing) = AutoFit.step(held, .settled(empty))
        #expect(idle.state == .armed && nothing == .none)
    }

    @Test func aHandOnTheLensStopsAFitAndReArmsItWhereItLands() {
        let fitting = AutoFit.Machine(state: .fitting)
        let held = AutoFit.Machine(state: .held, lastFit: edges)
        #expect(AutoFit.step(fitting, .dragged).machine.state == .armed)
        #expect(AutoFit.step(held, .dragged).machine.state == .armed)
        #expect(AutoFit.step(armed(), .dragged).machine == armed())
    }

    @Test func aManualResizeTurnsItOffInEveryState() {
        for s in [AutoFit.State.armed, .probing([.left]), .fitting, .held] {
            let (m, a) = AutoFit.step(AutoFit.Machine(state: s), .resized)
            #expect(m.state == .off && a == .disable, "\(s)")
        }
        // Off already: nothing to say.
        let (off, quiet) = AutoFit.step(AutoFit.Machine(), .resized)
        #expect(off.state == .off && quiet == .none)
        // Back on by the menu: armed again.
        #expect(AutoFit.step(AutoFit.Machine(), .enable).machine.state == .armed)
    }

    @Test func theMenuTurnsItOffFromAnyState_andAProbeGivesTheCaptureBack() {
        for s in [AutoFit.State.armed, .fitting, .held] {
            let (m, a) = AutoFit.step(AutoFit.Machine(state: s), .disable)
            #expect(m.state == .off && a == .none, "\(s)")
        }
        let (m, a) = AutoFit.step(AutoFit.Machine(state: .probing([.right])), .disable)
        #expect(m.state == .off && a == .restoreCapture)
    }

    @Test func aFitByHandRemembersItsColumnAndChangesNoState() {
        for s in [AutoFit.State.off, .armed, .held] {
            let (m, a) = AutoFit.step(AutoFit.Machine(state: s), .fitted(edges))
            #expect(m.state == s && m.lastFit == edges && a == .none, "\(s)")
        }
    }

    @Test func anOffLensTakesNoSettle() {
        let (m, a) = AutoFit.step(AutoFit.Machine(), .settled(context()))
        #expect(m.state == .off && a == .none)
    }

    @Test func aLensLetGoOnOtherContentTakesItsShape_andOnTheSameContentStays() {
        let lens = CGRect(x: 849, y: 266, width: 550, height: 271)
        let other = CGRect(x: 60, y: 400, width: 250, height: 330)    // narrower, lower, to the left: a land may shrink and move
        for s in [AutoFit.State.armed, .held] {
            let (m, a) = AutoFit.step(AutoFit.Machine(state: s, lastFit: edges), .landed(lens: lens, target: other))
            #expect(m.state == .fitting && a == .land(other), "\(s)")
        }
        // The same content (every edge within minGrow), or none: armed, nothing done; the column fit judges as before.
        let same = lens.insetBy(dx: 2, dy: 2)
        for target in [same, nil] {
            let (m, a) = AutoFit.step(armed(), .landed(lens: lens, target: target))
            #expect(m.state == .armed && a == .none)
        }
        // The animation ends held on the target's edges.
        let done = AutoFit.step(AutoFit.Machine(state: .fitting), .animationDone(AutoFit.Edges(left: other.minX, right: other.maxX)))
        #expect(done.machine.state == .held && done.action == .commit)
        // Off, or mid-fit: a landing changes nothing.
        #expect(AutoFit.step(AutoFit.Machine(), .landed(lens: lens, target: other)).action == .none)
        #expect(AutoFit.step(AutoFit.Machine(state: .fitting), .landed(lens: lens, target: other)).action == .none)
    }
}

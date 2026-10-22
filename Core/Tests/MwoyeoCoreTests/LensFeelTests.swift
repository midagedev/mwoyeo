import CoreGraphics
import Foundation
import Testing
@testable import MwoyeoCore

/// The feel of the lens's fit and snap (round fit117, addendum A2, 2026-10-22: "렌즈 자동 리사이즈나 스냅은 사용성이 정말 중요해서"): synthetic pointer paths and a
/// fake clock through the same Core functions the session uses, so what a hand would feel is a number. No wall clock: the paths and the timeline are data.
@Suite struct LensFeelTests {
    // MARK: the guide, the tick, the sweep

    /// The session's use of the pull, over a path of right-edge positions (what the hand put the edge at, never the snapped one): `snap` with the
    /// previous one carried, then `change` for the guide and the tick.
    private struct Sweep {
        var previous: ColumnFit.Snap?
        var events: [(x: CGFloat, change: ColumnFit.Change)] = []
        let targets: ColumnFit.Targets
        var enters: Int { events.filter { if case .enter = $0.change { true } else { false } }.count }
        var leaves: Int { events.filter { $0.change == .leave }.count }
        mutating func feed(_ x: CGFloat) {
            let next = ColumnFit.snap(CGRect(x: 100, y: 0, width: x - 100, height: 100), edges: .right, targets: targets, previous: previous)
            let change = ColumnFit.change(from: previous, to: next)
            if change != .none { events.append((x, change)) }
            previous = next
        }
    }
    private let target: CGFloat = 403          // a column's right edge at 397 and the pad
    private var targets: ColumnFit.Targets { ColumnFit.Targets(rights: [ColumnFit.Target(x: target, top: 0, bottom: 900)]) }
    private func path(_ from: CGFloat, _ to: CGFloat, step: CGFloat = 0.25) -> [CGFloat] {
        stride(from: from, through: to, by: from < to ? step : -step).map { $0 }
    }

    @Test func aSlowSweepBackAndForthAcrossTheReachAndTheReleaseHasNoFlickerAndOneTickPerEntry() {
        var sweep = Sweep(targets: targets)
        for _ in 0..<3 {
            (path(380, 430) + path(430, 380)).forEach { sweep.feed($0) }
        }
        // Three round trips cross the target twice each: six entries, six exits, alternating, each at its threshold.
        #expect(sweep.enters == 6 && sweep.leaves == 6, "\(sweep.enters) enters, \(sweep.leaves) leaves")
        for (i, e) in sweep.events.enumerated() {
            let away = abs(e.x - target)
            switch e.change {
            case .enter: #expect(i % 2 == 0 && away <= ColumnFit.reach, "enter at \(e.x)")
            case .leave: #expect(i % 2 == 1 && away > ColumnFit.release, "leave at \(e.x)")
            case .none: break
            }
        }
        // One tick per entry is by construction one `enter` per entry: the session ticks on `enter` and on nothing else.
        #expect(sweep.events.count == 12)
    }

    @Test func aHandTremblingAtTheReachOrAtTheReleaseDoesNotFlicker() {
        var sweep = Sweep(targets: targets)
        path(380, 395.4).forEach { sweep.feed($0) }                                // in, at 395 (8 pt away)
        for _ in 0..<40 { [394.6, 395.4].forEach { sweep.feed($0) } }              // trembles across the reach's border while held: stays in (12 pt out)
        #expect(sweep.enters == 1 && sweep.leaves == 0, "\(sweep.events.map(\.x))")
        path(395.4, 414.8).forEach { sweep.feed($0) }
        for _ in 0..<40 { [415.2, 414.8].forEach { sweep.feed($0) } }              // out at 415.2 (12.2 away); the next 414.8 is 11.8 away but not within the reach: no re-entry
        #expect(sweep.enters == 1 && sweep.leaves == 1, "\(sweep.events.map(\.x))")
    }

    @Test func aFastPassThroughTheReachStillShowsOneGuideAndOneTick() {
        var sweep = Sweep(targets: targets)
        [380, 394, 404, 412, 426].forEach { sweep.feed($0) }        // 14 pt steps: in at 404 (the first sample within 8), out at 426
        #expect(sweep.enters == 1 && sweep.leaves == 1)
    }

    /// One live resize as the session runs it (`RegionSession.snapResized`): every frame the hand puts the right edge at `x` (a `mouseDragged`, or a display
    /// frame in which it holds still), the snap is asked with the one before it (the hysteresis: taken from 8 pt, kept to 12), and `LiveSnap` says where the
    /// lens shows its edge. A new drag starts with no snap and no state (`noteDropped`).
    private struct Drag {
        var snap: ColumnFit.Snap?
        var live: LiveSnap
        var time: TimeInterval = 0
        let targets: ColumnFit.Targets
        let hz: Double
        init(_ feel: LiveSnap.Feel, targets: ColumnFit.Targets, hz: Double = 60, dwell: LiveSnap.Dwell = .standard) {
            live = LiveSnap(feel: feel, dwell: dwell); self.targets = targets; self.hz = hz
        }
        /// One frame with the hand at `x`: the edge the lens shows, whether the guide is up, and the taper's edge for it.
        @discardableResult mutating func frame(_ x: CGFloat) -> (edge: CGFloat, guide: Bool) {
            time += 1 / hz
            let hand = CGRect(x: 100, y: 0, width: x - 100, height: 100)
            snap = ColumnFit.snap(hand, edges: .right, targets: targets, previous: snap)
            return (100 + live.width(hand: hand, snap: snap, targets: targets, at: time), snap != nil)
        }
    }

    // MARK: instant (the motion contract's 3.1)

    @Test func anInstantDragCapturesTheEdgeInTheFrameItComesWithinReachGrowingOrShrinking() {
        // 2026-10-23 (snap117, motion contract 3.1): the edge is on the target in the very frame the hand comes within 8 pt of it, and under the hand again in
        // the very frame it passes 12 pt. fit117's taper (decision 16: on the target within 4 pt, none at 12) showed the guide at 7 pt with the edge still 4.5 pt
        // off it (the skinland117 take, 48.50 to 50.10 s), and glided it on after the release; it stays as the `dwell` feel. A hand at 1 pt a frame (slow), 4
        // (brisk) and 10 (a throw), right across the target both ways.
        for step in [1.0, 4.0, 10.0] as [CGFloat] {
            for (name, xs) in [("growing", Array(stride(from: 360, through: 450, by: step))), ("shrinking", Array(stride(from: 450, through: 360, by: -step)))] {
                var drag = Drag(.instant, targets: targets), held = false
                for x in xs {
                    let shown = drag.frame(x), away = abs(x - target)
                    if away <= ColumnFit.reach { held = true } else if away > ColumnFit.release { held = false }
                    #expect(shown.guide == held, "\(name) step \(step): hand at \(x), the guide is \(shown.guide)")
                    #expect(abs(shown.edge - (held ? target : x)) < 1e-9, "\(name) step \(step): hand at \(x) (\(away) from the target), the lens's edge is at \(shown.edge)")
                }
            }
        }
    }

    @Test func anInstantEdgeIsTheHandsOrTheTargetsNeverBetween() {
        // The magnet takes or lets go whole: a slow sweep both ways shows only the hand's own x and the target.
        var drag = Drag(.instant, targets: targets)
        for x in path(380, 430) + path(430, 380) {
            let edge = drag.frame(x).edge
            #expect(abs(edge - x) < 1e-9 || abs(edge - target) < 1e-9, "hand at \(x), the lens's edge is at \(edge)")
        }
    }

    @Test func aSecondInstantDragStartingWithinReachIsCapturedOnItsFirstFrameAndLandsOnTheTarget() {
        // The skinland117 take: a drag grows the lens past the column (the edge is let go at 12 pt), comes back to 7 pt short and holds there. Dropped (the
        // snap is cleared), the next drag grabs the edge 4 pt inside it and its first frame is 5 pt short.
        var first = Drag(.instant, targets: targets)
        let sweep = path(target - 3, target + 30, step: 3) + path(target + 30, target + 7, step: 3) + Array(repeating: target + 7, count: 30)
        let shown = sweep.map { first.frame($0) }
        #expect(abs(shown.last!.edge - target) < 1e-9 && shown.last!.guide, "held at 7 pt: the edge is at \(shown.last!.edge)")
        var second = Drag(.instant, targets: targets)
        let firstFrame = second.frame(target - 5)
        #expect(abs(firstFrame.edge - target) < 1e-9 && firstFrame.guide, "the second drag's first frame: the edge is at \(firstFrame.edge)")
    }

    @Test func anInstantWidthIsTheHandsOrTheSnapsAndNeverUnderTheFloor() {
        let t = ColumnFit.Target(x: 403, top: 0, bottom: 900)
        func width(_ hand: CGFloat, _ offset: CGFloat?) -> CGFloat {
            var live = LiveSnap(feel: .instant)
            return live.width(hand: CGRect(x: 100, y: 0, width: hand, height: 100), snap: offset.map { ColumnFit.Snap(edge: .right, target: t, offset: $0) }, targets: targets, at: 0)
        }
        #expect(width(300, nil) == 300 && width(300, 0) == 300)
        #expect(width(300, 8) == 308 && width(300, -8) == 292 && width(300, 12) == 312 && width(300, -12) == 288)
        #expect(width(85, -12) == ColumnFit.minWidth)
    }

    @Test func anInstantEdgeAsksNothingOfTheClock() {
        var slow = Drag(.instant, targets: targets, hz: 5), fast = Drag(.instant, targets: targets, hz: 240)
        for x in path(380, 430, step: 1) { #expect(slow.frame(x).edge == fast.frame(x).edge) }
    }

    // MARK: dwell (decision 16, with a capture while the hand holds still)

    /// The edge a taper-only lens shows (decision 16 as fit117 built it): the reference the `dwell` feel moves by while the hand moves.
    private func tapered(_ x: CGFloat) -> CGFloat {
        x + (ColumnFit.snap(CGRect(x: 100, y: 0, width: x - 100, height: 100), edges: .right, targets: targets, entry: ColumnFit.release).map { ColumnFit.livePull($0.offset) } ?? 0)
    }

    @Test func aMovingDwellDragNeverJumpsUnderTheHandWhileItIsPulledOntoAColumnAndReleasedFromIt() {
        // Decision 16 (fit117 addendum A2, 2026-10-22; not relaxed): a hand at 1 pt a frame (a slow drag), 4 (brisk) and 10 (a throw), right across the target
        // and back: the edge the person sees moves at most 1.5 times as far as the hand does in every frame (the first build moved it 8.5 pt on entering and
        // 12 pt on leaving, in one frame), and it stands on the target while the hand is within the plateau. The hand moves in every frame, so it never dwells.
        for step in [1.0, 4.0, 10.0] as [CGFloat] {
            var drag = Drag(.dwell, targets: targets), hand: CGFloat = 360, last = drag.frame(hand).edge, onTarget = 0, worst: CGFloat = 0
            for x in Array(stride(from: 360 + step, through: 450, by: step)) + Array(stride(from: 450 - step, through: 360, by: -step)) {
                let edge = drag.frame(x).edge
                worst = max(worst, abs(edge - last) / abs(x - hand))
                #expect(abs(edge - tapered(x)) < 1e-9, "step \(step): hand at \(x), the edge is \(edge) and the taper's \(tapered(x))")
                if abs(x - target) <= ColumnFit.plateau - 0.01 { #expect(abs(edge - target) < 1e-9, "step \(step): hand at \(x), edge at \(edge)"); onTarget += 1 }
                last = edge; hand = x
            }
            #expect(worst <= 1.5 + 1e-9, "step \(step): the edge moved \(worst) times the hand's step in one frame")
            if step <= 4 { #expect(onTarget > 0) }
            #expect(!drag.live.capturing)
        }
    }

    @Test func aHandHeldStillWithinTheGuideHasTheEdgeOnTheTargetBeforeItLetsGo() {
        // 2026-10-23 (snap117, addendum A1): the skinland117 take's second drag held the hand 7 pt off for 1.5 s and the edge stood 4.5 pt off the guide the whole
        // time. The hand arrives at 7 pt short (a taper edge 4.5 pt off), holds 0.5 s: the edge is on the target in the hold's `hold` + `settle`, in steps no
        // longer than the spring's own, and stays there.
        for hz in [60.0, 120.0] {
            var drag = Drag(.dwell, targets: targets, hz: hz)
            for x in path(target - 30, target - 7, step: 1) { drag.frame(x) }       // arrives at 1 pt a frame
            let arrival = drag.time, base = tapered(target - 7)
            #expect(abs(target - base) > 4, "the taper's edge is \(abs(target - base)) pt off the target")
            var last = base, onTargetAt: TimeInterval?, worstStep: CGFloat = 0
            while drag.time - arrival < 0.5 {
                let edge = drag.frame(target - 7).edge
                worstStep = max(worstStep, abs(edge - last))
                if onTargetAt == nil, abs(edge - target) < 1e-9 { onTargetAt = drag.time - arrival }
                last = edge
            }
            #expect(abs(last - target) < 1e-9 && drag.live.capturing, "\(hz) Hz: after 0.5 s of holding the edge is at \(last)")
            let landed = onTargetAt ?? .infinity
            #expect(landed <= LiveSnap.Dwell.standard.hold + LensMotion.settle + 2 / hz, "\(hz) Hz: on the target after \(landed) s")
            // The spring's own step: its largest frame (the velocity peaks at ω · t = 1: 33 ms in, 0.18 of the way at 60 Hz) of the distance it has to go.
            let own = abs(target - base) * (0..<60).map { FitMotion.progress(Double($0 + 1) / hz, duration: LensMotion.settle) - FitMotion.progress(Double($0) / hz, duration: LensMotion.settle) }.max()!
            #expect(worstStep <= own * 1.05 + 1e-9, "\(hz) Hz: the largest step was \(worstStep), the spring's own \(own)")
        }
    }

    @Test func aHandThatMovesAgainTakesTheEdgeBackToTheTaperFromWhereItIsWithoutAJump() {
        // Held and captured, then the hand moves away 3 pt a frame, out past 12 pt and beyond: the edge leaves the target by the spring and joins the taper
        // (none at 12) from where it is. In every frame it moves at most 1.5 times the hand's step plus the spring's own step of that frame.
        var drag = Drag(.dwell, targets: targets)
        for x in path(target - 30, target - 7, step: 1) { drag.frame(x) }
        for _ in 0..<60 { drag.frame(target - 7) }
        #expect(abs(drag.frame(target - 7).edge - target) < 1e-9 && drag.live.capturing)
        var hand = target - 7, last = target
        for _ in 0..<40 {
            hand -= 3                                           // away from the column, shrinking
            let level0 = drag.live.level(at: drag.time), edge = drag.frame(hand).edge, level1 = drag.live.level(at: drag.time)
            let spring = abs(level1 - level0) * abs(target - tapered(hand))
            #expect(abs(edge - last) <= 1.5 * 3 + spring + 1e-9, "hand at \(hand): the edge moved \(abs(edge - last)) pt")
            last = edge
        }
        #expect(!drag.live.capturing && abs(last - hand) < 1e-9, "far from the column the edge is the hand's: \(last) for \(hand)")
    }

    @Test func aTrembleUnderTheDwellsJitterKeepsTheCaptureAndAMoveOverItReleasesIt() {
        var drag = Drag(.dwell, targets: targets)
        for x in path(target - 30, target - 7, step: 1) { drag.frame(x) }
        for i in 0..<60 { drag.frame(target - 7 + (i % 2 == 0 ? 0.6 : -0.6)) }       // a trembling hand: 1.2 pt peak to peak, under the jitter
        #expect(drag.live.capturing)
        for _ in 0..<3 { drag.frame(target - 4) }                                    // a move of 3 pt: the hand is moving again
        #expect(!drag.live.capturing)
    }

    @Test func aHandThatHoldsStillBeyondTheGuideCapturesNothingAndLetsTheEdgeGoBackToIt() {
        // Far from every column a held hand has nothing to be taken to; and one that was captured and then rests 14 pt off (the guide is down from 12) has the
        // edge back under it once the spring has let go, not on the column it left.
        var far = Drag(.dwell, targets: targets)
        for _ in 0..<60 { far.frame(target - 30) }
        #expect(!far.live.capturing && abs(far.frame(target - 30).edge - (target - 30)) < 1e-9)
        var drag = Drag(.dwell, targets: targets)
        for x in path(target - 30, target - 7, step: 1) { drag.frame(x) }
        for _ in 0..<60 { drag.frame(target - 7) }
        #expect(drag.live.capturing)
        for _ in 0..<60 { drag.frame(target - 14) }
        #expect(!drag.live.capturing && drag.snap == nil && abs(drag.frame(target - 14).edge - (target - 14)) < 1e-9)
    }

    @Test func aSecondDwellDragStartsWithNothingHeld() {
        var drag = Drag(.dwell, targets: targets)
        for x in path(target - 30, target - 7, step: 1) { drag.frame(x) }
        for _ in 0..<60 { drag.frame(target - 7) }
        #expect(drag.live.capturing)
        drag.live.reset(); drag.snap = nil                                           // what `noteDropped` does
        let edge = drag.frame(target - 5).edge
        #expect(!drag.live.capturing && abs(edge - tapered(target - 5)) < 1e-9, "the first frame of a second drag follows the taper: \(edge)")
    }

    // MARK: what the ring shows of the two feels

    /// The scripted drag of the snap117 takes, in the hand's right edge a frame at a time (an ease-out between the stops, as drive.py's paths are): in from 30 pt
    /// short to 7 short and hold 0.6 s, through the target to 7 past and hold 0.6 s, away to 30 past.
    private func scripted(hz: Double) -> [CGFloat] {
        func ease(_ from: CGFloat, _ to: CGFloat, _ seconds: Double) -> [CGFloat] {
            let n = Int(seconds * hz)
            return (1...n).map { k in let u = Double(k) / Double(n); return from + (to - from) * CGFloat(1 - pow(1 - u, 3)) }
        }
        let hold = { (x: CGFloat) in Array(repeating: x, count: Int(0.6 * hz)) }
        return ease(target - 30, target - 7, 0.7) + hold(target - 7) + ease(target - 7, target + 7, 0.6) + hold(target + 7) + ease(target + 7, target + 30, 0.6)
    }

    /// What the ring shows of one feel over `scripted`: the lens's corner (the frame's right edge: the hand's point) and the middle of the ring's right edge
    /// (the frame's edge and the skin's bow) as they step from frame to frame, and the largest bow.
    private func ring(_ feel: LiveSnap.Feel, hz: Double, frames: Int? = nil) -> (corner: CGFloat, middle: CGFloat, bow: CGFloat) {
        var drag = Drag(feel, targets: targets, hz: hz)
        var skin = LensSkin(frame: CGRect(x: 100, y: 0, width: target - 30 - 100, height: 100))
        var lastCorner: CGFloat?, lastMiddle: CGFloat?, worst = (corner: CGFloat(0), middle: CGFloat(0), bow: CGFloat(0))
        for x in scripted(hz: hz).prefix(frames ?? .max) {
            let frame = CGRect(x: 100, y: 0, width: drag.frame(x).edge - 100, height: 100)
            skin.step(1 / hz, target: frame, hand: .corner)
            let outline = skin.outline(around: frame), middle = frame.maxX + outline.bows[LensSkin.Edge.maxX.rawValue]
            if let c = lastCorner, let m = lastMiddle { worst.corner = max(worst.corner, abs(frame.maxX - c)); worst.middle = max(worst.middle, abs(middle - m)) }
            worst.bow = max(worst.bow, abs(outline.bows[LensSkin.Edge.maxX.rawValue]))
            lastCorner = frame.maxX; lastMiddle = middle
        }
        return worst
    }

    @Test func theRingTakesTheInstantJumpInTheSkinAndTheDwellGlideSmoothly() {
        // 2026-10-23 (snap117, addendum A2): decision 16 was written before the organic outline existed; this is the jump as the ring shows it now. The hand
        // holds 7 pt off, the instant feel puts the corner 7 to 8 pt on in one frame; the skin's right edge is a spring that follows, so the ring's middle steps
        // by less (the bow, at most the hand's cap of 4 pt). The dwell feel moves the corner by the settle spring's own steps and the ring bows less.
        for hz in [60.0, 120.0] {
            let instant = ring(.instant, hz: hz), dwell = ring(.dwell, hz: hz)
            let capture = ring(.instant, hz: hz, frames: Int(1.3 * hz))                    // the approach and the first hold: the capture only
            print("measure: \(Int(hz)) Hz instant capture only: corner step \(String(format: "%.2f", capture.corner)) pt, ring middle step \(String(format: "%.2f", capture.middle)) pt")
            print("measure: \(Int(hz)) Hz instant corner step \(String(format: "%.2f", instant.corner)) pt, ring middle step \(String(format: "%.2f", instant.middle)) pt, bow \(String(format: "%.2f", instant.bow)) pt;"
                  + " dwell corner step \(String(format: "%.2f", dwell.corner)) pt, ring middle step \(String(format: "%.2f", dwell.middle)) pt, bow \(String(format: "%.2f", dwell.bow)) pt")
            // The largest step is the release (the edge goes from the target back under the hand: 12 pt and the hand's own step), the capture's is 8.
            #expect(instant.corner >= ColumnFit.reach && instant.corner <= ColumnFit.release + 1, "\(hz) Hz: the instant corner steps \(instant.corner)")
            #expect(instant.middle < instant.corner, "\(hz) Hz: the skin takes some of the jump: the middle steps \(instant.middle), the corner \(instant.corner)")
            #expect(instant.bow <= LensSkin.capHand + 1e-9 && dwell.bow <= LensSkin.capHand + 1e-9)
            #expect(dwell.corner <= 3, "\(hz) Hz: the dwell corner steps \(dwell.corner)")      // the taper's 1.5 pt per hand point at the script's pace, and the spring's own step
        }
    }

    // MARK: the glide after a release, Reduce Motion

    @Test func theGlideAfterAReleaseIsTheContractsQuickSpring() {
        // 2026-10-23 (skinland117, addendum A1, contract section 2): `settle` is the critically damped spring of response 2π / 30 s (stiffness 900, the block
        // correction's own), which `FitMotion.progress` runs for the time it takes to settle to 0.3 %: 8 · response / 2π = 8 / 30 s. It replaces fit117's
        // 0.12 s (ω = 66.7, 90 % in 58 ms), whose 7 pt glide read as a jump. The contract's 90 % is at 130 ms.
        let response = 2 * Double.pi / 30, settles = 8 * response / (2 * Double.pi)
        #expect(abs(LensMotion.settle - settles) < 1e-9, "settle is \(LensMotion.settle) s, the contract's is \(settles) s")
        #expect(FitMotion.progress(0.13, duration: LensMotion.settle) >= 0.9 && FitMotion.progress(0.129, duration: LensMotion.settle) < 0.9)
        for hz in [60.0, 120.0] {
            let frame = 1 / hz
            // It moves at once, no ease-in. Closed form 1 − (1 + x)e^(−x), x = ω · frame: 0.090 at 60 Hz (the contract's 0.63 pt of 7), 0.027 at 120 Hz:
            // a critically damped spring starts from rest, so a frame half as long covers a quarter of the way (the 0.05 of fit117 holds at 60 Hz only).
            let x = 30 * frame, first = FitMotion.progress(frame, duration: LensMotion.settle)
            #expect(abs(first - (1 - (1 + x) * exp(-x))) < 1e-9)
            #expect(first > (hz == 60 ? 0.05 : 0.02), "the first frame at \(hz) Hz is \(first) of the way")
            var last: CGFloat = 0
            var t = frame
            while t < LensMotion.settle {
                let p = FitMotion.progress(t, duration: LensMotion.settle)
                #expect(p >= last && p <= 1)
                last = p
                t += frame
            }
            // The first frame at or past the duration is the target itself (`RegionFrameWindow.animationFrame`), within one frame of 267 ms.
            #expect(t - LensMotion.settle < frame + 1e-9 && t <= LensMotion.settle + frame + 1e-9)
        }
    }

    @Test func underReduceMotionEveryMotionIsNoTimeAtAll() {
        for d in [LensMotion.fit, LensMotion.autoFit, LensMotion.settle, LensMotion.guideFade] {
            #expect(LensMotion.seconds(d, reduced: true) == 0 && LensMotion.seconds(d, reduced: false) == d)
        }
        #expect(FitMotion.progress(0, duration: 0) == 1)
    }

    @Test func theFitIsTheMotionContractsSpring() {
        // Addendum A9 (2026-10-22): `fit` is the contract's critically damped spring of response 0.30 s (/tmp/r117/motion117/motion-contract.md section 2);
        // `FitMotion.progress` is that curve with its duration the time it settles to 0.3 % of the target: 8 / ω = 8 · response / 2π = 0.382 s.
        let response = 0.30, settles = 8 * response / (2 * Double.pi)
        #expect(abs(LensMotion.fit - settles) < 1e-9, "fit is \(LensMotion.fit) s, the contract's is \(settles) s")
        #expect(abs(FitMotion.progress(response, duration: LensMotion.fit) - (1 - (1 + 2 * Double.pi) * exp(-2 * Double.pi))) < 1e-9)
    }

    @Test func autoFitIsTheContractsCalmSpringAndTheGuideFadeStaysShort() {
        // 2026-10-23 (skinland117, addendum A1, contract section 2 and 3.4): `autoFit` is the critically damped spring of response 0.50 s (SwiftUI's `.smooth`),
        // settling to 0.3 % in 8 · 0.50 / 2π = 0.637 s, 90 % by 310 ms (`1 − (1 + x)e^(−x) = 0.9` at x = 3.89, ω = 4π: 0.3095 s). It replaces 0.25 s,
        // which showed 12.3 pt in the first frame of a 122 pt growth that the person did not start; `calm` shows 2.3 pt.
        let response = 0.50, settles = 8 * response / (2 * Double.pi)
        #expect(abs(LensMotion.autoFit - settles) < 1e-9, "autoFit is \(LensMotion.autoFit) s, the contract's is \(settles) s")
        #expect(FitMotion.progress(0.31, duration: LensMotion.autoFit) >= 0.9 && FitMotion.progress(0.309, duration: LensMotion.autoFit) < 0.9)
        #expect(LensMotion.guideFade <= 0.25)
    }

    // MARK: Auto Fit never fires while the page scrolls or a hand is on the lens, and never twice for one settle

    private let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let page = ColumnFit.Column(left: 72, right: 398, top: 77, bottom: 966, blocks: 1, lines: 30, cores: [CGRect(x: 72, y: 300, width: 326, height: 300)])

    private struct Timeline {
        var gate = AutoFit.SettleGate()
        var machine = AutoFit.Machine(state: .armed)
        var lens = CGRect(x: 150, y: 320, width: 200, height: 150)
        var grows: [Double] = [], judged: [Int] = []
        var now = 0.0, lastMotion = -10.0, dragging = false, version = 0
        let page: ColumnFit.Column, display: CGRect

        /// One 50 ms tick: the session asks the gate, and on `judge` gives the table a `settled`; a growth lands at once.
        mutating func tick() {
            now += 0.05
            switch gate.check(version: version, now: now, lastMotion: lastMotion, calm: AutoFit.calmAfter, idle: true, dragging: dragging, onScreen: true) {
            case .no, .wait: return
            case .judge:
                judged.append(version)
                let (m, action) = AutoFit.step(machine, .settled(AutoFit.Context(calm: true, lens: lens, bounds: display, column: page)))
                machine = m
                if case .grow(let rect) = action {
                    grows.append(now)
                    lens = rect
                    machine = AutoFit.step(machine, .animationDone(AutoFit.Edges(left: page.left, right: page.right))).machine
                }
            }
        }
        mutating func run(_ seconds: Double, scrolling: Bool = false, snapshotEvery: Double = 0.3) {
            let end = now + seconds
            var nextSnapshot = now + snapshotEvery
            while now < end - 1e-9 {
                if scrolling { lastMotion = now }
                if now >= nextSnapshot { version += 1; nextSnapshot += snapshotEvery }
                tick()
            }
        }
    }

    @Test func autoFitWaitsForTheScrollToEndAndGrowsTheLensOnceForTheSettle() {
        var t = Timeline(page: page, display: display)
        t.version = 1
        t.run(3, scrolling: true)                      // the page scrolls for 3 s, snapshots every 0.3 s
        #expect(t.grows.isEmpty && t.judged.isEmpty, "judged during the scroll: \(t.judged), grew at \(t.grows)")
        t.run(2)                                       // 1 s after the last motion the settle counts; reads go on
        #expect(t.grows.count == 1, "grew \(t.grows.count) times: \(t.grows)")
        #expect(t.grows[0] >= 3 + AutoFit.calmAfter - 0.06, "grew at \(t.grows[0]), the scroll ended at 3")
        t.run(5)                                       // more snapshots, nothing changed: judged each once, grown none
        #expect(t.grows.count == 1 && Set(t.judged).count == t.judged.count, "judged \(t.judged), grew \(t.grows)")
        #expect(t.lens.width == 338)                   // 66...404
    }

    @Test func aHandOnTheLensNeverMeetsAJudgement() {
        var t = Timeline(page: page, display: display)
        t.version = 1
        t.dragging = true
        t.run(4)
        #expect(t.judged.isEmpty && t.grows.isEmpty)
        t.dragging = false                             // dropped: the next read is judged afresh (the session rearms the gate)
        t.gate.rearm()
        t.run(1.5)
        #expect(t.grows.count == 1)
    }
}

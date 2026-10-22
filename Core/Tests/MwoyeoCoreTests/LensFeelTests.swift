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

    /// The edge a live resize shows for a hand at `x`: the hand's, plus the pull of the nearest target from 12 pt in (`ColumnFit.livePull`), the way the
    /// session's `snapResized` does it.
    private func shown(_ x: CGFloat, targets: ColumnFit.Targets) -> CGFloat {
        let pull = ColumnFit.snap(CGRect(x: 100, y: 0, width: x - 100, height: 100), edges: .right, targets: targets, entry: ColumnFit.release)
        return x + (pull.map { ColumnFit.livePull($0.offset) } ?? 0)
    }

    @Test func theEdgeNeverJumpsUnderTheHandWhileItIsPulledOntoAColumnAndReleasedFromIt() {
        // A hand at 1 pt a frame (a slow drag), 4 (brisk) and 10 (a throw), right across the target and back: the edge the person sees moves at most 1.5
        // times as far as the hand does in every frame (the first build moved it 8.5 pt on entering and 12 pt on leaving, in one frame), and it stands on the
        // target while the hand is within the plateau.
        for step in [1.0, 4.0, 10.0] as [CGFloat] {
            var hand: CGFloat = 360, last = shown(hand, targets: targets), onTarget = 0, worst: CGFloat = 0
            for x in Array(stride(from: 360 + step, through: 450, by: step)) + Array(stride(from: 450 - step, through: 360, by: -step)) {
                let edge = shown(x, targets: targets)
                worst = max(worst, abs(edge - last) / abs(x - hand))
                if abs(x - target) <= ColumnFit.plateau - 0.01 { #expect(abs(edge - target) < 1e-9, "step \(step): hand at \(x), edge at \(edge)"); onTarget += 1 }
                last = edge; hand = x
            }
            #expect(worst <= 1.5 + 1e-9, "step \(step): the edge moved \(worst) times the hand's step in one frame")
            if step <= 4 { #expect(onTarget > 0) }
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

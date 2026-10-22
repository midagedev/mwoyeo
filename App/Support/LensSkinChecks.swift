#if !MAS
import AppKit
import MwoyeoCore

/// The membrane on the screen (motion contract section 9, round skinland117), run by `--capture-ui … check-logic` and alone as `skin-checks`. The Core
/// owner (`LensSkin`) has its own tests; these are about the wiring: the lens window's ring and the panel's clip are one outline on the same frame
/// (a rounded-rect clip is the mutant), every moment plays its row of `LensSkin.choreography` through the window, a lens that was only restored does
/// not take hold, Reduce Motion is the rigid ring, and the real display link plays a Fit. The clocks are the checks' own (the window's hooks take a
/// `dt`); the one run on the real link polls for its end with a bound and asserts nothing about how long it took.
@MainActor
enum LensSkinChecks {
    private static let frame = 1.0 / 60

    static func run() async -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ note: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") skin: \(what)" + (note().isEmpty ? "" : " [\(note())]"))
            if !ok { failed += 1 }
        }
        defer { Motion.shared.force(nil) }
        Motion.shared.force(false)
        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else {
            check("a display to put the lenses on", false)
            return failed
        }
        // Never shown: a window that is not on the screen has a display link that does not fire, so the clock is the check's.
        let base = CGPoint(x: screen.frame.minX + 120, y: screen.frame.minY + 160)
        func lens(_ r: CGRect, hold: CGPoint? = nil) -> (window: RegionFrameWindow, panel: OverlayPanel) {
            let w = RegionFrameWindow(region: r, name: "skin check"), p = OverlayPanel(frame: r)
            p.outline = { [weak w] in w?.outline() }
            w.onOutline = { [weak p] in p?.restyle() }
            if let hold { w.takeHold(at: hold) }
            w.contentView?.layoutSubtreeIfNeeded()
            p.slide(to: r)
            return (w, p)
        }
        /// The frames of an animation as `FrameChromeView` makes them: the skin steps towards `to` (the window's own frame once the animation is over, which the
        /// window system may have put half a point off it), the window goes where the spring has it, the panel's clip follows.
        func play(_ w: RegionFrameWindow, _ p: OverlayPanel, from: CGRect, to: CGRect, duration: TimeInterval, until: TimeInterval) {
            var t = 0.0, over = false
            while t < until - 1e-9 {
                t += frame
                let at = t >= duration ? to : FitMotion.frame(from: from, to: to, progress: FitMotion.progress(t, duration: duration))
                w.stepOutline(frame, toward: over ? w.regionFrame : to, to: at)
                p.slide(to: w.regionFrame)
                over = over || t >= duration
            }
        }
        /// What the window's outline has done since the moment began (`skin: fit peak=4.00 rest=344ms`): the moment, the peak bow in pt, the rest in ms.
        func meter(_ w: RegionFrameWindow) -> (moment: String, peak: Double, rest: Double) {
            let m = w.meter
            return (m.moment?.rawValue ?? "-", Double(m.peak), (m.restAt * 1000).rounded())
        }
        func close(_ got: Double, _ want: Double) -> Bool { abs(got - want) <= 0.1 * want + 1000 * frame }

        let rest = CGRect(x: base.x, y: base.y, width: 340, height: 200)

        // MARK: The ring and the clip are one outline
        let (rw, rp) = lens(rest)
        let atRest = Self.offsets(ring: Self.ring(rw), clip: Self.clip(rp))
        check("at rest the clip is the ring's outline, 1 pt inside it everywhere", atRest.low > 0.8 && atRest.high < 1.2 && rw.outline().isRigid,
              String(format: "%.2f..%.2f pt, bows %@", Double(atRest.low), Double(atRest.high), rw.stats()))
        // FAIL-first: the instrument names a clip that is still a rounded rect beside a bowed ring.
        let from = CGRect(x: base.x + 150, y: base.y, width: 175, height: 136), to = CGRect(x: base.x + 66.5, y: base.y, width: 336, height: 136)
        let (mw, mp) = lens(from)
        mw.beginOutline(.fit)
        play(mw, mp, from: from, to: to, duration: LensMotion.fit, until: 0.07)
        let mid = Self.offsets(ring: Self.ring(mw), clip: Self.clip(mp))
        let roundClip = CGPath(roundedRect: mw.regionFrame, cornerWidth: LensSkin.radius, cornerHeight: LensSkin.radius, transform: nil)
        let mutant = Self.offsets(ring: Self.ring(mw), clip: roundClip)
        check("FAIL-first: a rounded-rect clip beside the bowed ring is not 1 pt inside it", mutant.high > 1.2 || mutant.low < 0.8,
              String(format: "%.2f..%.2f pt", Double(mutant.low), Double(mutant.high)))
        check("mid-Fit (70 ms) the clip is the ring's outline, 1 pt inside it everywhere, and the outline is bowed", mid.low > 0.8 && mid.high < 1.2 && !mw.outline().isRigid,
              String(format: "%.2f..%.2f pt, %@", Double(mid.low), Double(mid.high), mw.stats()))

        // MARK: Each moment plays its row, through the window
        let glide = rest.offsetBy(dx: 7, dy: 0)   // a lens let go 7 pt off a column's edge glides onto it (the contract's example)
        let growing = CGRect(x: base.x + 66.5, y: base.y, width: 213.5, height: 136)   // Auto Fit's 122 pt growth
        func isRow(_ got: (moment: String, peak: Double, rest: Double), _ row: LensSkin.Row) -> Bool {
            got.moment == row.moment.rawValue && abs(got.peak - Double(row.peak)) <= 0.1 * Double(row.peak) + 0.05 && close(got.rest, Double(row.restMs))
        }
        let rows: [(LensSkin.Moment, CGRect, CGRect, TimeInterval)] = [
            (.fit, from, to, LensMotion.fit),
            (.undoFit, to, from, LensMotion.fit),
            (.autoFit, growing, to, LensMotion.autoFit),
            (.drop, rest, glide, LensMotion.settle),
        ]
        for (moment, a, b, duration) in rows {
            let (w, p) = lens(a)
            w.beginOutline(moment)
            play(w, p, from: a, to: b, duration: duration, until: 1.2)
            let row = LensSkin.choreography.first { $0.moment == moment }!, got = meter(w)
            check("\(row.label) through the window: peak \(String(format: "%.2f", got.peak)) pt, rest \(Int(got.rest)) ms (the table: \(row.peak), \(row.restMs))",
                  isRow(got, row), w.stats())
            check("\(row.label): the window ends on its target (within the half point the window system rounds to) and the outline is the rigid ring",
                  Self.near(w.regionFrame, b) && w.outline().isRigid && w.outline().frame.size == w.regionFrame.size, w.stats())
        }
        // FAIL-first (round skinland117, addendum A1, 2026-10-23): the durations fit117 had, a settle of 0.12 s and an Auto Fit of 0.25 s, are not their rows
        // (the 7 pt glide bowed 3.15 pt against 1.62; Auto Fit was at rest in 183 ms against 562).
        for (moment, a, b, old) in [(LensSkin.Moment.drop, rest, glide, 0.12), (.autoFit, growing, to, 0.25)] {
            let (w, p) = lens(a)
            w.beginOutline(moment)
            play(w, p, from: a, to: b, duration: old, until: 1.2)
            let row = LensSkin.choreography.first { $0.moment == moment }!, got = meter(w)
            check("FAIL-first: \(row.label) over \(old) s is not its row: peak \(String(format: "%.2f", got.peak)) pt, rest \(Int(got.rest)) ms (the table: \(row.peak), \(row.restMs))",
                  !isRow(got, row), w.stats())
        }

        // MARK: A lens that was only restored does not take hold; one the picker placed does
        let click = CGPoint(x: rest.minX + 20, y: rest.midY)
        let (qw, _) = lens(rest)
        let (hw, hp) = lens(rest, hold: click)
        check("FAIL-first: a lens the picker placed shows its outline grown at its first frame (the instrument sees \(String(format: "%.2f", Double(hw.outline().deviation))) pt)",
              hw.outline().deviation >= 3.5)
        check("a lens that was only restored does not take hold: its first frame is the rigid ring", qw.outline().isRigid && meter(qw).moment == "-", qw.stats())
        check("the pill comes in over 0.20 s: alpha 0 at the first frame", hw.introAlpha == 0, "\(hw.introAlpha)")
        for _ in 0..<6 { hw.stepOutline(frame, toward: hw.regionFrame); hp.slide(to: hw.regionFrame) }
        check("the pill is half in at 0.10 s", abs(hw.introAlpha - 0.5) < 0.01, String(format: "%.3f", Double(hw.introAlpha)))
        for _ in 0..<40 { hw.stepOutline(frame, toward: hw.regionFrame); hp.slide(to: hw.regionFrame) }
        let held = LensSkin.choreography.first { $0.moment == .commit }!, took = meter(hw)
        check("the commit through the window: peak \(String(format: "%.2f", took.peak)) pt, rest \(Int(took.rest)) ms (the table: \(held.peak), \(held.restMs)); the pill is in",
              took.moment == "commit" && abs(took.peak - Double(held.peak)) <= 0.1 * Double(held.peak) + 0.05 && close(took.rest, Double(held.restMs)) && hw.introAlpha == 1,
              hw.stats())
        let afterHold = Self.offsets(ring: Self.ring(hw), clip: Self.clip(hp))
        check("after the hold the ring and the clip are the rigid outline again, 1 pt apart", hw.outline().isRigid && afterHold.low > 0.8 && afterHold.high < 1.2,
              String(format: "%.2f..%.2f pt", Double(afterHold.low), Double(afterHold.high)))

        // MARK: A frame nobody animated puts the outline at rest; Reduce Motion is the rigid ring
        let (sw, sp) = lens(from)
        sw.beginOutline(.fit)
        play(sw, sp, from: from, to: to, duration: LensMotion.fit, until: 0.07)
        let driven = sw.outline()
        sw.driveRegion(rest.offsetBy(dx: 300, dy: 80))
        let stale = sw.outline()
        sw.setRegion(rest.offsetBy(dx: 300, dy: 80))
        check("FAIL-first: a frame a gesture drives leaves the outline bowed (\(String(format: "%.2f", Double(stale.deviation))) pt); `setRegion` puts it at rest",
              !driven.isRigid && stale.deviation > 1 && sw.outline().isRigid && sw.outline().deviation == 0, sw.stats())
        Motion.shared.force(true)
        let (xw, xp) = lens(from)
        xw.beginOutline(.fit)
        play(xw, xp, from: from, to: to, duration: LensMotion.fit, until: 0.07)
        let reduced = Self.offsets(ring: Self.ring(xw), clip: Self.clip(xp))
        check("under Reduce Motion the outline is the rigid ring through a Fit, and the clip is 1 pt inside it", xw.outline().isRigid && reduced.low > 0.8 && reduced.high < 1.2,
              String(format: "%.2f..%.2f pt, %@", Double(reduced.low), Double(reduced.high), xw.stats()))
        let (gw, _) = lens(rest, hold: click)
        Motion.shared.force(false)
        check("under Reduce Motion a lens the picker placed shows no grown outline", gw.outline().isRigid, gw.stats())

        // MARK: The real display link plays a Fit
        let shown = lens(CGRect(x: base.x, y: base.y + 260, width: 175, height: 136))
        shown.window.alphaValue = 0
        shown.window.ignoresMouseEvents = true
        shown.window.orderFrontRegardless()
        let goal = CGRect(x: base.x - 83, y: base.y + 260, width: 336, height: 136)
        var finished: Bool?
        shown.window.animate(to: goal, duration: LensMotion.fit, moment: .fit) { finished = $0 }
        let animating = shown.window.isAnimating
        for _ in 0..<600 where finished == nil || !shown.window.outline().isRigid || !meter(shown.window).moment.hasPrefix("fit") {
            try? await Task.sleep(for: .milliseconds(10))
        }
        shown.window.orderOut(nil)
        let live = meter(shown.window)
        check("the real display link plays a Fit: the window lands on its target, the outline is the rigid ring again and the meter says fit (peak \(String(format: "%.2f", live.peak)) pt)",
              animating && finished == true && Self.near(shown.window.regionFrame, goal) && shown.window.outline().isRigid && live.moment == "fit" && live.peak > 1 && live.peak <= 4.05,
              shown.window.stats())
        return failed
    }

    // MARK: - The instrument

    private static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 0.51 && abs(a.minY - b.minY) <= 0.51 && abs(a.width - b.width) <= 0.51 && abs(a.height - b.height) <= 0.51
    }

    /// The ring's mask path in screen coordinates (y up): the lens window's view coordinates are its window's.
    private static func ring(_ w: RegionFrameWindow) -> CGPath {
        var t = CGAffineTransform(translationX: w.frame.minX, y: w.frame.minY)
        return w.ringPath?.copy(using: &t) ?? CGMutablePath()
    }

    /// The panel's clip as the layers place it, in screen coordinates (y up).
    private static func clip(_ p: OverlayPanel) -> CGPath { p.clipOutlineOnScreen() ?? CGMutablePath() }

    /// How far the ring is from the clip: the nearest and the farthest distance from a sample on either to the other. The ring is the outline 1 pt out, so
    /// both are 1 where they are one outline.
    private static func offsets(ring: CGPath, clip: CGPath) -> (low: CGFloat, high: CGFloat) {
        let a = polyline(ring), b = polyline(clip)
        guard !a.isEmpty, !b.isEmpty else { return (-1, 99) }
        let d = a.map { distance($0, b) } + b.map { distance($0, a) }
        return (d.min() ?? -1, d.max() ?? 99)
    }

    private static func polyline(_ path: CGPath) -> [CGPoint] {
        var pts: [CGPoint] = [], cur = CGPoint.zero
        path.applyWithBlock { e in
            let p = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint, .addLineToPoint:
                cur = p[0]
                pts.append(cur)
            case .addCurveToPoint:
                let a = cur, b = p[0], c = p[1], d = p[2]
                for k in 1...16 {
                    let s = CGFloat(k) / 16, u = 1 - s
                    pts.append(CGPoint(x: u * u * u * a.x + 3 * u * u * s * b.x + 3 * u * s * s * c.x + s * s * s * d.x,
                                       y: u * u * u * a.y + 3 * u * u * s * b.y + 3 * u * s * s * c.y + s * s * s * d.y))
                }
                cur = d
            default:
                break
            }
        }
        return pts
    }

    private static func distance(_ p: CGPoint, _ line: [CGPoint]) -> CGFloat {
        var best = CGFloat.infinity
        for i in line.indices {
            let a = line[i], b = line[(i + 1) % line.count], dx = b.x - a.x, dy = b.y - a.y, l = dx * dx + dy * dy
            let u = l > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l)) : 0
            best = min(best, hypot(a.x + u * dx - p.x, a.y + u * dy - p.y))
        }
        return best
    }
}
#endif

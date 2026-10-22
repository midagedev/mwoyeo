#if !MAS
import AppKit
import MwoyeoCore

/// The checks of the lens's fit (round fit117, docs/design/lens-fit.md section 12), run by `--capture-ui … check-logic` or alone as `fit-checks`
/// (PASS/FAIL lines): Fit to Column on a two-column page yields the column's width within ±3 pt (the measured error of the reader's column edges is
/// at most 2.1 pt) and takes the old rect back; a lens over nothing with columns (a chat) does not snap or fit; a resize snaps to the column's right
/// edge within 8 pt and lets go at 12; ⌘ and the setting turn the snap off; Auto Fit grows a lens once, never shrinks it, turns off at a manual resize
/// and comes back on another column; a column the capture cut is read wider once first; Reduce Motion makes the fit one frame; the menu row and
/// VoiceOver's action are the double-click's equivalents; the two settings round-trip with their strict validation.
///
/// Lenses are real sessions on a fake capture, on one laptop display of the checks' own. The page is geometry: each paragraph's lines are
/// the union of block cores at the true column edges (the right one 1.3 pt wide, the bias measured on the paper bench), cut to the capture the way
/// the pipeline's would be, and handed to the session as a snapshot. What the reader makes of a drawn page is the paper bench's and the live lens's.
@MainActor
enum FitChecks {
    /// The page: two columns of text, and the display it is on.
    static let left = (x0: 100.0, x1: 430.0), right = (x0: 470.0, x1: 800.0)
    static let display = LensRobustChecks.laptop

    static func run(_ model: AppModel) async -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") fit: \(what)" + (ok ? "" : " [\(detail())]"))
            if !ok { failed += 1 }
        }
        Motion.shared.force(true)
        defer { Motion.shared.force(nil) }

        var version = 1000          // above the pipeline's own count: its empty first snapshots, which come late, do not replace these
        /// Blocks of a column: paragraphs of 6, 8 and 7 lines at the true edges, the right edge as the reader draws it (1.3 pt wide).
        func blocks(_ c: (x0: Double, x1: Double)) -> [ColumnFit.Block] {
            [(120.0, 6), (230.0, 8), (360.0, 7)].map { y, lines in
                ColumnFit.Block(core: CGRect(x: c.x0 + 0.3, y: y, width: c.x1 - c.x0 + 1.0, height: Double(lines) * 14), lines: lines)
            }
        }
        /// What a capture of `capture` (global points) holds of the page: blocks cut to it, their columns, as a snapshot. `seen`: the part of the capture
        /// the blocks were read from (the pipeline's `readRect`): a capture that has just grown holds blocks that stop where the old read did.
        func snapshot(_ capture: CGRect, seen: CGRect? = nil, columns wanted: [(x0: Double, x1: Double)] = [left, right], oneLine: Bool = false) -> OverlaySnapshot {
            version += 1
            let read = seen ?? capture
            var cut: [ColumnFit.Block] = []
            for b in wanted.flatMap(blocks) {
                let x0 = max(b.core.minX, read.minX), x1 = min(b.core.maxX, read.maxX), y0 = max(b.core.minY, read.minY), y1 = min(b.core.maxY, read.maxY)
                guard x1 - x0 >= 8, y1 - y0 >= 4 else { continue }
                cut.append(ColumnFit.Block(core: CGRect(x: x0 - capture.minX, y: y0 - capture.minY, width: x1 - x0, height: y1 - y0), lines: oneLine ? 1 : b.lines))
            }
            return OverlaySnapshot(version: version, blocks: [], animated: false, origin: capture.origin, columns: ColumnFit.columns(cut), captureSize: capture.size,
                                   read: read.offsetBy(dx: -capture.minX, dy: -capture.minY))
        }
        let wholePage = CGRect(x: 40, y: 80, width: 820, height: 520)

        func lens(_ rect: CGRect, autoFit: Bool = false, settings: AppSettings = AppSettings()) async -> RegionSession {
            var config = RegionConfig(name: "Paper", rect: rect)
            config.autoFit = autoFit
            let s = RegionSession(config: config, settings: settings, translator: model.translator, inpainter: nil, capturer: FakeCapture(), recovery: LensRobustChecks.fast)
            s.layoutProvider = { LensRobustChecks.undocked }
            s.appUnderLens = { _ in nil }
            s.fit.calm = -1            // content has stood still long enough at once: the checks wait for no clock (the table's rows are `AutoFitTests`')
            s.fit.commandDown = { false }       // not the machine's keyboard: another round's driver may hold ⌘ down while a check runs (10-22 15:2x, five snap checks FAILED on it)
            await s.start()
            return s
        }
        func frame(_ s: RegionSession) -> NSRect { ScreenGeometry.appKitRect(fromQuartz: s.config.rect) }
        func window(_ s: RegionSession) -> RegionFrameWindow? { s.lensWindow as? RegionFrameWindow }
        func menuTitles(_ s: RegionSession) -> [String] { s.contextMenu().items.map(\.title) }
        func fitRow(_ s: RegionSession) -> NSMenuItem? { s.contextMenu().items.first { $0.title == String(localized: "Fit to Column") || $0.title == String(localized: "Undo Fit") } }
        let pad = Double(ColumnFit.pad)
        func width(_ s: RegionSession) -> Double { Double(s.config.rect.width) - 2 * pad }

        // MARK: Fit to Column

        let narrow = CGRect(x: 130, y: 200, width: 270, height: 180)           // 30 pt in from the column on each side
        let a = await lens(narrow)
        a.received(snapshot(wholePage))
        let before = a.config.rect
        var saved = 0
        a.onConfigChange = { _ in saved += 1 }
        _ = Trace.takeCounts()
        a.fitToColumn()
        var c = Trace.takeCounts()
        check("Fit to Column on a two-column page: the lens's width less its pads is the column's, within ±3 pt (\(width(a)) against 330)",
              abs(width(a) - 330) <= 3 && abs(a.config.rect.minX - (left.x0 - pad)) <= 3, "\(a.config.rect)")
        check("its top and height stay, and it is saved", a.config.rect.minY == before.minY && a.config.rect.height == before.height && saved >= 1, "\(a.config.rect) saved \(saved)")
        check("it is counted (lens.fit.manual), and the lens now has an Undo Fit", c["lens.fit.manual"] == 1 && fitRow(a)?.title == String(localized: "Undo Fit") && fitRow(a)?.isEnabled == true, "\(c) \(menuTitles(a))")
        a.fitToColumn()
        check("a second Fit to Column takes the old rect back exactly", a.config.rect == before && fitRow(a)?.title == String(localized: "Fit to Column"), "\(a.config.rect)")

        // Fit to Column is a menu row, a screen reader's action, and the ring's double-click (`DoubleTap`, Core): all one function.
        let actions = window(a)?.contentView?.accessibilityCustomActions() ?? []
        let fitAction = actions.first { $0.name == String(localized: "Fit to Column") }
        _ = fitAction?.handler?()
        check("VoiceOver offers Fit to Column as an action of the lens, and it fits", fitAction != nil && abs(width(a) - 330) <= 3, "\(actions.map(\.name)) \(a.config.rect)")
        let undoAction = window(a)?.contentView?.accessibilityCustomActions()?.first { $0.name == String(localized: "Undo Fit") }
        _ = undoAction?.handler?()
        check("and names it Undo Fit while the old rect is held, which takes the rect back", undoAction != nil && a.config.rect == before, "\(a.config.rect)")
        let menu = a.contextMenu()
        if let at = menu.items.firstIndex(where: { $0.title == String(localized: "Fit to Column") }) { menu.performActionForItem(at: at) }
        check("the menu row presses (what AXPress on a menu item does) and does what the double-click does", abs(width(a) - 330) <= 3 && fitRow(a)?.title == String(localized: "Undo Fit"), "\(a.config.rect)")

        // A lens over the right column, wider than it: the fit takes it in.
        let b = await lens(CGRect(x: 440, y: 200, width: 400, height: 180))
        b.received(snapshot(wholePage))
        b.fitToColumn()
        check("a lens wider than the right column is fitted to it too (within ±3 pt, left edge on the column's)", abs(width(b) - 330) <= 3 && abs(b.config.rect.minX - (right.x0 - pad)) <= 3, "\(b.config.rect)")

        // The display clamps: a column that runs past the display's edge.
        let d = await lens(CGRect(x: 1200, y: 200, width: 200, height: 180))
        d.received(snapshot(CGRect(x: 900, y: 80, width: 612, height: 520), columns: [(x0: 1180.0, x1: 1600.0)]))
        d.fitToColumn()
        check("a column running past the display's edge: the lens takes the edge", d.config.rect.maxX == display.maxX && d.config.rect.minX <= 1180 - pad + 3, "\(d.config.rect)")

        // MARK: nothing with columns: a chat

        let chat = await lens(narrow)
        chat.received(snapshot(wholePage, oneLine: true))
        let chatRect = chat.config.rect
        chat.fitToColumn()
        check("a lens over a chat (one-line blocks, no column): Fit to Column changes nothing", chat.config.rect == chatRect, "\(chat.config.rect)")
        check("the menu row is disabled and says why", fitRow(chat)?.isEnabled == false && fitRow(chat)?.toolTip == String(localized: "Move the lens over one column of text."),
              "\(String(describing: fitRow(chat)?.toolTip))")
        let chatSnap = window(chat)?.onSnapResize?(frame(chat).insetBy(dx: 0, dy: 0))
        check("it does not snap", chatSnap == frame(chat) && chat.fit.targets.isEmpty)
        let chatAuto = await lens(narrow, autoFit: true)
        chatAuto.received(snapshot(wholePage, oneLine: true))
        check("and Auto Fit does nothing over it", chatAuto.config.rect == narrow, "\(chatAuto.config.rect)")

        // Across the gutter: ambiguous, so nothing.
        let gutter = await lens(CGRect(x: 340, y: 200, width: 180, height: 180))
        gutter.received(snapshot(wholePage))
        let gutterRect = gutter.config.rect
        gutter.fitToColumn()
        check("a lens across the gutter: no column under it, nothing changes", gutter.config.rect == gutterRect && fitRow(gutter)?.isEnabled == false)

        // A snapshot that is older than the content's last motion, or does not hold the lens, says nothing yet.
        let st = await lens(narrow)
        st.received(snapshot(wholePage))
        st.fit.contentMovedAt = ProcessInfo.processInfo.systemUptime + 1
        check("a snapshot older than the content's last motion is not trusted: the row is disabled and says Reading…",
              fitRow(st)?.isEnabled == false && fitRow(st)?.toolTip == String(localized: "Reading…"), "\(String(describing: fitRow(st)?.toolTip))")
        st.fit.contentMovedAt = 0
        st.received(snapshot(CGRect(x: 600, y: 80, width: 260, height: 520)))
        check("nor is one that does not hold the lens (it was dragged away, the next read is not in yet)",
              fitRow(st)?.isEnabled == false && fitRow(st)?.toolTip == String(localized: "Reading…"), "\(String(describing: fitRow(st)?.toolTip))")
        st.received(snapshot(wholePage))
        check("a newer one that holds the lens is", fitRow(st)?.isEnabled == true)

        // MARK: Snap on resize

        let r = await lens(narrow)
        r.received(snapshot(wholePage))
        let onResize = window(r)?.onSnapResize
        func resized(toRight x: Double) -> NSRect { var f = frame(r); f.size.width = x - narrow.minX; return f }
        let edge = left.x1 + 1.3 + pad      // the right edge a lens snaps to: the column's, 1.3 pt wide as read, and the pad
        func maxX(_ f: NSRect?) -> Double? { f.map { ScreenGeometry.quartzRect(fromAppKit: $0).maxX } }
        _ = Trace.takeCounts()
        let near = onResize?(resized(toRight: edge - 3))
        c = Trace.takeCounts()
        check("a resize 3 pt short of the column's edge (within the plateau) puts the lens's edge on it (right edge \(edge))", maxX(near).map { abs($0 - edge) < 0.01 } == true && c["lens.snap.enter"] == 1,
              "\(String(describing: near)) \(c)")
        let pulled = onResize?(resized(toRight: edge - 5))
        check("5 pt short it is pulled 3.5 pt of the way: the pull tapers, the edge does not jump under the hand", maxX(pulled).map { abs($0 - (edge - 1.5)) < 0.01 } == true, "\(String(describing: maxX(pulled)))")
        let held = onResize?(resized(toRight: edge - 11.5))
        check("11.5 pt short the pull is a quarter of a point and the guide is still up (hysteresis)", maxX(held).map { abs($0 - (edge - 11.25)) < 0.01 } == true && r.fit.snap != nil, "\(String(describing: maxX(held)))")
        let free = onResize?(resized(toRight: edge - 12.5))
        check("and beyond 12 pt there is none, and the guide is down", free == resized(toRight: edge - 12.5) && r.fit.snap == nil, "\(String(describing: free))")
        let far = onResize?(resized(toRight: edge - 20))
        check("20 pt away it was never caught", far == resized(toRight: edge - 20))
        // A hand moving 1 pt at a time from 16 pt short to the edge: the lens's edge moves between 0 and 1.5 pt in a step, never more (no pop on entering).
        var worst = 0.0, lastShown = 0.0
        for k in stride(from: 16.0, through: 0.0, by: -1.0) {
            let x = maxX(onResize?(resized(toRight: edge - k))) ?? 0
            if k < 16 { worst = max(worst, abs(x - lastShown)) }
            lastShown = x
        }
        check("a hand moving 1 pt at a time from 16 pt short onto the edge: the lens's edge never moves more than 1.5 pt in a step (worst \(worst))", worst <= 1.5 + 1e-9 && abs(lastShown - edge) < 0.01)
        let letGo = onResize?(resized(toRight: edge - 6))
        let rest = letGo.flatMap { window(r)?.onSettleResize?($0) }
        check("let go 6 pt short (the guide up), the lens glides the rest of the way onto the edge", maxX(rest).map { abs($0 - edge) < 0.01 } == true && r.fit.settling, "\(String(describing: maxX(rest)))")
        window(r)?.onCommit?()
        check("and the snap is over once it is dropped", r.fit.snap == nil && !r.fit.settling)
        r.fit.commandDown = { true }
        let command = onResize?(resized(toRight: edge - 3))
        check("with ⌘ held a resize does not snap", command == resized(toRight: edge - 3))
        r.fit.commandDown = { false }
        var off = AppSettings()
        off.lensSnap = false
        let o = await lens(narrow, settings: off)
        o.received(snapshot(wholePage))
        let offSnap = window(o)?.onSnapResize?(resized(toRight: edge - 3))
        check("and with Snap to text columns off it does not either", offSnap == resized(toRight: edge - 3))

        // MARK: Snap on a move: the guide, the tick once, the settle

        let m = await lens(CGRect(x: 99, y: 200, width: 250, height: 180))    // its left edge 4.7 pt from where a lens on the left column's edge stands (94.3)
        m.received(snapshot(wholePage))
        _ = Trace.takeCounts()
        let moves = (0..<4).map { i in frame(m).offsetBy(dx: Double(i) * 0.5, dy: 0) }
        for f in moves { window(m)?.onMove?(f) }
        c = Trace.takeCounts()
        check("a move onto a column's edge shows the guide and ticks once, however many frames it stays in reach", c["lens.snap.enter"] == 1 && m.fit.snap != nil, "\(c) \(String(describing: m.fit.snap))")
        let settled = window(m)?.onSettle?(moves[3])
        check("let go there, the lens settles on the edge (the left edge at \(left.x0 - pad))",
              settled.map { abs(ScreenGeometry.quartzRect(fromAppKit: $0).minX - (left.x0 + 0.3 - pad)) < 0.01 } == true, "\(String(describing: settled))")
        window(m)?.onCommit?()
        check("and the snap is over once it is dropped", m.fit.snap == nil && !m.fit.settling)
        let mc = await lens(CGRect(x: 99, y: 200, width: 250, height: 180))
        mc.received(snapshot(wholePage))
        mc.fit.commandDown = { true }
        _ = Trace.takeCounts()
        window(mc)?.onMove?(frame(mc))
        c = Trace.takeCounts()
        check("with ⌘ held a move has no guide, no tick and no settle", c["lens.snap.enter"] == nil && window(mc)?.onSettle?(frame(mc)) == nil)

        // MARK: Auto Fit

        let auto = await lens(narrow, autoFit: true)
        _ = Trace.takeCounts()
        auto.received(snapshot(wholePage))
        c = Trace.takeCounts()
        let grown = auto.config.rect
        check("Auto Fit: a settle that finds the column cut by both edges grows the lens to it (within ±3 pt)", abs(width(auto) - 330) <= 3 && c["lens.fit.auto"] == 1, "\(grown) \(c)")
        auto.received(snapshot(wholePage))
        check("a second settle on the same column does nothing", auto.config.rect == grown && Trace.takeCounts()["lens.fit.auto"] == nil)
        window(auto)?.onResize?(NSRect(x: frame(auto).minX, y: frame(auto).minY, width: frame(auto).width - 40, height: frame(auto).height))
        check("a manual resize turns Auto Fit off for this lens (config.autoFit false, the machine off)", !auto.config.autoFit && auto.fit.machine.state == .off, "\(auto.config.autoFit) \(auto.fit.machine.state)")
        window(auto)?.onCommit?()
        auto.received(snapshot(wholePage))
        check("and it stays off", Trace.takeCounts()["lens.fit.auto"] == nil)
        auto.setAutoFit(true)
        check("turned on again by the menu row, it judges what it reads (the lens narrowed by hand is grown again)", auto.config.autoFit && abs(width(auto) - 330) <= 3, "\(auto.config.rect)")
        let autoRow = auto.contextMenu().items.first { $0.title == String(localized: "Auto Fit") }
        check("the menu's Auto Fit row has its checkmark", autoRow?.state == .on)

        // Dropped on the other column: armed again there.
        let right2 = CGRect(x: 520, y: 200, width: 200, height: 180)
        window(auto)?.onMove?(ScreenGeometry.appKitRect(fromQuartz: right2))
        window(auto)?.onCommit?()
        auto.received(snapshot(wholePage))
        check("a drag onto the other column re-arms it there: the lens grows to that column", abs(width(auto) - 330) <= 3 && abs(auto.config.rect.minX - (right.x0 - pad)) <= 3, "\(auto.config.rect)")

        // Never shrinks.
        let wide = await lens(CGRect(x: 60, y: 200, width: 400, height: 180), autoFit: true)    // 60...460 holds the column (100...431) and stops short of the next (470)
        wide.received(snapshot(wholePage))
        check("Auto Fit never shrinks: a lens wider than its column stays", wide.config.rect == CGRect(x: 60, y: 200, width: 400, height: 180), "\(wide.config.rect)")
        let half = await lens(CGRect(x: 60, y: 200, width: 300, height: 180), autoFit: true)    // cuts the column on the right only: the left stays
        half.received(snapshot(wholePage))
        check("a lens that cuts the column on one side only grows that side only", half.config.rect.minX == 60 && abs(half.config.rect.maxX - (left.x1 + 1.3 + pad)) <= 3, "\(half.config.rect)")

        // MARK: A column the capture cut: one wider read first

        let p = await lens(CGRect(x: 180, y: 200, width: 100, height: 180))      // 0.3 of the column
        let cutCapture = CGRect(x: 150, y: 80, width: 260, height: 520)           // the capture ends inside the column on both sides
        p.received(snapshot(cutCapture))
        let probed = p.config.rect
        _ = Trace.takeCounts()
        p.fitToColumn()
        c = Trace.takeCounts()
        let band = Overscan.band(around: p.config.rect, display: display)
        check("a column the capture cut has unknown edges: Fit to Column reads wider first (the capture is the band) and has not moved the lens",
              c["lens.fit.probe"] == 1 && p.fit.band != nil && p.captureRect == band && p.config.rect == probed && p.fit.probe != nil, "\(c) \(p.captureRect) \(band)")
        // film4 F4/F5 (2026-10-22): the capture grew to the band and the pipeline's first snapshot of it still held the blocks of the old read, which stop at the
        // old capture's edge: that is not the probe's answer, and its edge is no snap target.
        p.received(snapshot(band, seen: cutCapture))
        let cutRight = Double(cutCapture.maxX) + pad
        check("the snapshot the grown capture sends before its read (blocks of the old read) is not the probe's answer: the lens stays, the probe waits",
              p.fit.probe != nil && p.fit.band != nil && p.config.rect == probed, "\(p.config.rect) probe \(String(describing: p.fit.probe))")
        check("and the edge the old read ended at is no snap target (the capture is wide now, the edge is still where the read stopped)",
              p.fit.targets.rights.allSatisfy { abs(Double($0.x) - cutRight) > 1 }, "\(p.fit.targets.rights.map(\.x))")
        p.received(snapshot(band))
        check("the next snapshot, read from the band, fits it (within ±3 pt) and the capture goes back to its usual shape",
              abs(width(p) - 330) <= 3 && p.fit.band == nil && p.fit.probe == nil && p.captureRect != band && p.captureRect.width < display.width, "\(p.config.rect) \(p.captureRect)")
        let ap = await lens(CGRect(x: 120, y: 200, width: 200, height: 180), autoFit: true)
        _ = Trace.takeCounts()
        ap.received(snapshot(CGRect(x: 90, y: 80, width: 300, height: 520)))     // ends at 390, inside the column: the right edge is unknown
        c = Trace.takeCounts()
        check("Auto Fit over a cut column probes first too, and does not guess", c["lens.fit.probe"] == 1 && ap.fit.band != nil && ap.config.rect.width == 200, "\(c) \(ap.config.rect)")
        ap.received(snapshot(Overscan.band(around: ap.config.rect, display: display)))
        check("then grows to the column from the band's snapshot", abs(width(ap) - 330) <= 3 && ap.fit.band == nil, "\(ap.config.rect)")

        // MARK: Snap on a resize needs the edge ahead of the corner: one read of the band at the drag's start (film4 F4)

        let sc = await lens(CGRect(x: 180, y: 200, width: 100, height: 180))
        sc.received(snapshot(cutCapture))
        func widened(_ s: RegionSession, toRight x: Double) -> NSRect { var f = frame(s); f.size.width = x - s.config.rect.minX; return f }
        let rightEdge = left.x1 + 1.3 + pad
        _ = Trace.takeCounts()
        window(sc)?.onResize?(widened(sc, toRight: 300))
        let scBand = Overscan.band(around: sc.config.rect, display: display)      // the band of the lens as the first frame left it
        c = Trace.takeCounts()
        check("a hand begins to resize a lens next to a column the read cut: the capture becomes the band for one read (a scout), and the lens is the hand's",
              c["lens.fit.scout"] == 1 && sc.fit.probe?.reason == .scout && sc.captureRect == scBand && sc.config.rect.maxX == 300, "\(c) \(sc.captureRect) \(scBand) \(sc.config.rect)")
        window(sc)?.onResize?(widened(sc, toRight: 340))
        check("the capture stays that band while the lens grows under the hand (a band that followed it would end every read)", sc.captureRect == scBand, "\(sc.captureRect)")
        sc.received(snapshot(scBand, seen: cutCapture))
        let stale = window(sc)?.onSnapResize?(widened(sc, toRight: Double(cutCapture.maxX) + pad - 3))
        check("until the band is read the edge the old read ended at pulls nothing (3 pt from it)", stale == widened(sc, toRight: Double(cutCapture.maxX) + pad - 3), "\(String(describing: stale))")
        sc.received(snapshot(scBand))
        let scouted = window(sc)?.onSnapResize?(widened(sc, toRight: rightEdge - 3))
        check("then the real edge does (3 pt short of the column's right edge lands on it)", scouted.map { abs(ScreenGeometry.quartzRect(fromAppKit: $0).maxX - rightEdge) < 0.01 } == true, "\(String(describing: scouted)) \(rightEdge)")
        check("and the scout is done: nothing waits, the band stays until the drop", sc.fit.probe == nil && sc.captureRect == scBand)
        window(sc)?.onCommit?()
        check("the drop gives the capture its usual shape again", sc.fit.band == nil && sc.captureRect != scBand && sc.captureRect.width < display.width, "\(sc.captureRect)")
        let sa = await lens(CGRect(x: 180, y: 200, width: 100, height: 180), settings: off)
        sa.received(snapshot(cutCapture))
        _ = Trace.takeCounts()
        window(sa)?.onResize?(widened(sa, toRight: 300))
        check("with Snap to text columns off a resize reads nothing more", Trace.takeCounts()["lens.fit.scout"] == nil && sa.fit.band == nil)
        let sw = await lens(narrow)
        sw.received(snapshot(wholePage))
        _ = Trace.takeCounts()
        window(sw)?.onResize?(widened(sw, toRight: 420))
        check("and where the column is read whole there is nothing to scout for", Trace.takeCounts()["lens.fit.scout"] == nil && sw.fit.band == nil)

        // MARK: A hand on the lens: no fit moves the edge it holds

        let hd = await lens(narrow)
        hd.received(snapshot(wholePage))
        window(hd)?.onMove?(frame(hd))
        let held0 = hd.config.rect
        hd.fitToColumn()
        check("Fit to Column does nothing while a hand holds the lens", hd.config.rect == held0 && !hd.fit.animating, "\(hd.config.rect)")
        let ha = await lens(narrow, autoFit: true)
        window(ha)?.onMove?(frame(ha))
        ha.received(snapshot(wholePage))
        check("Auto Fit does not judge while a hand holds the lens", ha.config.rect == narrow && Trace.takeCounts()["lens.fit.auto"] == nil, "\(ha.config.rect)")
        Motion.shared.force(false)
        let hm = await lens(narrow)
        hm.received(snapshot(wholePage))
        hm.fitToColumn()
        window(hm)?.stopAnimating()
        check("a hand pressing the lens stops a fit where it has got to (nothing jumps to the target)", !hm.fit.animating && hm.config.rect.width < 336 && hm.config.rect.width >= narrow.width, "\(hm.config.rect)")
        window(hm)?.onCommit?()
        Motion.shared.force(true)

        // MARK: Reduce Motion

        Motion.shared.force(false)
        let mo = await lens(narrow)
        mo.received(snapshot(wholePage))
        mo.fitToColumn()
        let animating = window(mo)?.isAnimating == true
        var waited = 0
        while mo.fit.animating, waited < 400 { try? await Task.sleep(for: .milliseconds(10)); waited += 1 }
        check("with Reduce Motion off the fit animates (the lens is still moving right after the call) and ends on the column", animating && !mo.fit.animating && abs(width(mo) - 330) <= 3,
              "animating \(animating) \(mo.config.rect)")
        Motion.shared.force(true)
        let rm = await lens(narrow)
        rm.received(snapshot(wholePage))
        rm.fitToColumn()
        check("with Reduce Motion on the fit is one frame: no animation is left running when the call returns", window(rm)?.isAnimating == false && !rm.fit.animating && abs(width(rm) - 330) <= 3)

        // MARK: Settings

        var on = AppSettings()
        on.lensSnap = false
        on.lensAutoFit = true
        let text = String(decoding: SettingsFileFormat.render(on), as: UTF8.self)
        let back = SettingsFileCheck.read(SettingsFileFormat.render(on), over: AppSettings())
        check("lensSnap and lensAutoFit: defaults true and false, written to the file, and round-trip", AppSettings().lensSnap && !AppSettings().lensAutoFit
              && text.contains("\"lensSnap\": false") && text.contains("\"lensAutoFit\": true") && back.settings == on && back.issues.isEmpty, text)
        let wrong = SettingsFileCheck.read(Data("{\n  \"lensSnap\": \"no\",\n  \"lensAutoFit\": 3\n}\n".utf8), over: on)
        check("a wrong type is reported with its line and keeps the current value",
              wrong.issues == [SettingsFileIssue(line: 2, message: "lensSnap: expected true or false, got a string; keeping the current value"),
                               SettingsFileIssue(line: 3, message: "lensAutoFit: expected true or false, got a number; keeping the current value")]
              && !wrong.settings.lensSnap && wrong.settings.lensAutoFit, "\(wrong.issues)")
        check("both are in the schema with their docs, and in the Appearance tab as preferences",
              SettingSpec.spec(for: "lensSnap")?.tab == .appearance && SettingSpec.spec(for: "lensAutoFit")?.nature == .preference
              && (SettingSpec.spec(for: "lensSnap")?.doc.contains("⌘") ?? false), "\(String(describing: SettingSpec.spec(for: "lensSnap")))")
        var config = RegionConfig(name: "x", rect: narrow)
        config.autoFit = true
        let roundTrip = (try? JSONEncoder().encode(config)).flatMap { try? JSONDecoder().decode(RegionConfig.self, from: $0) }
        let old = (try? JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "name": "x", "rect": [[1, 2], [3, 4]], "isEnabled": true] as [String: Any]))
            .flatMap { try? JSONDecoder().decode(RegionConfig.self, from: $0) }
        check("a lens keeps its own Auto Fit, and a lens saved before it was there reads as off", roundTrip?.autoFit == true && old?.autoFit == false, "\(String(describing: roundTrip)) \(String(describing: old))")

        for s in [a, b, d, chat, chatAuto, gutter, st, r, o, m, mc, auto, wide, half, p, ap, mo, rm] { await s.stop() }
        return failed
    }
}
#endif

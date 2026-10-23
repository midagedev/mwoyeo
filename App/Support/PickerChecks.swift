#if !MAS
import AppKit
import CoreText
import MwoyeoCore

/// The one-click picker's checks (docs/design/first-lens.md section 7, gates 3 to 8), run by `--capture-ui … check-logic` and alone as
/// `picker-checks` (PASS/FAIL lines). A page drawn with CoreText and read by the real reader stands in for the display; the delivery of the
/// map, the clock of the glide and Reduce Motion are the checks' own, so nothing here waits on a wall clock but the reader's answer (polled
/// with a bound).
@MainActor
enum PickerChecks {
    /// How long a poll waits for the reader to answer: a bound for a reader that never gets there, not a wait.
    private static let bound = 60.0
    /// The page stands at the top left of the main display: two columns of justified text, 340 pt wide with a 48 pt gutter.
    static let columns: [(CGFloat, CGFloat)] = [(60, 400), (448, 788)]
    static let pageSize = CGSize(width: 840, height: 900)

    static func run(_ model: AppModel) async -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ note: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") picker: \(what)" + (ok ? "" : note().isEmpty ? "" : " [\(note())]"))
            if !ok { failed += 1 }
        }
        defer { Motion.shared.force(nil) }
        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else {
            check("a display to place the picker on", false)
            return failed
        }
        // Gate 8: the map is read only while a picker is up; this process launched as the app does and opened none.
        check("no map read at launch: picker.map.read = 0 before any picker (\(RegionPicker.stats.reads))", RegionPicker.stats.reads == 0)

        let display = CGRect(origin: .zero, size: pageSize)
        let twoColumns = drawPage(paragraphs: true)
        let read = try? await PickerMap.read(twoColumns.image, scale: 2, display: display, languages: [])
        let map = read?.0
        check("the drawn page reads as two reading columns (\(map?.readingColumns ?? -1), \(map?.blocks ?? -1) blocks, language \(read?.1 ?? "none"))",
              map?.readingColumns == 2)
        guard let map else { return failed }

        /// A picker view of the main display with `reader`, hosted in a window nobody sees, its glide on the check's clock.
        var now = CACurrentMediaTime()
        var placed: RegionPicker.Result??
        func picker(_ reader: PickerMap.Reader?) -> (PickerView, NSWindow) {
            placed = nil
            let view = PickerView(screen: screen, windows: [], readMap: reader) { placed = .some($0) }
            view.clock = { now }
            let host = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.alphaValue = 0
            host.ignoresMouseEvents = true
            host.contentView = view
            host.orderFront(nil)
            return (view, host)
        }
        func ready(_ view: PickerView) async -> Bool {
            let end = Date().addingTimeInterval(bound)
            while Date() < end {
                if case .ready = view.map { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }
        /// A point of the page (y down) in the view's coordinates.
        func at(_ p: CGPoint) -> NSPoint { NSPoint(x: p.x, y: screen.frame.height - p.y) }
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: at(p), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        func click(_ view: PickerView, _ p: CGPoint) {
            view.mouseMoved(with: event(.mouseMoved, p))
            view.mouseDown(with: event(.leftMouseDown, p))
            view.mouseUp(with: event(.leftMouseUp, p))
        }
        /// The default lens a click at `p` drops with no target: the default size centred on the click, inside the display (no window).
        func ghost(_ p: CGPoint) -> CGRect {
            let r = LensTarget.ghost(at: at(p), window: nil, in: NSRect(origin: .zero, size: screen.frame.size))
            return ScreenGeometry.quartzRect(fromAppKit: r.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY))
        }
        let instant: PickerMap.Reader = { _ in map }

        // MARK: Gate 3: hover, then click, places the column's lens
        let (view, host) = picker(instant)
        view.startMap()
        let mapped = await ready(view)
        check("the picker's map arrives from its reader", mapped)
        for (i, column) in columns.enumerated() {
            let paragraph = twoColumns.paragraphs[i][1]
            let p = CGPoint(x: (column.0 + column.1) / 2, y: paragraph.midY)
            click(view, p)
            let r = placed.flatMap { $0 }?.rect ?? .zero
            let members = map.columns.flatMap(\.members).map(\.core)
            let left = r.minX - (column.0 - 6), right = r.maxX - (column.1 + 6)
            check("column \(i + 1): a click places the column ± 6 pt within 3 pt (left \(fmt(left)), right \(fmt(right)), width − 12 = \(fmt(r.width - 12)) for \(fmt(column.1 - column.0)))",
                  abs(left) <= 3 && abs(right) <= 3)
            // 2026-10-23 (film5, 27f22ab "padded rows"): the target's top and bottom stand `ColumnFit.pad` off the lines' boxes, as its sides do (the boxes are
            // the glyphs' own, and an outline on them cut a two-line message's ascenders). Derivation: the blocks' edges are the lines' boxes, so each edge is
            // `pad` (6) away, within the 2 pt the check held before; the paragraph's ink top is the lens's top plus `pad`, within the 4 pt it held. FAIL-first: on
            // this build before the re-pin the old terms read 6.0, 6.2 and 6.1, 5.9 (FAIL), and an unpadded target reads 0 here, 6 off (FAIL).
            let pad = ColumnFit.pad
            let top = members.map { abs($0.minY - r.minY) }.min() ?? .infinity, bottom = members.map { abs($0.maxY - r.maxY) }.min() ?? .infinity
            check("column \(i + 1): its top and bottom stand `pad` off the read blocks' edges within 2 pt (\(fmt(top)), \(fmt(bottom)) for \(fmt(pad)))",
                  abs(top - pad) <= 2 && abs(bottom - pad) <= 2)
            check("column \(i + 1): its top is the hovered paragraph's, padded (drawn ink \(fmt(paragraph.minY)), lens \(fmt(r.minY)) + \(fmt(pad)))", abs(r.minY + pad - paragraph.minY) <= 4)
            // Gate 6: Return with the pointer over the target places the same lens, the click's keyboard twin.
            let (keys, keysHost) = picker(instant)
            keys.startMap()
            _ = await ready(keys)
            keys.mouseMoved(with: event(.mouseMoved, p))
            keys.handle(.confirm)
            check("column \(i + 1): Return over the target places what the click placed", placed.flatMap { $0 }?.rect == r && keys.placement == nil)
            keysHost.orderOut(nil)
        }
        check("the clicks were counted as targets (\(RegionPicker.stats.clickTarget))", RegionPicker.stats.clickTarget >= 2)

        // The trackpad's tick as the spotlight takes a target's shape (user 2026-10-23: "피커 붙을때도"): one per new target, none while the pointer stays on
        // it, none within `tickGap` of the last (a sweep across a page does not buzz). FAIL-first: before the tick, picker.tick stayed 0 for the three hops.
        do {
            func ticks() -> Int { let c = Trace.takeCounts(); for (k, n) in c { Trace.count(k, n) }; return c["picker.tick", default: 0] }
            let (tv, tHost) = picker(instant)
            tv.startMap()
            _ = await ready(tv)
            let points = columns.enumerated().map { i, c in CGPoint(x: (c.0 + c.1) / 2, y: twoColumns.paragraphs[i][1].midY) }
            let start = ticks()
            now += 1; tv.mouseMoved(with: event(.mouseMoved, points[0]))
            let first = ticks() - start
            tv.mouseMoved(with: event(.mouseMoved, CGPoint(x: points[0].x + 4, y: points[0].y + 3)))
            let stay = ticks() - start - first
            now += 0.05; tv.mouseMoved(with: event(.mouseMoved, points[1]))
            let quick = ticks() - start - first - stay
            now += 1; tv.mouseMoved(with: event(.mouseMoved, points[0]))
            let back = ticks() - start - first - stay - quick
            check("the spotlight ticks once on a new target (\(first)), not while the pointer stays on it (\(stay)), not 50 ms after a tick (\(quick)), and again on the next target after (\(back))",
                  first == 1 && stay == 0 && quick == 0 && back == 1)
            tHost.orderOut(nil)
        }

        // A pointer that rests where the picker opens (film defect F22, 2026-10-23, addendum A2 of skinland117): `open()` aims at it where it is, so the first map aims
        // at once. The pointer is the check's own (`mouseLocation`): the real one is not ours to move.
        let resting = CGPoint(x: (columns[0].0 + columns[0].1) / 2, y: twoColumns.paragraphs[0][1].midY)
        let restingAt = NSPoint(x: screen.frame.minX + at(resting).x, y: screen.frame.minY + at(resting).y)
        let (blind, blindHost) = picker(instant)
        blind.mouseLocation = { restingAt }
        blind.startMap()   // main's open: the read only, the pointer known from a move alone
        _ = await ready(blind)
        check("FAIL-first: with the read alone a resting pointer gets no outline when the map arrives (target \(blind.target != nil), spotlight \(blind.spotlight != nil))",
              blind.target == nil && blind.spotlight == nil)
        blind.close()
        blindHost.orderOut(nil)
        let (opened, openedHost) = picker(instant)
        opened.mouseLocation = { restingAt }
        opened.ghostGrace = 0   // 2026-10-23 picktarget117: the default lens waits for the read (`LensTarget.ghostGrace`); this gate injects no wait, its claim is unchanged
        opened.open()
        check("a picker opened over a resting pointer shows the default lens under it at once, before any map", opened.spotlight != nil && opened.target == nil)
        _ = await ready(opened)
        now += 1
        opened.render(at: now)
        let aimedAt = opened.target.map { ScreenGeometry.appKitRect(fromQuartz: $0.rect).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
        check("and when the map arrives, with no move of the pointer, the spotlight is the paragraph's lens", aimedAt != nil && opened.spotlight == aimedAt)
        opened.close()
        openedHost.orderOut(nil)

        // On a chat the click drops today's default lens.
        let chat = drawPage(paragraphs: false)
        let chatMap = (try? await PickerMap.read(chat.image, scale: 2, display: display, languages: []))?.0
        check("the drawn chat has no reading column (\(chatMap?.readingColumns ?? -1), \(chatMap?.blocks ?? -1) blocks)", chatMap?.readingColumns == 0 && (chatMap?.blocks ?? 0) >= 6)
        let (chatView, chatHost) = picker { _ in chatMap }
        chatView.startMap()
        try? await Task.sleep(for: .milliseconds(50))
        let message = chat.paragraphs[0][2]
        click(chatView, CGPoint(x: message.midX, y: message.midY))
        check("on the chat a click drops the default lens, byte for byte", placed.flatMap { $0 }?.rect == ghost(CGPoint(x: message.midX, y: message.midY)))
        chatHost.orderOut(nil)

        // A click before the map is there drops the default lens; the map that comes after it changes nothing.
        final class Later: @unchecked Sendable { var deliver: CheckedContinuation<LensTarget.Map?, Never>? }
        let later = Later()
        let (late, lateHost) = picker { _ in await withCheckedContinuation { c in later.deliver = c } }
        late.startMap()
        let early = CGPoint(x: 230, y: twoColumns.paragraphs[0][1].midY)
        click(late, early)
        check("a click before the map arrives drops the default lens", placed.flatMap { $0 }?.rect == ghost(early))
        try? await Task.sleep(for: .milliseconds(20))
        later.deliver?.resume(returning: map)
        late.close()
        lateHost.orderOut(nil)

        // MARK: Gate 4: the read is off the main thread; a map that never comes leaves the picker as it always was
        let (stuck, stuckHost) = picker { _ in try? await Task.sleep(for: .seconds(3600)); return nil }
        stuck.ghostGrace = 0   // this gate is about the picker opening at once; the grace has its own gate below
        let t = CACurrentMediaTime()
        stuck.startMap()
        let started = CACurrentMediaTime() - t
        stuck.mouseMoved(with: event(.mouseMoved, early))
        let drawsBefore = PickerView.draws
        stuckHost.display()
        CATransaction.flush()   // the pills draw through their layers, at the commit
        check("with a read that never answers the picker opens at once (startMap \(fmt(started * 1000)) ms) and draws its hint and label (\(PickerView.draws - drawsBefore) draws)",
              started < 0.05 && PickerView.draws > drawsBefore && stuck.spotlight != nil)

        // MARK: Round picktarget117 (2026-10-23): while the read is young the spotlight is nothing; the first target opens from the pointer
        // The film4 take showed the default lens (the window's content, not the page's) over Preview's dark margin for the 532 ms of the read,
        // then gliding into the first target. The grace and the clock are the check's own; nothing here waits on a wall clock.
        final class Deliver: @unchecked Sendable { var map: CheckedContinuation<LensTarget.Map?, Never>? }
        let deliver = Deliver()
        let (young, youngHost) = picker { _ in await withCheckedContinuation { c in deliver.map = c } }
        young.startMap()
        young.mouseMoved(with: event(.mouseMoved, early))
        check("while the read is young the spotlight is nothing, not the default lens (\(young.spotlight.map { "\($0)" } ?? "none"))",
              young.spotlight == nil && !young.gliding)
        check("and the picker is to look again when the grace ends (\(young.recheckIn.map { fmt($0) } ?? "none") s of \(fmt(LensTarget.ghostGrace)))",
              young.recheckIn.map { $0 > 0 && $0 <= LensTarget.ghostGrace } == true)
        click(young, early)
        check("a click in that time still drops the default lens", placed.flatMap { $0 }?.rect == ghost(early))
        now += LensTarget.ghostGrace + 0.01
        young.mouseMoved(with: event(.mouseMoved, early))
        young.render(at: now + 1)   // it opens from the pointer: a frame after its spring
        check("once the read has taken its grace the default lens shows (\(young.spotlight.map { "\(Int($0.width)) x \(Int($0.height))" } ?? "none"))",
              young.spotlight.map { $0.width <= KeyboardLens.defaultSize.width && $0.height <= KeyboardLens.defaultSize.height && $0.width > 100 } == true
              && young.recheckIn == nil)
        young.close()
        youngHost.orderOut(nil)

        let deliverFirst = Deliver()
        let (fresh, freshHost) = picker { _ in await withCheckedContinuation { c in deliverFirst.map = c } }
        fresh.startMap()
        fresh.mouseMoved(with: event(.mouseMoved, early))
        try? await Task.sleep(for: .milliseconds(20))
        deliverFirst.map?.resume(returning: map)
        let freshReady = await ready(fresh)
        let opening = fresh.spotlight
        let finalRect = fresh.target.map { ScreenGeometry.appKitRect(fromQuartz: $0.rect).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
        let pointerAt = at(early)
        check("the map arrives while nothing shows, and the first target is a square at the pointer (\(opening.map { "\($0)" } ?? "none"))",
              freshReady && opening.map { $0.width == LensTarget.seedSide && $0.height == LensTarget.seedSide
                                         && abs($0.midX - pointerAt.x) < 0.5 && abs($0.midY - pointerAt.y) < 0.5 } == true && fresh.gliding)
        var inside = true, growing = true, previous = opening ?? .zero
        for f in 1...20 {
            fresh.render(at: now + Double(f) / 60)
            guard let r = fresh.spotlight, let end = finalRect else { inside = false; break }
            inside = inside && end.insetBy(dx: -0.01, dy: -0.01).contains(r)
            growing = growing && r.width >= previous.width - 0.01 && r.height >= previous.height - 0.01
            previous = r
        }
        // 2026-10-23 (film5): the last frame within 0.01 pt of the target, the tolerance `inside` holds every frame to. Derivation: with the padded target
        // (27f22ab) the last frame read x 52.999999995 of 53.0, a float's residue of the spring, not a frame short; FAIL-first: exact equality failed on it.
        check("it opens on the glide's spring to the target and every frame stays inside it (\(fmt(previous.width)) x \(fmt(previous.height)) of \(finalRect.map { "\(fmt($0.width)) x \(fmt($0.height))" } ?? "none"))",
              inside && growing && finalRect.map { e in [previous.minX - e.minX, previous.minY - e.minY, previous.width - e.width, previous.height - e.height].allSatisfy { abs($0) < 0.01 } } == true, "inside \(inside) growing \(growing) last \(previous) target \(finalRect.map { "\($0)" } ?? "none")")
        fresh.close()
        freshHost.orderOut(nil)

        Motion.shared.force(true)
        let deliverReduced = Deliver()
        let (still, stillHost) = picker { _ in await withCheckedContinuation { c in deliverReduced.map = c } }
        still.startMap()
        still.mouseMoved(with: event(.mouseMoved, early))
        try? await Task.sleep(for: .milliseconds(20))
        deliverReduced.map?.resume(returning: map)
        let stillReady = await ready(still)
        check("under Reduce Motion the first target is there at once", stillReady && !still.gliding
              && still.spotlight == still.target.map { ScreenGeometry.appKitRect(fromQuartz: $0.rect).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) })
        Motion.shared.force(nil)
        still.close()
        stillHost.orderOut(nil)

        // Where nothing is to wait for, the default lens is there at once: no reader, and a read that gave nothing.
        let (unread, unreadHost) = picker(nil)
        unread.mouseMoved(with: event(.mouseMoved, early))
        check("with no reader the default lens shows at once", unread.spotlight != nil && unread.recheckIn == nil)
        unread.close()
        unreadHost.orderOut(nil)
        let (empty, emptyHost) = picker { _ in nil }
        empty.startMap()
        empty.mouseMoved(with: event(.mouseMoved, early))
        let emptyEnd = Date().addingTimeInterval(bound)
        while empty.spotlight == nil, Date() < emptyEnd { try? await Task.sleep(for: .milliseconds(10)) }
        check("a read that gave nothing shows the default lens at once", empty.spotlight != nil && empty.recheckIn == nil)
        empty.close()
        emptyHost.orderOut(nil)

        // A2 (the skinland117 take): the pointer below the window, over the Dock, has no target; over the window the target stays inside it.
        // The window ends just under the first paragraph of the first column; the second and third paragraphs below it stand for the Dock's blocks.
        let paragraphs = twoColumns.paragraphs[0]
        let windowBounds = CGRect(x: 0, y: 0, width: pageSize.width, height: paragraphs[0].maxY + 10)
        let listed = WindowInfo(id: 1, pid: 1, appName: "Preview", title: "", bounds: windowBounds, isOnScreen: true)
        let (windowed, windowedHost) = { () -> (PickerView, NSWindow) in
            let view = PickerView(screen: screen, windows: [listed], readMap: instant) { _ in }
            view.clock = { now }
            view.ghostGrace = 0
            let host = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.alphaValue = 0
            host.ignoresMouseEvents = true
            host.contentView = view
            host.orderFront(nil)
            return (view, host)
        }()
        windowed.startMap()
        _ = await ready(windowed)
        windowed.mouseMoved(with: event(.mouseMoved, CGPoint(x: 230, y: paragraphs[0].midY)))
        let onWindow = windowed.target?.rect
        check("over the window the target stays inside it (\(onWindow.map { "\($0)" } ?? "none") in \(windowBounds))",
              onWindow.map { windowBounds.contains($0) } == true)
        windowed.mouseMoved(with: event(.mouseMoved, CGPoint(x: 230, y: paragraphs[2].midY)))
        check("below the window, over no window, there is no target (\(windowed.target.map { "\($0.rect)" } ?? "none"))", windowed.target == nil)
        windowed.close()
        windowedHost.orderOut(nil)

        // MARK: Gate 8: one read per picker, cancelled with it; no picture kept
        let readsBefore = RegionPicker.stats.reads
        for _ in 0..<3 { stuck.startMap(); stuck.mouseMoved(with: event(.mouseMoved, early)) }
        check("one picker open reads its map once (\(RegionPicker.stats.reads - readsBefore + 1) reads)", RegionPicker.stats.reads == readsBefore)
        final class Seen: @unchecked Sendable { var cancelled = false; weak var picture: CGImage? }
        let seen = Seen()
        let (closing, closingHost) = picker { display in
            let picture = drawPage(paragraphs: true).image
            seen.picture = picture
            let found = try? await PickerMap.read(picture, scale: 2, display: display, languages: [])
            do { try await Task.sleep(for: .seconds(3600)) } catch { seen.cancelled = true }
            return found?.0
        }
        closing.startMap()
        let end = Date().addingTimeInterval(bound)
        while seen.picture == nil, Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(200))
        closing.close()
        stuck.close()
        let end2 = Date().addingTimeInterval(2)
        while !(seen.cancelled && seen.picture == nil), Date() < end2 { try? await Task.sleep(for: .milliseconds(10)) }
        check("closing the picker cancels its read (the reader saw the cancellation)", seen.cancelled)
        check("and no picture of the display outlives it", seen.picture == nil)
        closingHost.orderOut(nil)
        stuckHost.orderOut(nil)

        // MARK: Gate 5: the spotlight glides on layers; 30 frames of a glide draw nothing
        let a = CGPoint(x: 230, y: twoColumns.paragraphs[0][1].midY), b = CGPoint(x: 618, y: twoColumns.paragraphs[1][2].midY)
        view.mouseMoved(with: event(.mouseMoved, a))
        now += 1
        view.render(at: now)
        host.display()
        CATransaction.flush()
        let first = view.spotlight
        let control = PickerView.draws
        view.mouseMoved(with: event(.mouseMoved, b))
        CATransaction.flush()
        let drawn = PickerView.draws
        var frames: [CGRect] = []
        var bows: [CGFloat] = []
        // 2026-10-23 (skinland117): 40 frames, not 30. The outline bows over the hop and is back on the rigid rect within 0.48 s of it (contract 9.6, "hop 2"),
        // so the spotlight is the target's rect itself from frame 30 on, not at frame 18 where the glide itself lands; the property asserted is the same.
        for f in 1...40 {
            view.render(at: now + Double(f) / 60)
            host.displayIfNeeded()
            CATransaction.flush()   // each frame committed as the display link's would be: a draw it causes is counted in its frame
            if let s = view.spotlight { frames.append(s) }
            bows.append(view.spotlightDeviation)
        }
        let target = view.target.map { ScreenGeometry.appKitRect(fromQuartz: $0.rect).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
        check("the hosted picker draws (control: \(control) draws so far)", control > 0)
        check("40 frames of a glide between two targets: \(PickerView.draws - drawn) draws of the picker's views, \(view.runningAnimations) layer animations",
              PickerView.draws == drawn && view.runningAnimations == 0)
        check("the spotlight moved over them and came to rest on the target (\(frames.count) frames, \(Set(frames.map { "\($0)" }).count) distinct)",
              frames.count == 40 && Set(frames.map { "\($0)" }).count > 10 && first != frames.last && target.map { frames.last?.insetBy(dx: 0, dy: 0) == $0 } == true)
        let hopPeak = bows.max() ?? 0
        check("the spotlight's outline bows over the hop (\(String(format: "%.2f", Double(hopPeak))) pt, at most the 4 pt cap) and is the rigid rect again by the end (\(String(format: "%.2f", Double(bows.last ?? -1))) pt)",
              hopPeak > 1 && hopPeak <= 4.05 && (bows.last ?? 1) < LensSkin.restDistance)

        // MARK: Gate 7: Reduce Motion: the spotlight jumps; the click is the same
        Motion.shared.force(true)
        now += 1
        view.mouseMoved(with: event(.mouseMoved, a))
        let jumped = view.spotlight
        check("under Reduce Motion the spotlight jumps to the target (no glide, \(view.runningAnimations) animations)",
              !view.gliding && view.runningAnimations == 0 && jumped == view.target.map { ScreenGeometry.appKitRect(fromQuartz: $0.rect).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) })
        check("and its outline is the rigid rect (\(String(format: "%.2f", Double(view.spotlightDeviation))) pt; with motion the same hop bowed \(String(format: "%.2f", Double(hopPeak))) pt)",
              view.spotlightDeviation == 0 && hopPeak > 1)
        click(view, a)
        let reduced = placed.flatMap { $0 }?.rect
        Motion.shared.force(false)
        click(view, a)
        check("and a click places the same lens as with motion", reduced != nil && reduced == placed.flatMap { $0 }?.rect)
        Motion.shared.force(nil)
        view.close()
        host.orderOut(nil)
        // The accessibility words stay today's.
        check("the picker's accessibility help and value are unchanged",
              view.accessibilityHelp() == String(localized: "Drag an area or click  ·  ⌥ pins to the screen  ·  esc to cancel")
              && view.accessibilityValue() as? String == String(localized: "Or press an arrow key to place it with the keyboard"))
        return failed
    }

    private static func fmt(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }
    private static func fmt(_ v: Double) -> String { String(format: "%.1f", v) }

    private static let prose = [
        "The lens reads the text under it and draws the translation in its place, line by line, so that the page keeps its shape.",
        "A column of a paper is read from the lines of its paragraphs: the left edges of the blocks stand together, and the right edge is the furthest.",
        "When the picker opens, one read of the display finds the columns, and the outline under the pointer takes the width of the column.",
        "A click places the lens that the outline shows, and the first translation arrives a moment later, without a drag or a resize.",
        "Where there is no column, as in a chat or a game, the picker shows the lens of the default size, centred on the pointer, as before.",
    ]

    private static let chatLines = [
        "anyone up for the raid tonight", "count me in", "see you all at nine then", "did they fix the double jump bug",
        "yes finally", "patch notes are out", "great news everyone", "bring snacks",
    ]

    /// A page of `pageSize` at scale 2, white: two columns of justified paragraphs (`paragraphs`), or a chat of one-line messages on alternating
    /// sides. Returns the picture and the ink of each paragraph or message per column (page points, y down).
    nonisolated static func drawPage(paragraphs: Bool) -> (image: CGImage, paragraphs: [[CGRect]]) {
        let scale: CGFloat = 2, size = pageSize
        let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let font = CTFontCreateWithName("Helvetica" as CFString, paragraphs ? 13 : 15, nil)
        var out: [[CGRect]] = []
        func set(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, justified: Bool) -> CGRect {
            let style = NSMutableParagraphStyle()
            style.alignment = justified ? .justified : .left
            style.lineSpacing = 3
            let s = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: style, .foregroundColor: NSColor(white: 0.1, alpha: 1)])
            let setter = CTFramesetterCreateWithAttributedString(s)
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: width, height: 10_000), nil)
            let box = CGRect(x: x, y: size.height - y - ceil(fit.height), width: width, height: ceil(fit.height))
            let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: box, transform: nil), nil)
            CTFrameDraw(frame, ctx)
            let lines = CTFrameGetLines(frame) as! [CTLine]
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            CTFrameGetLineOrigins(frame, CFRange(), &origins)
            var ink = CGRect.null
            for (line, o) in zip(lines, origins) {
                ctx.textPosition = .zero   // the image bounds are relative to the context's text position, which drawing moved
                let b = CTLineGetImageBounds(line, ctx)
                ink = ink.union(CGRect(x: box.minX + o.x + b.minX, y: box.minY + o.y + b.minY, width: b.width, height: b.height))
            }
            return CGRect(x: ink.minX, y: size.height - ink.maxY, width: ink.width, height: ink.height)
        }
        if paragraphs {
            for (i, c) in columns.enumerated() {
                var y: CGFloat = i == 0 ? 80 : 60, inks: [CGRect] = []
                for k in 0..<5 {
                    let text = (0..<2).map { prose[(k + $0 + i) % prose.count] }.joined(separator: " ")
                    let ink = set(text, x: c.0, y: y, width: c.1 - c.0, justified: true)
                    inks.append(ink)
                    y = ink.maxY + 18
                }
                out.append(inks)
            }
        } else {
            var y: CGFloat = 70, inks: [CGRect] = []
            for (k, line) in chatLines.enumerated() {
                let x: CGFloat = k % 2 == 0 ? 60 : 520 - CGFloat(line.count) * 4
                inks.append(set(line, x: x, y: y, width: 400, justified: false))
                y += 64
            }
            out.append(inks)
        }
        return (ctx.makeImage()!, out)
    }
}
#endif

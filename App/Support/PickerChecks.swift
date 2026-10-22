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
            let top = members.map { abs($0.minY - r.minY) }.min() ?? .infinity, bottom = members.map { abs($0.maxY - r.maxY) }.min() ?? .infinity
            check("column \(i + 1): its top and bottom stand on the read blocks' edges within 2 pt (\(fmt(top)), \(fmt(bottom)))", top <= 2 && bottom <= 2)
            check("column \(i + 1): its top is the hovered paragraph's (drawn ink \(fmt(paragraph.minY)), lens \(fmt(r.minY)))", abs(r.minY - paragraph.minY) <= 4)
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
        let t = CACurrentMediaTime()
        stuck.startMap()
        let started = CACurrentMediaTime() - t
        stuck.mouseMoved(with: event(.mouseMoved, early))
        let drawsBefore = PickerView.draws
        stuckHost.display()
        CATransaction.flush()   // the pills draw through their layers, at the commit
        check("with a read that never answers the picker opens at once (startMap \(fmt(started * 1000)) ms) and draws its hint and label (\(PickerView.draws - drawsBefore) draws)",
              started < 0.05 && PickerView.draws > drawsBefore && stuck.spotlight != nil)

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
        for f in 1...30 {
            view.render(at: now + Double(f) / 60)
            host.displayIfNeeded()
            CATransaction.flush()   // each frame committed as the display link's would be: a draw it causes is counted in its frame
            if let s = view.spotlight { frames.append(s) }
        }
        let target = view.target.map { ScreenGeometry.appKitRect(fromQuartz: $0.rect).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
        check("the hosted picker draws (control: \(control) draws so far)", control > 0)
        check("30 frames of a glide between two targets: \(PickerView.draws - drawn) draws of the picker's views, \(view.runningAnimations) layer animations",
              PickerView.draws == drawn && view.runningAnimations == 0)
        check("the spotlight moved over them and came to rest on the target (\(frames.count) frames, \(Set(frames.map { "\($0)" }).count) distinct)",
              frames.count == 30 && Set(frames.map { "\($0)" }).count > 10 && first != frames.last && target.map { frames.last?.insetBy(dx: 0, dy: 0) == $0 } == true)

        // MARK: Gate 7: Reduce Motion: the spotlight jumps; the click is the same
        Motion.shared.force(true)
        now += 1
        view.mouseMoved(with: event(.mouseMoved, a))
        let jumped = view.spotlight
        check("under Reduce Motion the spotlight jumps to the target (no glide, \(view.runningAnimations) animations)",
              !view.gliding && view.runningAnimations == 0 && jumped == view.target.map { ScreenGeometry.appKitRect(fromQuartz: $0.rect).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) })
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

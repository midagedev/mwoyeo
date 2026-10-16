import CoreGraphics
import Foundation
import ImageIO
import MwoyeoCore
import os

/// One captured frame of a region.
struct CapturedFrame: @unchecked Sendable {
    let image: CGImage
    /// Downsampled luma for change detection; one gray pixel covers `grayStep`×`grayStep` image pixels.
    let gray: GrayImage
    let grayStep: Int
    /// Image pixels per point.
    let scale: CGFloat
    /// The captured rect, global Quartz points.
    let rect: CGRect
    /// `ProcessInfo.systemUptime` at capture.
    let time: TimeInterval
}

/// A translated block ready to show: region-local frame in points (top-left origin) and its rendered image.
struct OverlayBlock: Identifiable, @unchecked Sendable {
    let id: UUID
    var frame: CGRect
    var image: CGImage
    var seamless: Bool
}

struct OverlaySnapshot: @unchecked Sendable {
    let version: Int
    let blocks: [OverlayBlock]
    let animated: Bool
    /// Capture origin (global Quartz points) the block frames are relative to. The capture is wider than the visible
    /// lens, so blocks may lie outside the overlay; the overlay offsets them by its own origin and clips the rest.
    let origin: CGPoint
    /// Capture time of the newest frame the block positions follow; scrolling after it is the overlay's to predict.
    var time: TimeInterval = 0
}

/// Content scrolled by `shift` points (positive = down) in `area` (global Quartz points) between frames captured at
/// `from` and `to`.
struct ScrollReport: Sendable {
    let area: CGRect
    let shift: CGFloat
    let from: TimeInterval
    let to: TimeInterval
}

enum RegionActivity: Sendable, Equatable {
    case idle, reading, translating
}

struct PipelineOptions: Sendable, Equatable {
    var renderMode: RenderMode
    var settleDelay: TimeInterval
    var useInpainting: Bool
    var fontStyle: FontStyleChoice
    var boxOpacity: Double
    var sourceLanguage: String
    var targetLanguage: String
    var glossaryTerms: [String]

    init(_ s: AppSettings) {
        renderMode = s.renderMode
        settleDelay = s.settleDelay
        useInpainting = s.useInpaintingModel
        fontStyle = s.fontStyle
        boxOpacity = s.boxOpacity
        sourceLanguage = s.sourceLanguage
        targetLanguage = s.targetLanguage
        glossaryTerms = s.glossaryPairs.map(\.0)
    }
}

/// Turns a stream of frames into overlay snapshots.
///
/// The capture covers more than the visible lens ("overscan"), so text next to the lens is already read, erased and
/// translated by the time a drag or scroll brings it into view.
///
/// - While content moves: re-read only the changed band (tile diff), show translations on plain boxes
///   ("fast"), follow scrolls by shifting existing blocks instead of re-reading them.
/// - Once still for `settleDelay`: read paragraphs, erase the source text (flat fill or MI-GAN) and write the
///   translation in its place ("seamless"), crossfading from the fast boxes.
actor RegionPipeline {
    private struct Block {
        let id: UUID
        var rect: CGRect            // image pixels
        var lines: [CGRect]         // image pixels
        var source: String
        var translation: String?
        var appearance: TextAppearance
        /// Font size (pixels) estimated from the original glyphs.
        var fontSize: CGFloat?
        /// Free background to the right of the text, included in `rect`, that a longer translation may use.
        var spareWidth: CGFloat = 0
        var erased: RGBAImage?      // seamless background covering `rect`
        var image: CGImage?
    }

    private let translator: TranslationService
    private let inpainter: Inpainter?
    private let onSnapshot: @Sendable (OverlaySnapshot) -> Void
    private var onActivity: (@Sendable (RegionActivity) -> Void)?
    private let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "pipeline")

    private var options: PipelineOptions
    private var latest: CapturedFrame?
    private var prevGray: GrayImage?
    /// Part of `prevGray` that holds real pixels (after the capture grew); nil = all of it.
    private var prevValid: PixelRect?
    /// Gray of the frame the current blocks describe (shifted along with scrolls).
    private var baseGray: GrayImage?
    /// Gray-pixel areas the blocks know nothing about (uncovered by a shift or a larger capture).
    private var forcedDirty: [PixelRect] = []
    /// Tiles that keep changing (animated emoji, typing indicators): their changes are left out until they go still.
    /// ponytail: forgotten on every move, so it re-learns for a second after a scroll; shift it with the move if that shows.
    private var churn = Churn()
    private var lastChange: TimeInterval = 0
    /// The lens moving inside the capture changes no pixels, but the settled re-read still waits for it to stop.
    private var lensMoved: TimeInterval = 0
    private var seamlessDone = false
    private var blocks: [Block] = []
    private var working = false
    private var settleTask: Task<Void, Never>?
    /// Sources waiting for translation, and whether the translation worker runs.
    private var pending: Set<String> = []
    private var translating = false
    private var version = 0
    private var scale: CGFloat = 2
    private var activity = RegionActivity.idle
    /// Bumped when the capture size changes; a pass that awaited across a bump discards its result.
    private var geometryEpoch = 0
    /// Content moves applied to the blocks since the running pass started (scrolls, lens recentres): its results, read
    /// from an older frame, are moved the same way instead of being dropped.
    private var moves: [Move] = []
    /// Gray-pixel areas that changed since the running pass started in ways no move explains.
    private var unexplained: [PixelRect] = []
    /// Capture time of the newest frame read for changes.
    private var frameTime: TimeInterval = 0
    private var onScroll: (@Sendable (ScrollReport) -> Void)?
    /// Where things are heading (-1…1 per axis): text from that side is translated first.
    private var lead = CGVector.zero
    private var grayShiftX = ShiftAccumulator()
    private var grayShiftY = ShiftAccumulator()
    private var lastMotionNote: TimeInterval = 0
    private var onMotion: (@Sendable () -> Void)?

    /// Capture rect and the visible lens inside it, global Quartz points.
    private var origin: CGPoint
    private var captureSize: CGSize
    private var visible: CGRect

    init(options: PipelineOptions, capture: CGRect, translator: TranslationService, inpainter: Inpainter?,
         onSnapshot: @escaping @Sendable (OverlaySnapshot) -> Void) {
        self.origin = capture.origin
        self.captureSize = capture.size
        self.visible = capture
        self.options = options
        self.translator = translator
        self.inpainter = inpainter
        self.onSnapshot = onSnapshot
    }

    func setActivityHandler(_ h: @escaping @Sendable (RegionActivity) -> Void) { onActivity = h }
    /// Called (at most twice a second) when content moves a lot: scrolling, page flips, animation.
    func setMotionHandler(_ h: @escaping @Sendable () -> Void) { onMotion = h }
    func setScrollHandler(_ h: @escaping @Sendable (ScrollReport) -> Void) { onScroll = h }
    func setLead(_ v: CGVector) { lead = v }

    func update(options new: PipelineOptions) {
        guard new != options else { return }
        var restyled = options
        restyled.fontStyle = new.fontStyle
        restyled.boxOpacity = new.boxOpacity
        restyled.settleDelay = new.settleDelay
        let reread = restyled != new, redraw = new.fontStyle != options.fontStyle || new.boxOpacity != options.boxOpacity
        options = new
        if reread { reset(); return }
        guard redraw else { return }
        // Only the look changed: redraw what is already read, erased and translated.
        for i in blocks.indices { blocks[i].image = nil }
        renderMissing()
        emit(animated: false)
    }

    /// Forget everything (region moved/resized, settings changed). The next frame is read from scratch.
    func reset() {
        settleTask?.cancel()
        blocks = []
        baseGray = nil
        prevGray = nil
        forcedDirty = []
        churn.reset()
        seamlessDone = false
        pending = []
        emit(animated: false)
        if latest != nil { kick() }
    }

    /// Re-translate everything currently on screen (e.g. after the user downloads a language pack).
    func refresh() {
        for i in blocks.indices { blocks[i].translation = nil; blocks[i].image = nil }
        baseGray = nil
        seamlessDone = false
        kick()
    }

    /// For the headless self-test: whether work is pending, and what each block reads.
    func debugState() -> (busy: Bool, blocks: [(String, String?)]) {
        (working || translating || settleTask != nil && !seamlessDone, blocks.map { ($0.source, $0.translation) })
    }

    func ingest(_ frame: CapturedFrame) {
        if let l = latest, frame.time < l.time { return }
        // Frames of an older capture geometry would put text in the wrong place.
        guard abs(frame.rect.minX - origin.x) < 0.5, abs(frame.rect.minY - origin.y) < 0.5,
              abs(frame.rect.width - captureSize.width) < 0.5, abs(frame.rect.height - captureSize.height) < 0.5,
              // The tag is what was asked for; the pixels may still be of the previous size right after a change.
              abs(frame.image.width - Int((captureSize.width * frame.scale).rounded())) <= 1,
              abs(frame.image.height - Int((captureSize.height * frame.scale).rounded())) <= 1 else {
            Trace.mark("frame dropped: \(frame.rect) vs \(origin) \(captureSize)", since: frame.time)
            return
        }
        scale = frame.scale
        lastStep = frame.grayStep
        let previous = frameTime
        frameTime = frame.time
        if let full = prevGray, full.width == frame.gray.width, full.height == frame.gray.height {
            let prev = prevValid.map { full.cropped(to: $0) } ?? full
            let gray = prevValid.map { frame.gray.cropped(to: $0) } ?? frame.gray
            let raw = FrameDiff.changeMap(from: prev, to: gray)
            if !raw.isUnchanged {
                let scrolled = blocks.isEmpty ? [] : FrameDiff.scrollRegions(from: prev, to: gray, change: raw, maxShift: gray.height / 3)
                if !scrolled.isEmpty { followScroll(scrolled, offset: prevValid, frame: frame, since: previous) }
                // Small changes that keep coming back are animation; big ones are motion (a scroll it could not follow).
                else if prevValid == nil, raw.ratio <= 0.2 { churn.add(raw, at: frame.time) }
                let change = churn.masking(raw, at: frame.time)
                Trace.mark("\(Int(captureSize.width))×\(Int(captureSize.height)): changed \(Int(raw.ratio * 100)) %"
                           + (change.changedCount < raw.changedCount ? " (\(raw.changedCount - change.changedCount) tiles animated)" : "")
                           + (change.dirtyRect.map { " dirty \($0.x),\($0.y) \($0.width)×\($0.height)" } ?? "")
                           + ", scrolled " + scrolled.map { "\($0.dy) in \($0.rect.width)×\($0.rect.height)" }.joined(separator: ", "),
                           since: frame.time)
                if !change.isUnchanged {
                    lastChange = frame.time
                    seamlessDone = false
                }
                if let d = change.dirtyRect(outside: scrolled.map(\.rect)) {
                    unexplained.append(PixelRect(x: d.x + (prevValid?.x ?? 0), y: d.y + (prevValid?.y ?? 0), width: d.width, height: d.height))
                }
                if raw.ratio > 0.2 || !scrolled.isEmpty { noteMotion(frame.time) }
            }
        } else {
            lastChange = frame.time
        }
        prevGray = frame.gray
        prevValid = nil
        latest = frame
        kick()
    }

    private func noteMotion(_ t: TimeInterval) {
        guard t - lastMotionNote > 0.5 else { return }
        lastMotionNote = t
        onMotion?()
    }

    // MARK: - Scheduling

    private func kick() {
        guard !working else { return }
        working = true
        Task { await self.run() }
    }

    private func run() async {
        while let frame = latest {
            let now = ProcessInfo.processInfo.systemUptime
            let stale = staleness(for: frame)
            // Seamless mode re-reads on change only, and a tile that stopped animating changed while it was left out.
            if options.renderMode == .seamless, seamlessDone, stale.change?.isUnchanged == false { seamlessDone = false }
            let settled = now - max(lastChange, lensMoved) >= options.settleDelay
            let wantsSeamless = options.renderMode != .fast && !seamlessDone && (settled || options.renderMode == .seamless)
            if wantsSeamless {
                // A timed-out read is tried again rather than counted as done.
                if await seamlessPass(frame) { seamlessDone = lastChange <= frame.time }
                continue
            }
            if options.renderMode != .seamless, let dirty = dirtyRect(for: frame, stale) {
                await fastPass(frame, dirty: dirty, stale: stale)
                continue
            }
            break
        }
        working = false
        setActivity(translating && lensPending ? .translating : .idle)
        let now = ProcessInfo.processInfo.systemUptime
        var wait: TimeInterval?
        if options.renderMode == .adaptive, !seamlessDone, latest != nil {
            wait = max(0.05, options.settleDelay - (now - max(lastChange, lensMoved)))
        }
        // An animation that stops sends no more frames: look again once its tiles count as still.
        if latest != nil, let c = churn.coolsIn(at: now) { wait = min(wait ?? .infinity, c + 0.05) }
        if let wait {
            settleTask?.cancel()
            settleTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                await self?.kick()
            }
        }
    }

    /// What the current blocks no longer describe: gray-pixel tiles that changed, and the blocks touching them.
    private struct Staleness {
        var change: ChangeMap?
        var forced: [PixelRect]
        func touches(_ r: CGRect, step: Int) -> Bool {
            let g = PixelRect(r.insetBy(dx: -1, dy: -1).applying(CGAffineTransform(scaleX: 1 / CGFloat(step), y: 1 / CGFloat(step))))
            // A block cut off at the old capture edge ends right where the uncovered strip begins: touching counts.
            let near = g.cgRect.insetBy(dx: -2, dy: -2)
            return change.map { $0.intersects(g) } ?? true || forced.contains { $0.cgRect.intersects(near) }
        }
    }

    private func staleness(for frame: CapturedFrame) -> Staleness {
        guard let base = baseGray, base.width == frame.gray.width, base.height == frame.gray.height else {
            return Staleness(change: nil, forced: [])
        }
        return Staleness(change: churn.masking(FrameDiff.changeMap(from: base, to: frame.gray), at: ProcessInfo.processInfo.systemUptime),
                         forced: forcedDirty)
    }

    /// Image-pixel rect needing a re-read, or nil when the blocks still describe the frame.
    private func dirtyRect(for frame: CapturedFrame, _ stale: Staleness) -> CGRect? {
        let full = CGRect(x: 0, y: 0, width: frame.image.width, height: frame.image.height)
        guard let change = stale.change else { return full }
        let step = CGFloat(frame.grayStep), pad = CGFloat(change.tile) * step
        var dirty: CGRect?
        func add(_ r: CGRect) { dirty = dirty.map { $0.union(r) } ?? r }
        // Text runs horizontally: changed tiles widen to full rows so partially changed lines are read whole.
        if let d = change.dirtyRect {
            add(CGRect(x: 0, y: CGFloat(d.y) * step - pad, width: full.width, height: CGFloat(d.height) * step + 2 * pad))
        }
        // Uncovered strips too: a line crossing into one may have been cut off at the old edge.
        for f in stale.forced { add(CGRect(x: 0, y: CGFloat(f.y) * step - pad, width: full.width, height: CGFloat(f.height) * step + 2 * pad)) }
        // And every stale block, whole.
        guard let d = dirty else { return nil }
        for b in blocks where b.rect.intersects(d) && stale.touches(b.rect, step: frame.grayStep) { add(b.rect.insetBy(dx: -pad, dy: -pad)) }
        return dirty?.intersection(full)
    }

    /// Moves the blocks of each scrolled area along with its content; fixed parts around it (headers, sidebars) stay.
    /// Only the strip that scrolled into view needs reading. `offset` places the regions (found in the part of the
    /// frame that could be compared) in the whole frame.
    private func followScroll(_ regions: [ScrollRegion], offset: PixelRect?, frame: CapturedFrame, since t0: TimeInterval) {
        let step = CGFloat(frame.grayStep)
        // Where the references agreed with the previous frame, the new frame is exactly what they now describe; that
        // also absorbs the part of a pixel a smooth scroll moved by, which would otherwise read as changed text.
        let inSync = baseGray.flatMap { base in prevGray.map { FrameDiff.changeMap(from: base, to: $0) } }
        for r in regions {
            let g = PixelRect(x: r.rect.x + (offset?.x ?? 0), y: r.rect.y + (offset?.y ?? 0), width: r.rect.width, height: r.rect.height)
            let area = CGRect(x: CGFloat(g.x) * step, y: CGFloat(g.y) * step, width: CGFloat(g.width) * step, height: CGFloat(g.height) * step)
            let gy = Int(r.dy.rounded()), strip = GrayImage.vacated(dy: Int(r.dy.rounded(.awayFromZero)), within: g)
            if let base = baseGray, base.width == frame.gray.width, base.height == frame.gray.height {
                let clean = inSync.map { $0.imageWidth == base.width && !$0.intersects(g) } ?? false
                baseGray = clean ? base.replacing(g, from: frame.gray) : base.shifted(dy: gy, within: g)
                forcedDirty = forcedDirty.map { $0.cgRect.intersects(g.cgRect) ? PixelRect(x: $0.x, y: $0.y + gy, width: $0.width, height: $0.height) : $0 }
                    + [strip].compactMap { $0 }
            }
            apply(Move(area: area, dx: 0, dy: CGFloat(r.dy) * step, gx: 0, gy: gy, grayArea: g, strip: strip))
            onScroll?(ScrollReport(area: CGRect(x: origin.x + area.minX / scale, y: origin.y + area.minY / scale,
                                                width: area.width / scale, height: area.height / scale),
                                   shift: CGFloat(r.dy) * step / scale, from: t0, to: frame.time))
        }
    }

    /// The visible lens (global Quartz points), for translating what the user sees first.
    /// A moving lens also holds off the settled re-read until it stops.
    func setVisible(_ rect: CGRect) {
        if rect != visible { lensMoved = ProcessInfo.processInfo.systemUptime }
        visible = rect
    }

    /// Content that moved: everything (the capture moved over still content) or one scrolled area.
    private struct Move {
        /// Image pixels, in the newer frame; nil = the whole frame.
        var area: CGRect?
        /// Image pixels.
        var dx: CGFloat, dy: CGFloat
        /// Gray pixels the references moved by, and the gray area (nil = all).
        var gx: Int, gy: Int
        var grayArea: PixelRect?
        /// Rows of `grayArea` that scrolled into view.
        var strip: PixelRect?

        /// Where a block belongs to a scrolled area: near the start of its text. A scroll is often found in only part of
        /// a column's width (the side with avatars and line starts; line ends are too sparse to match), and a long
        /// line's middle can lie outside it; one point also keeps a block from moving with two areas.
        static func anchor(_ r: CGRect) -> CGPoint { CGPoint(x: r.minX + min(r.width, r.height) / 2, y: r.midY) }

        /// The block moved along, or nil when it left the frame or scrolled out of its area (under a fixed header).
        func apply(to b: Block, bounds: CGRect) -> Block? {
            if let area, !area.contains(Self.anchor(b.rect)) { return b }
            var b = b
            b.rect = b.rect.offsetBy(dx: dx, dy: dy)
            b.lines = b.lines.map { $0.offsetBy(dx: dx, dy: dy) }
            if let area { return area.contains(Self.anchor(b.rect)) ? b : nil }
            // Blocks cut by the edge stay (the overlay clips them, like a lens); gone ones are dropped.
            return b.rect.intersects(bounds) ? b : nil
        }

        /// A gray-pixel area that moved along.
        func apply(to r: PixelRect) -> PixelRect {
            if let g = grayArea, !g.cgRect.intersects(r.cgRect) { return r }
            return PixelRect(x: r.x + gx, y: r.y + gy, width: r.width, height: r.height)
        }

        /// Where a rect now in the newer frame was before the move.
        func undo(_ r: CGRect) -> CGRect {
            if let area, !area.contains(Self.anchor(r)) { return r }
            return r.offsetBy(dx: -dx, dy: -dy)
        }
    }

    /// The capture moved to `newOrigin` (global Quartz points) while the content under it moved by `contentDelta`
    /// (zero when a lens is dragged over static content; the window's move when the capture follows a window).
    /// Blocks stay glued to the content, and only the strips the move uncovered are read.
    func captureMoved(to newOrigin: CGPoint, contentDelta: CGVector = .zero) {
        let rel = CGVector(dx: newOrigin.x - origin.x - contentDelta.dx, dy: newOrigin.y - origin.y - contentDelta.dy)
        origin = newOrigin
        guard rel.dx != 0 || rel.dy != 0 else { return }
        // Blocks move by the exact pixel delta; the gray references only by whole gray pixels, with the
        // fraction carried over so a slow drag never drifts.
        let px = -rel.dx * scale, py = -rel.dy * scale
        let step = CGFloat(lastStep)
        // The last frame shows the old position; the capturer delivers a fresh one once it has moved.
        latest = nil
        let gx = grayShiftX.add(px / step), gy = grayShiftY.add(py / step)
        lastChange = ProcessInfo.processInfo.systemUptime
        seamlessDone = false
        if (gx != 0 || gy != 0), let prev = prevGray {
            prevGray = prev.shifted(dx: gx, dy: gy)
            let valid = prevValid ?? PixelRect(x: 0, y: 0, width: prev.width, height: prev.height)
            prevValid = PixelRect(x: valid.x + gx, y: valid.y + gy, width: valid.width, height: valid.height)
                .clamped(width: prev.width, height: prev.height)
        }
        if let base = baseGray, gx != 0 || gy != 0 {
            baseGray = base.shifted(dx: gx, dy: gy)
            forcedDirty = forcedDirty.map { PixelRect(x: $0.x + gx, y: $0.y + gy, width: $0.width, height: $0.height) }
                + base.vacatedStrips(dx: gx, dy: gy)
        }
        apply(Move(area: nil, dx: px, dy: py, gx: gx, gy: gy, grayArea: nil, strip: nil))
        kick()
    }

    /// The capture grew or shrank (overscan widened for motion, lens resized). Blocks are kept where they are on
    /// screen and only the newly covered area is read.
    func captureResized(to rect: CGRect) {
        guard rect.size != captureSize || rect.origin != origin else { return }
        let px = (origin.x - rect.minX) * scale, py = (origin.y - rect.minY) * scale
        let size = CGSize(width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
        origin = rect.origin
        captureSize = rect.size
        geometryEpoch += 1
        churn.reset()
        lastChange = ProcessInfo.processInfo.systemUptime
        seamlessDone = false
        latest = nil
        grayShiftX.reset(); grayShiftY.reset()
        let bounds = CGRect(origin: .zero, size: size)
        blocks = blocks.compactMap { b in
            var b = b
            b.rect = b.rect.offsetBy(dx: px, dy: py)
            b.lines = b.lines.map { $0.offsetBy(dx: px, dy: py) }
            return b.rect.intersects(bounds) ? b : nil
        }
        if let base = baseGray {
            let step = CGFloat(lastStep)
            let gx = Int((px / step).rounded()), gy = Int((py / step).rounded())
            let gw = Int(size.width) / Int(step), gh = Int(size.height) / Int(step)
            baseGray = base.reframed(dx: gx, dy: gy, width: gw, height: gh)
            // Scroll detection keeps working across the resize, compared only where the old frame had pixels.
            if let prev = prevGray, prev.width == base.width, prev.height == base.height {
                prevGray = prev.reframed(dx: gx, dy: gy, width: gw, height: gh)
                prevValid = PixelRect(x: gx, y: gy, width: prev.width, height: prev.height).clamped(width: gw, height: gh)
            } else {
                prevGray = nil
            }
            forcedDirty = forcedDirty.map { PixelRect(x: $0.x + gx, y: $0.y + gy, width: $0.width, height: $0.height) }
                + base.uncovered(dx: gx, dy: gy, width: gw, height: gh)
        }
        emit(animated: false)
    }

    /// Gray step of the frames (image pixels per gray pixel).
    private var lastStep = 4

    private func apply(_ m: Move) {
        moves.append(m)
        churn.reset()
        unexplained = unexplained.map { m.apply(to: $0) }
        let bounds = CGRect(x: 0, y: 0, width: captureSize.width * scale, height: captureSize.height * scale)
        blocks = blocks.compactMap { m.apply(to: $0, bounds: bounds) }
        emit(animated: false)
    }

    /// Where a pass started, so its results can follow content that moved while it awaited.
    private struct PassStart {
        let epoch: Int
    }

    /// Passes run one at a time, so the moves since this one started are all the moves there are.
    private func startPass() -> PassStart {
        moves = []
        unexplained = []
        return PassStart(epoch: geometryEpoch)
    }

    /// After a pass's await: the moves to apply to its results, or nil if the geometry changed under it.
    /// Also makes the reference what the results, moved, describe: the newest frame, except where it changed in ways
    /// no move explains — there `frame` moved along stays, so those parts read as changed.
    private func finishPass(_ start: PassStart, frame: CapturedFrame) -> [Move]? {
        guard start.epoch == geometryEpoch else { return nil }
        var base = frame.gray, forced: [PixelRect] = []
        for m in moves {
            if let g = m.grayArea {
                base = base.shifted(dy: m.gy, within: g)
                forced = forced.map { $0.cgRect.intersects(g.cgRect) ? PixelRect(x: $0.x, y: $0.y + m.gy, width: $0.width, height: $0.height) : $0 }
                    + [m.strip].compactMap { $0 }
            } else if m.gx != 0 || m.gy != 0 {
                forced = forced.map { PixelRect(x: $0.x + m.gx, y: $0.y + m.gy, width: $0.width, height: $0.height) }
                    + base.vacatedStrips(dx: m.gx, dy: m.gy)
                base = base.shifted(dx: m.gx, dy: m.gy)
            }
        }
        // Moves are only whole gray pixels; taking the newest frame also drops the fraction a smooth scroll leaves.
        if !moves.isEmpty, let now = prevGray, now.width == base.width, now.height == base.height {
            base = unexplained.reduce(now) { $0.replacing($1, from: base) }
        }
        baseGray = base
        forcedDirty = forced
        return moves
    }

    // MARK: - Passes

    private var ocrLanguages: [Locale.Language] {
        options.sourceLanguage == "auto" ? [] : [Locale.Language(identifier: options.sourceLanguage)]
    }

    private func fastPass(_ frame: CapturedFrame, dirty: CGRect, stale: Staleness) async {
        setActivity(.reading)
        let start = startPass()
        let useFast = options.sourceLanguage != "auto" && Languages.isLatinScript(options.sourceLanguage)
        // Blocks whose pixels did not change stay as they are (seamless ones keep their erased background).
        let staleIDs = Set(blocks.filter { $0.rect.intersects(dirty) && stale.touches($0.rect, step: frame.grayStep) }.map(\.id))
        let keptRects = blocks.filter { !staleIDs.contains($0.id) }.map(\.rect)
        let t = Trace.now
        let wantsErase = options.renderMode != .fast
        var found: [OCRBlock]
        do {
            // Erasing modes read paragraphs, like the seamless pass: the settled re-read then finds the same text and
            // keeps its translations instead of translating everything a second time.
            found = wantsErase ? (try? await TextRecognizer.blocks(in: frame.image, roi: dirty, languages: ocrLanguages,
                                                                   customWords: options.glossaryTerms)) ?? [] : []
            if found.isEmpty {
                found = try await TextRecognizer.lines(in: frame.image, roi: dirty, languages: ocrLanguages, fast: useFast,
                                                       customWords: options.glossaryTerms).map { TextRecognizer.makeBlock([$0]) }
            }
        } catch {
            log.error("fast OCR failed: \(String(describing: error), privacy: .public)")
            Trace.mark("fast: OCR failed \(error)", since: t)
            // A stuck request is retried; any other failure would just fail again on the same pixels.
            if !(error is TextRecognizer.Timeout) { _ = finishPass(start, frame: frame) }
            return
        }
        found = splitByStyle(found, in: frame.image)
        Trace.mark("fast: OCR \(Int(dirty.width))×\(Int(dirty.height))px → \(found.count) blocks", since: t)
        let fresh = found.filter { ocr in
            TextRecognizer.needsTranslation(ocr.text, target: options.targetLanguage)
                && !keptRects.contains { $0.contains(CGPoint(x: ocr.rect.midX, y: ocr.rect.midY)) }
        }
        let full = wantsErase ? RGBAImage(cgImage: frame.image) : nil
        let old = blocks.filter { staleIDs.contains($0.id) }
        let matches = BlockMatcher.match(old: old.map { .init(rect: $0.rect, text: $0.source) },
                                         new: fresh.map { .init(rect: $0.rect, text: $0.text) })
        var made: [Block] = []
        for (i, ocr) in fresh.enumerated() {
            let prior = matches[i].map { old[$0] }
            var b: Block
            if let full, let e = erase(ocr, in: full) {
                b = Block(id: prior?.id ?? UUID(), rect: e.rect.cgRect, lines: ocr.lines.map(\.rect), source: ocr.text, appearance: e.look,
                          fontSize: e.fontSize, spareWidth: e.spare)
                b.erased = e.patch
            } else {
                let r = ocr.rect, pad = ocr.lines.map(\.rect.height).min() ?? r.height
                let boxRect = r.insetBy(dx: -max(2, pad * 0.12), dy: -max(1, pad * 0.08))
                    .intersection(CGRect(x: 0, y: 0, width: frame.image.width, height: frame.image.height))
                b = Block(id: prior?.id ?? UUID(), rect: boxRect, lines: ocr.lines.map(\.rect), source: ocr.text,
                          appearance: appearance(of: ocr.lines[0].rect, in: frame.image))
            }
            if let prior, prior.source == ocr.text { b.translation = prior.translation }
            made.append(b)
        }
        guard let moved = finishPass(start, frame: frame) else { return }
        let bounds = CGRect(x: 0, y: 0, width: frame.image.width, height: frame.image.height)
        // Translations that arrived meanwhile are on the current copies of the old blocks.
        let current = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        made = made.compactMap { b in
            guard var b = moved.reduce(Optional(b), { b, m in b.flatMap { m.apply(to: $0, bounds: bounds) } }) else { return nil }
            if b.translation == nil, let c = current[b.id], c.source == b.source { b.translation = c.translation }
            return b
        }
        blocks = blocks.filter { !staleIDs.contains($0.id) } + made
        Trace.mark("fast: \(made.count) new blocks (\(wantsErase ? "erased" : "boxed")), \(blocks.count - made.count) kept", since: t)
        fillTranslations()
        renderMissing()
        emit(animated: false)
    }

    @discardableResult
    private func seamlessPass(_ frame: CapturedFrame) async -> Bool {
        setActivity(.reading)
        let start = startPass()
        var t = Trace.now
        var found: [OCRBlock]
        do {
            do {
                found = try await TextRecognizer.blocks(in: frame.image, languages: ocrLanguages, customWords: options.glossaryTerms)
            } catch is TextRecognizer.Timeout {
                Trace.mark("seamless: document OCR timed out, reading lines", since: t)
                found = []
            }
            if found.isEmpty {
                found = try await TextRecognizer.lines(in: frame.image, languages: ocrLanguages, fast: false)
                    .map { TextRecognizer.makeBlock([$0]) }
            }
        } catch {
            log.error("document OCR failed: \(String(describing: error), privacy: .public)")
            Trace.mark("seamless: OCR failed \(error)", since: t)
            if error is TextRecognizer.Timeout { return false }
            _ = finishPass(start, frame: frame)
            return true
        }
        Trace.mark("seamless: document OCR (\(found.count) blocks)", since: t); t = Trace.now
        found = splitByStyle(found, in: frame.image)
            .filter { TextRecognizer.needsTranslation($0.text, target: options.targetLanguage) }
        guard let full = RGBAImage(cgImage: frame.image) else { return true }
        Trace.mark("seamless: frame → RGBA", since: t); t = Trace.now

        // Matched in the frame's coordinates: undo any move applied to the blocks since the pass started.
        let undone = blocks.map { b in moves.reversed().reduce(b.rect) { $1.undo($0) } }
        let matches = BlockMatcher.match(old: blocks.indices.map { .init(rect: undone[$0], text: blocks[$0].source) },
                                         new: found.map { .init(rect: $0.rect, text: $0.text) })
        let prior = blocks
        var next: [Block] = []
        for (i, ocr) in found.enumerated() {
            guard let e = erase(ocr, in: full) else { continue }
            let id = matches[i].map { prior[$0].id } ?? UUID()
            var b = Block(id: id, rect: e.rect.cgRect, lines: ocr.lines.map(\.rect), source: ocr.text, appearance: e.look,
                          fontSize: e.fontSize, spareWidth: e.spare)
            if let oi = matches[i], prior[oi].source == ocr.text { b.translation = prior[oi].translation }
            b.erased = e.patch
            next.append(b)
        }
        Trace.mark("seamless: erase \(next.count) blocks", since: t); t = Trace.now
        guard let moved = finishPass(start, frame: frame) else { return true }
        let bounds = CGRect(x: 0, y: 0, width: frame.image.width, height: frame.image.height)
        blocks = next.compactMap { b in moved.reduce(Optional(b)) { b, m in b.flatMap { m.apply(to: $0, bounds: bounds) } } }
        fillTranslations()
        renderMissing()
        Trace.mark("seamless: render", since: t)
        emit(animated: true)
        return true
    }

    /// The document reader groups lines by layout alone, so a chat message and the next sender's name, or a post
    /// title and its body, can land in one paragraph. Split wherever the text colour or size changes — first within
    /// a line (a name, a badge and a timestamp read as one line each become their own block, icons in front of text
    /// are cut off), then between lines. Names and badges are dropped, so they stay on screen as they are.
    private func splitByStyle(_ blocks: [OCRBlock], in image: CGImage) -> [OCRBlock] {
        let split = blocks.flatMap { block -> [OCRBlock] in
            var parts: [[OCRLine]] = [[]]
            for line in block.lines {
                let runs = styleRuns(line, in: image)
                if runs.count == 1 {
                    parts[parts.count - 1].append(runs[0])
                } else if runs.count > 1 {
                    parts += runs.map { [$0] } + [[]]
                }
            }
            return parts.filter { !$0.isEmpty }.flatMap { lines -> [OCRBlock] in
                guard lines.count > 1 else { return [TextRecognizer.makeBlock(lines)] }
                let styles = lines.map { (color: appearance(of: $0.rect, in: image).textColor, height: $0.rect.height) }
                var groups: [[OCRLine]] = [[lines[0]]]
                for i in 1..<lines.count {
                    let a = styles[i - 1], b = styles[i]
                    let sizeJump = max(a.height, b.height) / max(1, min(a.height, b.height)) > 1.3
                    if a.color.distance(to: b.color) > 60 || sizeJump { groups.append([]) }
                    groups[groups.count - 1].append(lines[i])
                }
                return groups.map(TextRecognizer.makeBlock)
            }
        }
        let items = split.map { LabelRule.Item(rect: $0.rect, text: $0.text, color: appearance(of: $0.lines[0].rect, in: image).textColor) }
        let labels = LabelRule.labels(items)
        return split.indices.filter { !labels.contains($0) }.map { split[$0] }
    }

    /// A line cut into runs of one text colour, with icons and stray marks trimmed off each run's ends.
    private func styleRuns(_ line: OCRLine, in image: CGImage) -> [OCRLine] {
        guard !line.words.isEmpty else { return [line] }
        let h = line.rect.height
        let ring = max(2, Int(h * 0.15))
        let crop = PixelRect(line.rect.insetBy(dx: -CGFloat(ring), dy: -CGFloat(ring))).clamped(width: image.width, height: image.height)
        let text = PixelRect(line.rect).clamped(width: image.width, height: image.height)
        guard let patch = RGBAImage(cgImage: image, crop: crop) else { return [line] }
        let mask = TextEraser.mask(for: patch, textRect: PixelRect(x: text.x - crop.x, y: text.y - crop.y, width: text.width, height: text.height),
                                   dilation: 0)
        let clusters = TextEraser.clusters(mask, in: patch, lineHeight: Int(h)).map {
            InkCluster(minX: $0.minX + crop.x, maxX: $0.maxX + crop.x, color: $0.color, ink: $0.ink, solid: $0.solid)
        }
        let tokens = line.words.map {
            StyleRuns.token(text: String(line.text[$0.range]), minX: $0.rect.minX, maxX: $0.rect.maxX, clusters: clusters, lineHeight: h)
        }
        if Trace.enabled {
            Trace.mark("runs: " + tokens.map { "\($0.text)[\($0.color.map { "\($0.r),\($0.g),\($0.b)" } ?? "-")\($0.solid ? " solid" : "")]" }
                .joined(separator: " "), since: Trace.now)
        }
        return StyleRuns.runs(tokens, lineHeight: h).map { r in
            let words = Array(line.words[r]), minX = tokens[r].map(\.minX).min()!, maxX = tokens[r].map(\.maxX).max()!
            return OCRLine(rect: CGRect(x: minX, y: line.rect.minY, width: maxX - minX, height: h),
                           text: String(line.text[words[0].range.lowerBound..<words[words.count - 1].range.upperBound]), words: words)
        }
    }

    // MARK: - Erasing

    private struct Erased {
        var rect: PixelRect
        var patch: RGBAImage
        var look: TextAppearance
        var fontSize: CGFloat?
        var spare: CGFloat
    }

    /// Erases a block's text: builds the glyph mask per line, then fills it (flat backgrounds) or inpaints it
    /// (textured ones). The patch also takes in free background to the right for longer translations.
    private func erase(_ block: OCRBlock, in full: RGBAImage) -> Erased? {
        Trace.count("erase")
        let lineHeight = block.lines.map(\.rect.height).sorted()[block.lines.count / 2]
        let ring = BlockRenderer.eraseMargin(lineHeight: lineHeight)
        var rect = PixelRect(block.rect.insetBy(dx: -CGFloat(ring), dy: -CGFloat(ring))).clamped(width: full.width, height: full.height)
        guard !rect.isEmpty else { return nil }

        var masks: [(PixelRect, TextMask)] = []
        var glyphHeights: [CGFloat] = []
        for line in block.lines {
            let lr = PixelRect(line.rect.insetBy(dx: -CGFloat(ring), dy: -CGFloat(ring))).clamped(width: full.width, height: full.height)
            guard !lr.isEmpty else { continue }
            let text = PixelRect(line.rect).clamped(width: full.width, height: full.height)
            let local = PixelRect(x: text.x - lr.x, y: text.y - lr.y, width: text.width, height: text.height)
            let m = TextEraser.mask(for: full.cropped(to: lr), textRect: local, dilation: max(1, Int(line.rect.height * 0.07)), outlines: true)
            masks.append((lr, m))
            if let g = m.glyphBounds { glyphHeights.append(CGFloat(g.height)) }
        }
        // Prefer a line whose glyphs were actually segmented over a whole-box fallback.
        guard let look = masks.map(\.1.appearance).first(where: { $0.coverage < 0.95 }) ?? masks.first?.1.appearance else { return nil }

        let spare = freeWidth(rightOf: rect, in: full, background: look.backgroundColor)
        rect.width += spare
        var patch = full.cropped(to: rect)
        var mask = [UInt8](repeating: 0, count: rect.width * rect.height)
        for (lr, m) in masks {
            for y in 0..<lr.height {
                for x in 0..<lr.width where m.bits[y * lr.width + x] != 0 {
                    let px = lr.x + x - rect.x, py = lr.y + y - rect.y
                    if px >= 0, py >= 0, px < rect.width, py < rect.height { mask[py * rect.width + px] = 1 }
                }
            }
        }

        TextEraser.fillEnclosedHoles(&mask, width: rect.width, height: rect.height)
        let flat = masks.allSatisfy(\.1.appearance.isFlatBackground)
        if ProcessInfo.processInfo.environment["MWOYEO_ERASE_ONLY"] == "mask" {
            for i in mask.indices where mask[i] != 0 { patch.set(x: i % rect.width, y: i / rect.width, RGBA(255, 0, 0)) }
        } else if !flat, options.useInpainting, let inpainter {
            do {
                Trace.count("inpaint")
                patch = try inpainter.inpaint(frame: full, rect: rect, mask: mask)
            } catch {
                log.error("inpainting failed: \(error.localizedDescription)")
                TextEraser.fill(&patch, mask: mask)
            }
        } else {
            TextEraser.fill(&patch, mask: mask)
        }
        let glyph = glyphHeights.isEmpty ? nil : glyphHeights.sorted()[glyphHeights.count / 2]
        return Erased(rect: rect, patch: patch, look: look, fontSize: glyph.map { Self.emSize(glyphHeight: $0, text: block.text) },
                      spare: CGFloat(spare))
    }

    /// Columns to the right of `rect` that hold nothing but the background colour (up to 80 % more width).
    private func freeWidth(rightOf rect: PixelRect, in full: RGBAImage, background: RGBA) -> Int {
        let limit = min(full.width - (rect.x + rect.width), Int(Double(rect.width) * 0.8))
        guard limit > 0 else { return 0 }
        var free = 0
        columns: while free < limit {
            let x = rect.x + rect.width + free
            for y in stride(from: rect.y, to: rect.y + rect.height, by: 2) where full.color(x: x, y: y).distance(to: background) > 22 {
                break columns
            }
            free += 1
        }
        // Leave a margin before whatever stopped us (a box edge, another label).
        return free < limit ? max(0, free - max(4, rect.height / 4)) : free
    }

    /// Em size from the measured glyph height: CJK and Hangul glyphs fill ~88 % of the em; Latin text spans
    /// cap height (~70 %) or, with descenders, ascender-to-descender (~95 %).
    static func emSize(glyphHeight h: CGFloat, text: String) -> CGFloat {
        if text.contains(where: TextRecognizer.isCJK) || text.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) {
            return h / 0.88
        }
        return text.contains(where: { "gjpqy".contains($0) }) ? h / 0.95 : h / 0.72
    }

    private func appearance(of lineRect: CGRect, in image: CGImage) -> TextAppearance {
        let ring = max(2, Int(lineRect.height * 0.15))
        let crop = PixelRect(lineRect.insetBy(dx: -CGFloat(ring), dy: -CGFloat(ring))).clamped(width: image.width, height: image.height)
        let text = PixelRect(lineRect).clamped(width: image.width, height: image.height)
        guard let patch = RGBAImage(cgImage: image, crop: crop) else {
            return TextAppearance(textColor: RGBA(255, 255, 255), backgroundColor: RGBA(0, 0, 0), backgroundNoise: 0, coverage: 0.2)
        }
        let local = PixelRect(x: text.x - crop.x, y: text.y - crop.y, width: text.width, height: text.height)
        return TextEraser.mask(for: patch, textRect: local, dilation: 0).appearance
    }

    // MARK: - Translation

    /// Fills translations from the cache right away and queues the rest.
    private func fillTranslations() {
        for i in blocks.indices where blocks[i].translation == nil {
            if let hit = translator.cached(blocks[i].source) {
                blocks[i].translation = hit
                blocks[i].image = nil
            } else {
                pending.insert(blocks[i].source)
            }
        }
        guard !translating, !pending.isEmpty else { return }
        translating = true
        if lensPending { setActivity(.translating) }
        Task { await translateQueue() }
    }

    /// Translates a few lines at a time, always picking again what the lens shows first: the queue keeps up with a
    /// moving lens instead of finishing text that has already scrolled out of view.
    private func translateQueue() async {
        while let batch = nextBatch() {
            let t = Trace.now
            let result = await translator.translate(batch) { source, translated in
                Task { await self.receive([source: translated]) }
            }
            Trace.mark("translate ×\(batch.count)", since: t)
            batch.forEach { pending.remove($0) }
            receive(result)
            // The overscan keeps translating quietly; "translating" is only what the lens is waiting for.
            if !working { setActivity(lensPending ? .translating : .idle) }
        }
        translating = false
        if !working { setActivity(.idle) }
    }

    private var lensPending: Bool {
        blocks.contains { $0.translation == nil && pending.contains($0.source) && priority($0.rect).0 == 0 }
    }

    private func nextBatch() -> [String]? {
        // Forget text that is gone or already translated.
        pending.formIntersection(blocks.filter { $0.translation == nil }.map(\.source))
        guard !pending.isEmpty else { return nil }
        var seen = Set<String>()
        let ordered = blocks.sorted { priority($0.rect) < priority($1.rect) }.map(\.source)
            .filter { pending.contains($0) && seen.insert($0).inserted }
        return Array(ordered.prefix(3))
    }

    /// What the lens shows comes first, in reading order; then the overscan, nearest first.
    private func priority(_ r: CGRect) -> (Int, CGFloat) {
        let lens = CGRect(x: (visible.minX - origin.x) * scale, y: (visible.minY - origin.y) * scale,
                          width: visible.width * scale, height: visible.height * scale)
        if r.intersects(lens) { return (0, r.minY) }
        let dx = max(lens.minX - r.maxX, r.minX - lens.maxX, 0), dy = max(lens.minY - r.maxY, r.minY - lens.maxY, 0)
        // Text on the side things are heading to (a dragged lens, content scrolling in) reaches the lens first.
        let side = CGVector(dx: r.midX < lens.minX ? -1 : r.midX > lens.maxX ? 1 : 0, dy: r.midY < lens.minY ? -1 : r.midY > lens.maxY ? 1 : 0)
        return (1, hypot(dx, dy) / (1 + max(0, side.dx * lead.dx + side.dy * lead.dy)))
    }

    private func receive(_ result: [String: String]) {
        var changed = false
        for i in blocks.indices {
            guard let t = result[blocks[i].source], blocks[i].translation != t else { continue }
            blocks[i].translation = t
            blocks[i].image = nil
            changed = true
        }
        if changed {
            renderMissing()
            emit(animated: true)
        }
    }

    // MARK: - Output

    private func renderMissing() {
        for i in blocks.indices where blocks[i].image == nil {
            let b = blocks[i]
            // A translation equal to the source means "leave it": no box, no erase, the original stays.
            guard let text = b.translation, !text.isEmpty, text != b.source else { continue }
            let heights = b.lines.map(\.height).sorted()
            let lineHeight = heights.isEmpty ? b.rect.height : heights[heights.count / 2]
            let background: BlockRenderer.Background = b.erased.map { .erased($0) }
                ?? .box(b.appearance.backgroundColor, opacity: options.boxOpacity)
            Trace.count("render")
            blocks[i].image = BlockRenderer.render(.init(
                size: b.rect.size, text: text, background: background, appearance: b.appearance,
                lineHeight: lineHeight, fontSize: b.fontSize, originalLineCount: max(1, b.lines.count), spareWidth: b.spareWidth,
                fontStyle: options.fontStyle,
                targetLanguage: options.targetLanguage, scale: scale,
                centered: LineAlignment.isCentered(b.lines.map { ($0.minX, $0.maxX) }, outlined: b.appearance.outlineColor != nil)))
        }
    }

    private func emit(animated: Bool) {
        version += 1
        let s = scale
        let out = blocks.compactMap { b -> OverlayBlock? in
            guard let img = b.image else { return nil }
            return OverlayBlock(id: b.id, frame: CGRect(x: b.rect.minX / s, y: b.rect.minY / s, width: b.rect.width / s, height: b.rect.height / s),
                                image: img, seamless: b.erased != nil)
        }
        onSnapshot(OverlaySnapshot(version: version, blocks: out, animated: animated, origin: origin, time: frameTime))
        dump(out)
    }

    private var lastDump: TimeInterval = 0

    /// MWOYEO_DUMP=dir: writes what the capture saw with the overlay on top (lens outlined), at most twice a second —
    /// to check the live app without screen recording rights of one's own.
    private func dump(_ out: [OverlayBlock]) {
        guard let dir = Trace.dumpDirectory, let frame = latest else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastDump > 0.5 else { return }
        lastDump = now
        let s = scale, lens = CGRect(x: (visible.minX - origin.x) * s, y: (visible.minY - origin.y) * s,
                                     width: visible.width * s, height: visible.height * s)
        let v = version
        Task.detached(priority: .utility) {
            let w = frame.image.width, h = frame.image.height
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return }
            let H = CGFloat(h)
            ctx.draw(frame.image, in: CGRect(x: 0, y: 0, width: w, height: h))
            for b in out {
                ctx.draw(b.image, in: CGRect(x: b.frame.minX * s, y: H - b.frame.maxY * s, width: b.frame.width * s, height: b.frame.height * s))
            }
            ctx.setStrokeColor(CGColor(red: 1, green: 0.3, blue: 0.2, alpha: 1))
            ctx.setLineWidth(4)
            ctx.stroke(CGRect(x: lens.minX, y: H - lens.maxY, width: lens.width, height: lens.height))
            guard let img = ctx.makeImage() else { return }
            let url = dir.appendingPathComponent(String(format: "%06d.png", v))
            if let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(d, img, nil)
                CGImageDestinationFinalize(d)
            }
        }
    }

    private func setActivity(_ a: RegionActivity) {
        guard a != activity else { return }
        activity = a
        onActivity?(a)
    }
}

/// Stage timings on stderr when MWOYEO_TRACE is set.
enum Trace {
    static let enabled = ProcessInfo.processInfo.environment["MWOYEO_TRACE"] != nil
    static func mark(_ label: @autoclosure () -> String, since t: TimeInterval) {
        guard enabled else { return }
        let ms = Int((ProcessInfo.processInfo.systemUptime - t) * 1000)
        FileHandle.standardError.write("[trace] \(label()) \(ms) ms\n".data(using: .utf8)!)
    }
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    /// Work counters (OCR requests, erases, engine calls…), for the self-test to report.
    private static let counters = OSAllocatedUnfairLock(initialState: [String: Int]())
    static func count(_ key: String, _ n: Int = 1) { counters.withLock { $0[key, default: 0] += n } }
    static func takeCounts() -> [String: Int] { counters.withLock { defer { $0 = [:] }; return $0 } }
    static let dumpDirectory: URL? = ProcessInfo.processInfo.environment["MWOYEO_DUMP"].map { URL(fileURLWithPath: $0) }
}

extension Array {
    func partitioned(by belongs: (Element) -> Bool) -> ([Element], [Element]) {
        var yes: [Element] = [], no: [Element] = []
        for e in self { if belongs(e) { yes.append(e) } else { no.append(e) } }
        return (yes, no)
    }
}

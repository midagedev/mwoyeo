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

/// What a block reads, for the lens's own text actions (copy, transcripts): region-local frame in points (top-left
/// origin) like `OverlayBlock`, whether or not it has a rendered translation.
struct BlockText: Sendable, Equatable {
    var frame: CGRect
    var source: String
    var translation: String?
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
    /// Every block's text, rendered or not.
    var texts: [BlockText] = []
    /// The newest captured frame (nil right after the capture moved) and its image pixels per point, for saving the lens.
    var frame: CGImage?
    var scale: CGFloat = 2
    /// The drawn blocks in image pixels, in draw order, for the self-test's layout check.
    var drawn: [DrawnBlock] = []
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
    /// How text is cut into paragraphs in this lens (the app's profile over the global choice) and the app it covers.
    var paragraphReader: ParagraphReader
    var lensApp: ReaderContext

    init(_ s: AppSettings, lensApp: ReaderContext = ReaderContext()) {
        renderMode = s.renderMode
        settleDelay = s.settleDelay
        useInpainting = s.useInpaintingModel
        fontStyle = s.fontStyle
        boxOpacity = s.boxOpacity
        sourceLanguage = s.sourceLanguage
        targetLanguage = s.targetLanguage
        glossaryTerms = s.glossaryPairs.map(\.0)
        paragraphReader = AppProfiles.paragraphReader(base: s.paragraphReader, profiles: s.appProfiles, app: lensApp.bundleID)
        self.lensApp = lensApp
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
        /// Where the translation is drawn in `image`, relative to `rect` (pixels).
        var ink: CGRect?
        /// Where in `rect` the translation may be laid out, relative to `rect`; nil = all of it.
        var textArea: CGRect?
        /// Set when this block is one piece of a paragraph that goes on in the next column: `source` is the paragraph's, and the
        /// block draws its share of the one translation (`FlowSplit`).
        var part: FlowPart?
        /// What the last render drew: its font size (pixels), whether the translation needed more room than the patch has, and
        /// whether it was cut to fit.
        var drawnSize: CGFloat = 0
        var clipped = false, ellipsis = false

        /// Whether this block stands for its paragraph where blocks are listed to a person or a gate (Copy Text, the self-test's
        /// source/translation pairs): the first piece of a paragraph, or a block that is a paragraph of its own.
        var startsParagraph: Bool { (part?.index ?? 0) == 0 }
    }

    private let translator: TranslationService
    private let inpainter: Inpainter?
    private let onSnapshot: @Sendable (OverlaySnapshot) -> Void
    private var onActivity: (@Sendable (RegionActivity) -> Void)?
    private var onNotice: (@Sendable (String) -> Void)?
    private var onRead: (@Sendable (ReadTally) -> Void)?
    /// The last read found vertical text, and said so: the notice is shown once per such text, not per pass.
    private var verticalNoticed = false
    private let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "pipeline")

    private var options: PipelineOptions
    /// Which paragraph reader the lens uses now (set from `options`, kept calm by the plan).
    private let readerPlan = ReaderPlan()
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
    /// Bumped by `reset()`: a batch started under an older epoch (other language, other region) lands nowhere.
    private var translationEpoch = 0
    /// The queue rests after a failed batch; only the resume task ends it. `pauseID` tells a stale resume from the current.
    private var paused = false
    private var pauseID = 0
    private var resumeTask: Task<Void, Never>?
    private var backoff = RetryBackoff()
    private var strikes = SourceStrikes()
    /// Consecutive failed recognition passes: the next read waits, whatever the pixels do.
    private var readBackoff = ReadBackoff()
    /// This pipeline as the reader host knows it (`ReaderClients`): told when a reader it waited for, or stood in for, is ready. The
    /// session reads this client's hint (`LensSignals.recognition`) without a hop to the pipeline.
    let readerClient: Int
    /// The last pass found no reader (`RecognitionUnavailable`): nothing reads again until the host says one is ready.
    private var readerWaiting = false
    /// A reader became ready since the running seamless pass began: the frame is read once more when it ends.
    private var layoutStale = false
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
    /// The batch now with the engine: what has come back, and whether it was cut short.
    private struct Flight {
        let id: Int
        let batch: [String]
        let started: TimeInterval
        /// Sources whose result has streamed in.
        var done: Set<String> = []
        /// The batch before this one was cut because the lens was waiting: that rule stays quiet for this one.
        let afterLensPreemption: Bool
        let task: Task<TranslationOutcome, Never>
        var cut: TranslationScheduling.Preemption?
    }
    private var flight: Flight?
    private var flightID = 0
    private var lastCutByLens = false
    /// When a block that waits for translation was first seen inside the lens, to measure how long the lens waited.
    private var lensSeen: [UUID: TimeInterval] = [:]
    private var onMotion: (@Sendable () -> Void)?

    // MARK: Motion
    // How content moves relative to the lens, for what the queue may start and when it must recover. Frames stop when
    // content stops (the capture only sends changes), so the one wake task below is what notices a stop.
    /// Text velocity relative to the lens, image pixels per second, +y toward the lens's maxY. Zero when unknown (an
    /// animation, a page flip) or after the motion ends.
    private var velocity = CGVector.zero
    /// The image-pixel area that scrolls at `velocity`; nil when the whole lens moves (or the velocity is unknown).
    /// Text outside it is fixed and has no dwell limit.
    private var velocityRegion: CGRect?
    /// When the newest motion reached the pipeline (`systemUptime` clock; a frame read late counts from when it was
    /// read, since more frames of the same scroll may still be queued behind it), and the capture-time gap between the
    /// last two motion frames.
    private var lastMotionAt: TimeInterval = -.infinity
    private var lastMotionCapture: TimeInterval = -.infinity
    private var motionInterval: TimeInterval = 0
    private var wasMoving = false
    /// Capture time of the last frame of the motion that just stopped; the lens's wait for translation counts from here.
    private var settleFrom: TimeInterval?
    private var stillTask: Task<Void, Never>?
    private var lastVisibleChange: TimeInterval = 0
    /// Still = no motion for 0.35 s or 2.5 intervals between motion frames, whichever is longer: a reading-speed scroll
    /// steps every 400 ms and must not flicker between moving and still. An interval over 1 s is a new motion, not a rhythm.
    private static let stillFloor: TimeInterval = 0.35, stillFactor = 2.5, rhythmCap: TimeInterval = 1

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
        readerPlan.configure(setting: options.paragraphReader, context: options.lensApp)
        self.translator = translator
        self.inpainter = inpainter
        self.onSnapshot = onSnapshot
        let ref = WeakPipeline()
        readerClient = ReaderClients.shared.add { Task { await ref.value?.readerReady() } }
        ref.value = self
    }

    private final class WeakPipeline: @unchecked Sendable { weak var value: RegionPipeline? }

    deinit { ReaderClients.shared.remove(readerClient) }

    /// A reader is ready: either this pipeline's last pass found none (`.unavailable`), or its last layout was read with the grouper
    /// (or `.fast`) while the reader it wanted was not (the recovery re-read, design §10.4). The frame is read once more. Blocks
    /// whose text is unchanged keep their translations.
    func readerReady() {
        readerWaiting = false
        guard latest != nil else { return }
        layoutStale = true
        seamlessDone = false
        Trace.count("reader.reread")
        kick()
    }

    func setNoticeHandler(_ h: @escaping @Sendable (String) -> Void) { onNotice = h }
    /// Told after every read what it found, for the lens's "already in <language>" line.
    func setReadHandler(_ h: @escaping @Sendable (ReadTally) -> Void) { onRead = h }
    func setActivityHandler(_ h: @escaping @Sendable (RegionActivity) -> Void) { onActivity = h }
    /// Called (at most twice a second) when content moves a lot: scrolling, page flips, animation.
    func setMotionHandler(_ h: @escaping @Sendable () -> Void) { onMotion = h }
    func setScrollHandler(_ h: @escaping @Sendable (ScrollReport) -> Void) { onScroll = h }
    func setLead(_ v: CGVector) {
        guard v != lead else { return }
        lead = v
        reconsider()
        // Text the old lead held back may be eligible now.
        startQueue()
    }

    func update(options new: PipelineOptions) {
        guard new != options else { return }
        var restyled = options
        restyled.fontStyle = new.fontStyle
        restyled.boxOpacity = new.boxOpacity
        restyled.settleDelay = new.settleDelay
        let reread = restyled != new, redraw = new.fontStyle != options.fontStyle || new.boxOpacity != options.boxOpacity
        options = new
        readerPlan.configure(setting: new.paragraphReader, context: new.lensApp)
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
        stillTask?.cancel()
        wasMoving = false
        velocity = .zero
        velocityRegion = nil
        settleFrom = nil
        blocks = []
        baseGray = nil
        prevGray = nil
        forcedDirty = []
        churn.reset()
        seamlessDone = false
        pending = []
        lensSeen = [:]
        lastCutByLens = false
        // A batch still running belongs to the old settings: its results are dropped, and a new queue may start.
        translationEpoch += 1
        translating = false
        clearRecovery()
        emit(animated: false)
        if latest != nil { kick() }
    }

    /// Ends a pause and forgets failures: the queue starts from a clean slate.
    private func clearRecovery() {
        resumeTask?.cancel()
        resumeTask = nil
        paused = false
        pauseID += 1
        backoff.reset()
        strikes.reset()
        readBackoff.reset()
    }

    /// Re-translate everything currently on screen (e.g. after the user downloads a language pack).
    func refresh() {
        for i in blocks.indices { blocks[i].translation = nil; blocks[i].image = nil }
        baseGray = nil
        seamlessDone = false
        // The reason for earlier failures (a missing language pack) may be gone.
        clearRecovery()
        kick()
    }

    /// For the headless self-test: whether work is pending, and what each block reads.
    func debugState() -> (busy: Bool, translating: Bool, paused: Bool, parked: Int, blocks: [(String, String?)], flight: [String], motion: (moving: Bool, velocity: CGVector, expected: Double?), lens: (total: Int, untranslated: Int)) {
        (working || translating || settleTask != nil && !seamlessDone, translating, paused, strikes.parkedCount,
         blocks.filter(\.startsParagraph).map { ($0.source, $0.translation) }, (flight?.batch ?? []).map { source in
             let s = blocks.filter { $0.source == source }.map { TranslationScheduling.standing(of: $0.rect, lens: lensRect, lead: lead) }
             return s.contains(.lens) ? "lens" : s.contains(.leading) ? "lead" : s.isEmpty ? "gone" : "other"
         }, (isMoving(at: ProcessInfo.processInfo.systemUptime), velocity, translator.expectedSeconds(lines: 3)),
         (blocks.filter { $0.rect.intersects(lensRect) }.count, blocks.filter { $0.translation == nil && $0.rect.intersects(lensRect) }.count))
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
        scrollVelocity = nil
        scrollRect = nil
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
                if raw.ratio > 0.2 || !scrolled.isEmpty {
                    noteMotion(frame.time)
                    noteMotionFrame(captured: frame.time, velocity: scrollVelocity, region: scrollRect)
                } else {
                    velocity = CGVector(dx: velocity.dx / 2, dy: velocity.dy / 2)
                }
            }
        } else {
            lastChange = frame.time
        }
        prevGray = frame.gray
        prevValid = nil
        latest = frame
        kick()
    }

    /// The velocity the scroll regions of the frame being read gave (the largest region's).
    private var scrollVelocity: CGVector?
    private var scrollRect: CGRect?
    private var scrollArea = 0

    /// A frame (or a lens move) showed motion, at `velocity` when it is known.
    private func noteMotionFrame(captured t: TimeInterval, velocity v: CGVector?, region: CGRect? = nil) {
        let gap = max(0, t - lastMotionCapture)
        Trace.mark("motion frame gap \(Int(min(gap, 99) * 1000)) ms v=\(v.map { Int($0.dy) } ?? 0)", since: t)
        motionInterval = gap < Self.rhythmCap ? gap : 0
        if let v {
            velocity = gap < Self.rhythmCap && velocity != .zero ? CGVector(dx: (velocity.dx + v.dx) / 2, dy: (velocity.dy + v.dy) / 2) : v
            velocityRegion = region
        } else {
            velocity = .zero
            velocityRegion = nil
        }
        lastMotionCapture = t
        lastMotionAt = max(t, ProcessInfo.processInfo.systemUptime)
        wasMoving = true
        settleFrom = nil
        scheduleStill()
    }

    private var stillWindow: TimeInterval { max(Self.stillFloor, Self.stillFactor * motionInterval) }
    /// Whether content is moving, as the time-aware rules see it. `MWOYEO_PLAN=off` (for measuring against) turns the rules off:
    /// content then always counts as moving without a known speed, which is how the queue behaved before them.
    private static let planning = ProcessInfo.processInfo.environment["MWOYEO_PLAN"] != "off"
    private func isMoving(at now: TimeInterval) -> Bool { !Self.planning || !stopped(at: now) }
    private func stopped(at now: TimeInterval) -> Bool { now - lastMotionAt >= stillWindow }
    /// The velocity to plan with: known only while content moves; otherwise nil.
    private func motionVelocity(at now: TimeInterval) -> CGVector? { Self.planning && isMoving(at: now) && velocity != .zero ? velocity : nil }

    private func scheduleStill(after grace: TimeInterval? = nil) {
        stillTask?.cancel()
        let due = grace.map { ProcessInfo.processInfo.systemUptime + $0 }
            ?? max(lastMotionAt + stillWindow, ProcessInfo.processInfo.systemUptime) + 0.02
        stillTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(due - ProcessInfo.processInfo.systemUptime))
            guard !Task.isCancelled else { return }
            await self?.refreshMotion(due: due)
        }
    }

    /// Notices the end of motion (nothing else does: no frames come once content is still) and stamps it.
    private func refreshMotion(due: TimeInterval) {
        let now = ProcessInfo.processInfo.systemUptime
        guard wasMoving else { return }
        // Late: the actor was busy with a pass, so frames queued behind it have not been looked at yet. Look again
        // shortly (the stamp stays: a whole new window would delay the still decision) instead of calling it still.
        if now - due > 0.1 { scheduleStill(after: 0.05); return }
        guard stopped(at: now) else { scheduleStill(); return }
        wasMoving = false
        velocity = .zero
        velocityRegion = nil
        settleFrom = lastMotionCapture
        Trace.mark("motion stopped (window \(Int(stillWindow * 1000)) ms)", since: lastMotionCapture)
        // Nothing else changes at a stop: this is the one moment to cut a batch the still lens no longer needs and to
        // start text the motion held back.
        guard Self.planning else { return }
        reconsider()
        startQueue()
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
            // A pixel change inside the backoff waits for its end (the timer below kicks again).
            if readBackoff.isWaiting(now: now) { Trace.count("ocr.backoff_wait"); break }
            // No reader took the last pass: the host says when one is ready (`readerReady`), not a timer.
            if readerWaiting { Trace.count("ocr.reader_wait"); break }
            let stale = staleness(for: frame)
            // Seamless mode re-reads on change only, and a tile that stopped animating changed while it was left out.
            if options.renderMode == .seamless, seamlessDone, stale.change?.isUnchanged == false { seamlessDone = false }
            let settled = now - max(lastChange, lensMoved) >= options.settleDelay
            let wantsSeamless = options.renderMode != .fast && !seamlessDone && (settled || options.renderMode == .seamless)
            if wantsSeamless {
                // A failed read is not counted as done: it waits out its backoff (`noteReadFailure`) and is read again. So is a read
                // after which a reader became ready while it ran (`readerReady`).
                if await seamlessPass(frame) { seamlessDone = lastChange <= frame.time && !layoutStale }
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
        if latest != nil, let r = readBackoff.remaining(now: now) { wait = r + 0.05 }
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
            #if !MAS
            FilmDump.emit("scroll") { ["t": frame.time, "origin": [area.minX, area.minY], "step": step, "gray": FilmDump.box(g), "dy": r.dy,
                                       "strip": FilmDump.boxOrNull(strip), "frame": FilmDump.box(frame.rect), "scale": frame.scale] }
            #endif
            apply(Move(area: area, dx: 0, dy: CGFloat(r.dy) * step, gx: 0, gy: gy, grayArea: g, strip: strip))
            if scrollVelocity == nil || r.rect.width * r.rect.height > scrollArea {
                scrollArea = r.rect.width * r.rect.height
                scrollRect = area
                scrollVelocity = CGVector(dx: 0, dy: CGFloat(r.dy) * step / CGFloat(min(max(frame.time - t0, 0.016), 0.5)))
            }
            onScroll?(ScrollReport(area: CGRect(x: origin.x + area.minX / scale, y: origin.y + area.minY / scale,
                                                width: area.width / scale, height: area.height / scale),
                                   shift: CGFloat(r.dy) * step / scale, from: t0, to: frame.time))
        }
    }

    /// The visible lens (global Quartz points), for translating what the user sees first.
    /// A moving lens also holds off the settled re-read until it stops.
    func setVisible(_ rect: CGRect) {
        let now = ProcessInfo.processInfo.systemUptime
        if rect != visible {
            // A dragged lens moves the text the opposite way relative to it.
            if rect.size == visible.size {
                if now - lastVisibleChange >= Self.rhythmCap {
                    // A jump after a pause, not a drag: no speed to measure.
                    noteMotionFrame(captured: now, velocity: nil)
                } else {
                    let dt = min(max(now - lastVisibleChange, 0.016), 0.5)
                    noteMotionFrame(captured: now, velocity: CGVector(dx: -(rect.minX - visible.minX) * scale / dt, dy: -(rect.minY - visible.minY) * scale / dt))
                }
            }
            lensMoved = now
            lastVisibleChange = now
            readBackoff.reset()
        }
        visible = rect
        reconsider()
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
        readBackoff.reset()
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
        reconsider()
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
        reconsider()
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
                                                                   customWords: options.glossaryTerms, plan: readerPlan, client: readerClient)) ?? [] : []
            if found.isEmpty {
                found = try await TextRecognizer.lines(in: frame.image, roi: dirty, languages: ocrLanguages, fast: useFast,
                                                       customWords: options.glossaryTerms, client: readerClient).map { TextRecognizer.makeBlock([$0]) }
            }
        } catch {
            log.error("fast OCR failed: \(String(describing: error), privacy: .public)")
            Trace.mark("fast: OCR failed \(error)", since: t)
            // A transient (a read that timed out, programs not ready) is read again after its backoff; any other failure would just
            // fail again on the same pixels.
            if noteReadFailure(error) { _ = finishPass(start, frame: frame) }
            return
        }
        readBackoff.success()
        if holdsVerticalText(found) {
            _ = finishPass(start, frame: frame)
            return
        }
        found = readBlocks(found, in: frame.image)
        Trace.mark("fast: OCR \(Int(dirty.width))×\(Int(dirty.height))px → \(found.count) blocks", since: t)
        let verdicts = found.map { TextRecognizer.verdict($0.text, target: options.targetLanguage) }
        onRead?(TextRecognizer.tally(verdicts, partial: dirty.width < CGFloat(frame.image.width) || dirty.height < CGFloat(frame.image.height)))
        let fresh = zip(found, verdicts).filter { ocr, verdict in
            verdict == .needs && !keptRects.contains { $0.contains(CGPoint(x: ocr.rect.midX, y: ocr.rect.midY)) }
        }.map(\.0)
        let full = wantsErase ? RGBAImage(cgImage: frame.image) : nil
        let places = layoutPlaces(of: fresh, among: found, in: frame.image)
        let old = blocks.filter { staleIDs.contains($0.id) }
        let matches = BlockMatcher.match(old: old.map { .init(rect: $0.rect, text: $0.source) },
                                         new: fresh.map { .init(rect: $0.rect, text: $0.text) })
        var made: [Block] = []
        for (i, ocr) in fresh.enumerated() {
            let prior = matches[i].map { old[$0] }
            var b: Block
            if let full, let e = erase(ocr, in: full, place: places[i]) {
                b = Block(id: prior?.id ?? UUID(), rect: e.rect.cgRect, lines: ocr.lines.map(\.rect), source: ocr.text, appearance: e.look,
                          fontSize: e.fontSize, spareWidth: e.spare, textArea: e.textArea, part: ocr.part)
                b.erased = e.patch
            } else {
                let r = ocr.rect, pad = ocr.lines.map(\.rect.height).min() ?? r.height
                let boxRect = r.insetBy(dx: -max(2, pad * 0.12), dy: -max(1, pad * 0.08))
                    .intersection(CGRect(x: 0, y: 0, width: frame.image.width, height: frame.image.height))
                b = Block(id: prior?.id ?? UUID(), rect: boxRect, lines: ocr.lines.map(\.rect), source: ocr.text,
                          appearance: appearance(of: ocr.lines[0].rect, in: frame.image), part: ocr.part)
            }
            if let prior, prior.source == ocr.text { b.translation = prior.translation }
            made.append(b)
        }
        capBodySizes(&made, among: blocks.filter { !staleIDs.contains($0.id) })
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
        layoutStale = false
        let start = startPass()
        var t = Trace.now
        var found: [OCRBlock]
        do {
            found = try await TextRecognizer.blocks(in: frame.image, languages: ocrLanguages, customWords: options.glossaryTerms,
                                                    plan: readerPlan, client: readerClient)
            if found.isEmpty {
                found = try await TextRecognizer.lines(in: frame.image, languages: ocrLanguages, fast: false, client: readerClient)
                    .map { TextRecognizer.makeBlock([$0]) }
            }
        } catch {
            log.error("document OCR failed: \(String(describing: error), privacy: .public)")
            Trace.mark("seamless: OCR failed \(error)", since: t)
            guard noteReadFailure(error) else { return false }
            _ = finishPass(start, frame: frame)
            return true
        }
        readBackoff.success()
        Trace.mark("seamless: document OCR (\(found.count) blocks)", since: t); t = Trace.now
        if Trace.enabled {
            for (i, b) in found.enumerated() {
                Trace.mark("ocr-block \(i) lines: " + b.lines.map { l in "\(Int(l.rect.minX)),\(Int(l.rect.minY)),\(Int(l.rect.width)),\(Int(l.rect.height)) '\(l.text.prefix(24))'" }.joined(separator: " ; "), since: Trace.now)
            }
        }
        if holdsVerticalText(found) {
            guard finishPass(start, frame: frame) != nil else { return true }
            blocks = []
            emit(animated: false)
            return true
        }
        let read = readBlocks(found, in: frame.image)
        let verdicts = read.map { TextRecognizer.verdict($0.text, target: options.targetLanguage) }
        onRead?(TextRecognizer.tally(verdicts))
        found = zip(read, verdicts).filter { $1 == .needs }.map(\.0)
        let places = layoutPlaces(of: found, among: read, in: frame.image)
        guard let full = RGBAImage(cgImage: frame.image) else { return true }
        Trace.mark("seamless: frame → RGBA", since: t); t = Trace.now

        // Matched in the frame's coordinates: undo any move applied to the blocks since the pass started.
        let undone = blocks.map { b in moves.reversed().reduce(b.rect) { $1.undo($0) } }
        let matches = BlockMatcher.match(old: blocks.indices.map { .init(rect: undone[$0], text: blocks[$0].source) },
                                         new: found.map { .init(rect: $0.rect, text: $0.text) })
        let prior = blocks
        var next: [Block] = []
        for (i, ocr) in found.enumerated() {
            guard let e = erase(ocr, in: full, place: places[i]) else { continue }
            let id = matches[i].map { prior[$0].id } ?? UUID()
            var b = Block(id: id, rect: e.rect.cgRect, lines: ocr.lines.map(\.rect), source: ocr.text, appearance: e.look,
                          fontSize: e.fontSize, spareWidth: e.spare, textArea: e.textArea, part: ocr.part)
            if let oi = matches[i], prior[oi].source == ocr.text { b.translation = prior[oi].translation }
            b.erased = e.patch
            next.append(b)
        }
        capBodySizes(&next, among: [])
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

    /// A pass that found no reader (`RecognitionUnavailable`) waits for `readerReady`: no timer, no backoff, and the frame stays
    /// unread. Any other failed pass delays the next read (`ReadBackoff`); "programs not ready" that outlived the host's retries, or
    /// no result, is a transient of the system's recognizer and waits 1 s, doubling to 30 s per consecutive failure
    /// (`Backoff.rev3Rung`), so the minute of it after an update or a heavy compile does not pile up (design F5). True when the frame
    /// counts as read (a lasting failure: the same pixels would fail again); a transient leaves it unread, so a still picture is
    /// read again once the backoff ends instead of staying empty until something on it changes.
    private func noteReadFailure(_ error: Error) -> Bool {
        if error is RecognitionUnavailable {
            readerWaiting = true
            Trace.count("ocr.unavailable")
            Trace.mark("ocr: no reader, waiting for one", since: Trace.now)
            return false
        }
        let transient = OCRHealth.passFailureIsTransient(error)
        let wait = readBackoff.failure(now: ProcessInfo.processInfo.systemUptime, transient: transient)
        Trace.count(transient ? "ocr.failed_pass.transient" : "ocr.failed_pass")
        Trace.mark("ocr: failed pass \(readBackoff.failures), next read in \(Int(wait)) s", since: Trace.now)
        return !transient
    }

    /// Vertical text (tategaki, manga balloons) is not read yet: its lines come back as tall narrow boxes. Nothing on
    /// such a frame is translated or erased, and the lens says so once per such text.
    private func holdsVerticalText(_ found: [OCRBlock]) -> Bool {
        let tall = VerticalText.isVertical(found.flatMap(\.lines).filter { $0.text.count >= 2 }.map(\.rect))
        Trace.mark("vertical: \(tall)", since: Trace.now)
        if tall, !verticalNoticed {
            verticalNoticed = true
            onNotice?(String(localized: "Vertical text isn't supported yet"))
        }
        if !tall { verticalNoticed = false }
        return tall
    }

    /// The one chain from the recognizer's blocks to the blocks the pipeline lays out, for the lens and the seamless pass alike (design:
    /// docs/design/recognition.md section 11): lines worth reading, a paragraph that goes on in the next column cut into one block per
    /// column, split lines joined, style splits. The cut comes before the joins so that their rules see columns, not the union of two.
    /// `flowed` last: it needs to know which pieces came through the chain whole.
    private func readBlocks(_ found: [OCRBlock], in image: CGImage) -> [OCRBlock] {
        flowed(splitByStyle(joinSplitLines(columnBreak(readableLines(found, in: image))), in: image))
    }

    /// A paragraph that goes on at the top of the next column comes back as one block of lines in two columns, whose rect holds the
    /// blocks of both: it is cut at the line that starts the next column, but only when its rect holds another block (`ColumnBreak`).
    /// The pieces that carry the sentence on get a `FlowPart`; one that starts a paragraph of its own (a prompt, a heading) does not.
    private func columnBreak(_ blocks: [OCRBlock]) -> [OCRBlock] {
        guard blocks.count > 1, Self.layoutRules else { return blocks }
        let runs = ColumnBreak.pieces(blocks.map { $0.lines.map(\.rect) })
        guard runs.contains(where: { $0.count > 1 }) else { return blocks }
        var group = 0
        return blocks.enumerated().flatMap { i, block -> [OCRBlock] in
            guard runs[i].count > 1 else { return [block] }
            Trace.count("ocr.column_break")
            let pieces = runs[i].map { TextRecognizer.makeBlock($0.map { block.lines[$0] }) }
            let chain = ColumnBreak.chains(pieces.map { (first: $0.lines[0].text, last: $0.lines[$0.lines.count - 1].text) })
            Trace.mark("column break: block \(i) '\(block.text.prefix(24))' → pieces \(runs[i].map(\.count)), shared \(chain)", since: Trace.now)
            defer { group += (chain.last ?? 0) + 1 }
            return pieces.enumerated().map { k, piece in
                var piece = piece
                let mates = chain.indices.filter { chain[$0] == chain[k] }
                if mates.count > 1 { piece.part = FlowPart(group: group + chain[k], index: mates.firstIndex(of: k) ?? 0, count: mates.count) }
                return piece
            }
        }
    }

    /// The pieces of a paragraph that came through `joinSplitLines` and `splitByStyle` whole are blocks of one text, the paragraph's,
    /// so it is translated once and each piece draws its share; a paragraph that lost a piece on the way (merged with a neighbour,
    /// split by style, taken for a label) is a set of paragraphs of their own, each with its own text (`FlowSplit.resolve`).
    private func flowed(_ blocks: [OCRBlock]) -> [OCRBlock] {
        guard blocks.contains(where: { $0.part != nil }) else { return blocks }
        let parts = FlowSplit.resolve(blocks.map(\.part), characters: blocks.map(\.text.count))
        var out = blocks
        var members: [Int: [Int]] = [:]
        for i in out.indices {
            out[i].part = parts[i]
            if let part = parts[i] { members[part.group, default: []].append(i) }
        }
        for positions in members.values {
            let text = TextRecognizer.makeBlock(positions.flatMap { blocks[$0].lines }).text
            for i in positions { out[i].text = text }
        }
        return out
    }

    /// A line the recognizer could not read across (an inline sum, a fraction) comes back as pieces on one text row, in
    /// separate blocks; a tall line reaches up into the block above. Translated apart, the pieces read badly and their patches
    /// paint over each other, so blocks that share a text row or interlock (`BlockMerge`) are one block before anything else.
    private func joinSplitLines(_ blocks: [OCRBlock]) -> [OCRBlock] {
        guard blocks.count > 1, Self.layoutRules else { return blocks }
        let groups = BlockMerge.groups(blocks.map { $0.lines.map(\.rect) })
        if Trace.lineDump { traceRowPairs(blocks, groups: groups) }
        guard groups.contains(where: { $0.count > 1 }) else { return blocks }
        return groups.map { group in
            guard group.count > 1 else { return blocks[group[0]] }
            let lines = group.flatMap { blocks[$0].lines }
            if Trace.enabled { Trace.mark("merged blocks \(group): " + group.map { String(blocks[$0].text.prefix(24)) }.joined(separator: " + "), since: Trace.now) }
            return TextRecognizer.makeBlock(BlockMerge.readingOrder(lines.map(\.rect)).map { lines[$0] })
        }
    }

    /// `MWOYEO_TRACE_LINES`: the pairs of lines of different blocks that stand on one text row within three heights of each other,
    /// their gap in heights (`BlockMerge.rowGap` is the widest that joins) and whether the blocks ended up as one.
    private func traceRowPairs(_ blocks: [OCRBlock], groups: [[Int]]) {
        var group: [Int: Int] = [:]
        for (g, members) in groups.enumerated() { for m in members { group[m] = g } }
        func box(_ r: CGRect) -> String { "[\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))]" }
        for i in blocks.indices {
            for j in blocks.indices where j > i {
                for x in blocks[i].lines { for y in blocks[j].lines {
                    guard let gap = BlockMerge.rowGapBetween(x.rect, y.rect), gap > -3, gap < 3 else { continue }
                    Trace.mark("row pair \(box(x.rect)) \(box(y.rect)) gap=\(String(format: "%.2f", Double(gap))) joined=\(group[i] == group[j])", since: Trace.now)
                } }
            }
        }
    }

    /// The lines of `blocks` that are worth reading as they are; the rest are left on the picture, not translated and not erased.
    /// A line the capture cuts in two (its box reaches the top or bottom of the frame: `CaptureEdge`) is read from half of it, and
    /// its translation, drawn over the visible half, is of half a sentence: the capture is larger than the lens, so it is the
    /// frame's edge, not the lens's, that cuts, and a pass that holds the whole line reads it whole. A word turned on its side
    /// (`VerticalText.isRotatedLine`: the words of a figure) comes out as a column of syllables.
    private func readableLines(_ blocks: [OCRBlock], in image: CGImage) -> [OCRBlock] {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let all = blocks.flatMap(\.lines)
        let cut = CaptureEdge.cut(all.map(\.rect), in: bounds)
        let rotated = VerticalText.rotatedLines(all.map { (box: $0.rect, text: $0.text) })
        var first = 0
        return blocks.compactMap { block in
            defer { first += block.lines.count }
            let kept = block.lines.indices.filter { i in
                if cut.contains(first + i) { Trace.count("ocr.cut_line"); return false }
                let line = block.lines[i]
                if Trace.lineDump, line.text.count <= 3 || rotated.contains(first + i) {
                    Trace.mark("line [\(Int(line.rect.minX)),\(Int(line.rect.minY)),\(Int(line.rect.width)),\(Int(line.rect.height))] \"\(line.text)\" rotated=\(rotated.contains(first + i)) strict=\(VerticalText.isRotatedLine(line.rect, characters: line.text.count))", since: Trace.now)
                }
                if rotated.contains(first + i) { Trace.count("ocr.rotated_line"); return false }
                return true
            }
            guard kept.count < block.lines.count else { return block }
            return kept.isEmpty ? nil : TextRecognizer.makeBlock(kept.map { block.lines[$0] })
        }
    }

    /// A translation's size comes from the glyphs of its source, which stand taller in a line with subscripts and superscripts: a
    /// body-like block is not drawn larger than the body-like blocks on the screen (`BodySize`), the new ones and `kept` alike. A
    /// label is not drawn larger than its line's width says (`LabelSize`).
    private func capBodySizes(_ made: inout [Block], among kept: [Block]) {
        func item(_ b: Block) -> BodySize.Block { BodySize.Block(fontSize: b.fontSize, characters: b.source.count, lines: max(1, b.lines.count)) }
        let ceiling = BodySize.ceiling(among: (kept + made).map(item))
        for i in made.indices {
            let size = BodySize.capped(item(made[i]), ceiling: ceiling)
            let core = made[i].lines.dropFirst().reduce(made[i].lines.first ?? made[i].rect) { $0.union($1) }
            made[i].fontSize = LabelSize.capped(size, text: made[i].source, width: core.width, lines: made[i].lines.count)
        }
    }

    /// `MWOYEO_LAYOUT=off` reads and erases blocks as before the layout rules (the column break, joining split lines, `Territory`,
    /// `ColumnEdge`, the descender strip), to put the self-test's layout line of the old behaviour beside the new one.
    private static let layoutRules = ProcessInfo.processInfo.environment["MWOYEO_LAYOUT"] != "off"

    /// What one block may paint and how far right it may write.
    private struct Place {
        /// The block's patch before it is widened into free space to the right: its text, margins and a strip for descenders,
        /// less what a neighbouring block takes (`Territory`).
        var territory: CGRect
        /// The right edge of the block's column (`ColumnEdge`); nil when no other block shares it.
        var columnRight: CGFloat?
        /// Depth under the lines that is erased with them: room for descenders.
        var below: Int
    }

    /// The places of `blocks`, which are read among `read` (the columns count every block read, translated or not).
    private func layoutPlaces(of blocks: [OCRBlock], among read: [OCRBlock], in image: CGImage) -> [Place] {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let cores = blocks.map(\.rect)
        let lineHeights = blocks.map { b in b.lines.map(\.rect.height).sorted()[b.lines.count / 2] }
        let rings = lineHeights.map { CGFloat(BlockRenderer.eraseMargin(lineHeight: $0)) }
        guard Self.layoutRules else {
            return blocks.indices.map { i in
                Place(territory: cores[i].insetBy(dx: -rings[i], dy: -rings[i]).intersection(bounds), columnRight: nil, below: Int(rings[i]))
            }
        }
        let wants = blocks.indices.map { Territory.want(core: cores[$0], lineHeight: lineHeights[$0], ring: rings[$0]).intersection(bounds) }
        let territories = Territory.trim(cores: cores, wants: wants)
        // A territory under half of its core leaves the block drawn in half of its place, or (a patch of 0-1 px) not at all with its
        // source still on the page: counted and traced, never silent.
        for i in blocks.indices where Territory.squeezed(core: cores[i], territory: territories[i]) {
            Trace.count("layout.squeezed")
            Trace.mark("layout: squeezed block \(i) '\(blocks[i].text.prefix(24))' core \(TraceNumber.px(cores[i].minX)),\(TraceNumber.px(cores[i].minY)) "
                       + "\(TraceNumber.px(cores[i].width))x\(TraceNumber.px(cores[i].height)) territory \(TraceNumber.px(territories[i].minX)),\(TraceNumber.px(territories[i].minY)) "
                       + "\(TraceNumber.px(territories[i].width))x\(TraceNumber.px(territories[i].height))", since: Trace.now)
        }
        let others = read.map(\.rect)
        return blocks.indices.map { i in
            Place(territory: territories[i], columnRight: ColumnEdge.right(of: cores[i], among: others.filter { $0 != cores[i] }),
                  below: Int(Territory.below(lineHeight: lineHeights[i], ring: rings[i])))
        }
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
            let made = parts.filter { !$0.isEmpty }.flatMap { lines -> [OCRBlock] in
                guard lines.count > 1 else { return [TextRecognizer.makeBlock(lines)] }
                let styles = lines.map { (color: appearance(of: $0.rect, in: image).textColor, size: LineSize.Line(height: $0.rect.height, width: $0.rect.width, text: $0.text)) }
                if Trace.enabled {
                    Trace.mark("sizes: " + lines.map { l in "h\(Int(l.rect.height)) w\(Int(l.rect.width)) n\(l.text.count) '\(l.text.prefix(14))'" }.joined(separator: " ; "), since: Trace.now)
                }
                var groups: [[OCRLine]] = [[lines[0]]]
                for i in 1..<lines.count {
                    let a = styles[i - 1], b = styles[i]
                    if a.color.distance(to: b.color) > 60 || LineSize.differ(a.size, b.size) || ParagraphMarker.startsItem(lines[i].text) { groups.append([]) }
                    groups[groups.count - 1].append(lines[i])
                }
                return groups.map(TextRecognizer.makeBlock)
            }
            // A piece of a paragraph that goes on in the next column stays one only if the style pass left it whole.
            guard made.count == 1, let part = block.part else { return made }
            var whole = made[0]
            whole.part = part
            return [whole]
        }
        let items = split.map { LabelRule.Item(rect: $0.rect, text: $0.text, color: appearance(of: $0.lines[0].rect, in: image).textColor,
                                                 lineHeight: $0.lines[0].rect.height) }
        let labels = LabelRule.labels(items)
        if Trace.enabled {
            Trace.mark("items: " + items.enumerated().map { "\($0.offset)\(labels.contains($0.offset) ? "*" : "") '\($0.element.text.prefix(10))' \(Int($0.element.rect.minX)),\(Int($0.element.rect.minY)) \(Int($0.element.rect.width))x\(Int($0.element.rect.height)) lh\(Int($0.element.lineHeight)) c\($0.element.color.r),\($0.element.color.g),\($0.element.color.b)" }.joined(separator: " ; "), since: Trace.now)
        }
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
        /// Where in `rect` a translation is laid out (pixels, relative to `rect`).
        var textArea: CGRect
    }

    /// Erases a block's text: builds the glyph mask per line, then fills it (flat backgrounds) or inpaints it
    /// (textured ones). The patch also takes in free background to the right for longer translations, up to the
    /// right edge of the block's column, and covers the descenders of its lines; it stays inside the block's `place`.
    private func erase(_ block: OCRBlock, in full: RGBAImage, place: Place) -> Erased? {
        Trace.count("erase")
        let lineHeight = block.lines.map(\.rect.height).sorted()[block.lines.count / 2]
        let ring = BlockRenderer.eraseMargin(lineHeight: lineHeight)
        let below = place.below
        var rect = PixelRect(place.territory).clamped(width: full.width, height: full.height)
        guard !rect.isEmpty else { return nil }

        var masks: [(PixelRect, TextMask)] = []
        var glyphHeights: [CGFloat] = []
        for line in block.lines {
            // The strip under a line is as deep as its descenders: a tail that ends past the crop would count as a glyph
            // running off the patch and stay.
            let crop = CGRect(x: line.rect.minX - CGFloat(ring), y: line.rect.minY - CGFloat(ring),
                              width: line.rect.width + CGFloat(2 * ring), height: line.rect.height + CGFloat(ring + below))
            let lr = PixelRect(crop).clamped(width: full.width, height: full.height)
            guard !lr.isEmpty else { continue }
            let text = PixelRect(line.rect).clamped(width: full.width, height: full.height)
            let local = PixelRect(x: text.x - lr.x, y: text.y - lr.y, width: text.width, height: text.height)
            let m = TextEraser.mask(for: full.cropped(to: lr), textRect: local, dilation: max(1, Int(line.rect.height * 0.07)), outlines: true, frames: true)
            masks.append((lr, m))
            if let g = m.glyphBounds { glyphHeights.append(CGFloat(g.height)) }
        }
        // Prefer a line whose glyphs were actually segmented over a whole-box fallback.
        guard let look = masks.map(\.1.appearance).first(where: { $0.coverage < 0.95 }) ?? masks.first?.1.appearance else { return nil }

        // Free background to the right ends at the column's edge: the text may use it up to there, not the page's margin.
        let reach = place.columnRight.map { max(0, Int($0 - block.rect.maxX)) }
        let spare = freeWidth(rightOf: rect, in: full, background: look.backgroundColor, atMost: reach)
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
        #if MAS
        let maskOnly = false
        #else
        let maskOnly = ProcessInfo.processInfo.environment["MWOYEO_ERASE_ONLY"] == "mask"
        #endif
        if maskOnly {
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
        #if !MAS
        // `MWOYEO_FILM_DUMP=erase` (tools/film/DESIGN.md, H2): what the erase saw per line (the noise that decides flat or patterned) and what it did. The
        // dilation is the median line's; `fill` is the branch taken above (a model that throws falls back to the flat fill without saying so here).
        FilmDump.emit("erase") {
            ["block": FilmDump.box(block.rect), "patch": FilmDump.box(rect), "ring": ring, "dilation": max(1, Int(lineHeight * 0.07)),
             "lines": masks.map { ["crop": FilmDump.box($0.0), "noise": $0.1.appearance.backgroundNoise, "flat": $0.1.appearance.isFlatBackground] as [String: Any] },
             "fill": maskOnly ? "mask" : !flat && options.useInpainting && inpainter != nil ? "inpaint" : "fill"]
        }
        #endif
        let glyph = glyphHeights.isEmpty ? nil : glyphHeights.sorted()[glyphHeights.count / 2]
        if Trace.lineDump, block.text.count <= 16 {
            Trace.mark("erase label [\(Int(block.rect.minX)),\(Int(block.rect.minY)),\(Int(block.rect.width)),\(Int(block.rect.height))] lines=\(block.lines.count) line=\(Int(lineHeight)) glyph=\(glyph.map { Int($0) } ?? -1) \"\(block.text)\"", since: Trace.now)
        }
        let area = Territory.textArea(core: block.rect, ring: CGFloat(ring), spare: CGFloat(spare), in: rect.cgRect)
            .offsetBy(dx: -CGFloat(rect.x), dy: -CGFloat(rect.y))
        return Erased(rect: rect, patch: patch, look: look, fontSize: glyph.map { Self.emSize(glyphHeight: $0, text: block.text) },
                      spare: CGFloat(spare), textArea: area)
    }

    /// Columns to the right of `rect` that hold nothing but the background colour (up to 80 % more width, and `atMost`).
    private func freeWidth(rightOf rect: PixelRect, in full: RGBAImage, background: RGBA, atMost: Int? = nil) -> Int {
        let limit = min(full.width - (rect.x + rect.width), Int(Double(rect.width) * 0.8), atMost ?? .max)
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
            } else if !strikes.isParked(blocks[i].source) {
                pending.insert(blocks[i].source)
            }
        }
        reconsider()
        startQueue()
    }

    /// The document this lens covers (its app, category and confirmed window title), once the session read its window; nil while the
    /// settings cannot put context on. Set by `RegionSession`; screen text is not in it.
    private var lensContext: LensContext?

    func setLensContext(_ c: LensContext?) { lensContext = c }

    /// The context of one batch: the lens's window with the lines around the batch on screen, put in reading order by their rects.
    /// nil when no window was read, and the batch goes the old way.
    private func documentContext(around batch: [String]) -> LensContext? {
        lensContext?.around(batch, lines: blocks.map { ContextNeighbours.Line(source: $0.source, rect: $0.rect) })
    }

    private func startQueue() {
        // While the queue rests, only the resume task starts it again.
        guard !paused, !translating, !pending.isEmpty else { return }
        translating = true
        if lensPending { setActivity(.translating) }
        Task { await translateQueue() }
    }

    /// Translates a few lines at a time, always picking again what the lens shows first: the queue keeps up with a
    /// moving lens instead of finishing text that has already scrolled out of view.
    private func translateQueue() async {
        let epoch = translationEpoch
        while let batch = nextBatch() {
            let t = Trace.now
            flightID += 1
            let id = flightID, service = translator
            let context = documentContext(around: batch)
            // A task of its own, so a batch the lens no longer needs can be cancelled while this one awaits it.
            let task = Task {
                await service.translate(batch, context: context) { source, translated in
                    Task { await self.streamed(source, translated, epoch: epoch, flight: id) }
                }
            }
            flight = Flight(id: id, batch: batch, started: ProcessInfo.processInfo.systemUptime, afterLensPreemption: lastCutByLens, task: task)
            reconsider()
            let outcome = await task.value
            if flight?.id == id {
                lastCutByLens = flight?.cut == .lensWaiting
                flight = nil
            }
            Trace.mark("translate ×\(batch.count)" + (outcome.cancelled ? " cancelled" : ""), since: t)
            // Settings changed meanwhile: `reset()` already cleared the queue state, and this result is for the old ones.
            guard epoch == translationEpoch else { return }
            receive(outcome.translations, epoch: epoch)
            for source in batch {
                // A cut batch's unfinished sources stay queued; `nextBatch` drops those that left the screen.
                if outcome.cancelled, outcome.translations[source] == nil { continue }
                pending.remove(source)
                if outcome.translations[source] != nil {
                    strikes.clear(source)
                } else if outcome.failed.contains(source) {
                    if !strikes.strike(source) { pending.insert(source) }
                } else if outcome.batchFailed {
                    pending.insert(source)
                }
            }
            if outcome.batchFailed {
                rest(now: ProcessInfo.processInfo.systemUptime)
                return
            }
            // A cancelled batch is not an answer from the engine: the backoff stays as it was.
            if !outcome.cancelled { backoff.success() }
            // The overscan keeps translating quietly; "translating" is only what the lens is waiting for.
            if !working { setActivity(lensPending ? .translating : .idle) }
        }
        translating = false
        if !working { setActivity(.idle) }
    }

    /// Stops the queue for the backoff time and schedules the one task that restarts it, with or without a new frame.
    private func rest(now: TimeInterval) {
        let pause = backoff.failure(now: now)
        translating = false
        paused = true
        pauseID += 1
        let id = pauseID
        if !working { setActivity(.idle) }
        resumeTask?.cancel()
        resumeTask = Task {
            do { try await Task.sleep(for: .seconds(pause)) } catch { return }
            self.resumeQueue(id)
        }
    }

    private func resumeQueue(_ id: Int) {
        guard paused, id == pauseID else { return }
        resumeTask = nil
        paused = false
        fillTranslations()
    }

    /// Cancels the running batch when nothing in it is worth finishing any more. Re-checked wherever blocks, lens, lead
    /// or results change, never on a timer.
    private func checkPreempt() {
        guard let f = flight, f.cut == nil else { return }
        let lens = lensRect, now = ProcessInfo.processInfo.systemUptime
        let moving = isMoving(at: now)
        let planned = translator.expectedSeconds(lines: 1) == nil ? nil : motionVelocity(at: now)
        // Once content is still, `lead` only ranks the overscan: text on the leading side is no longer on its way in.
        let lead = moving ? lead : .zero
        let unfinished = f.batch.filter { !f.done.contains($0) && translator.cached($0) == nil }
        let standings = unfinished.map { source -> TranslationScheduling.Standing in
            let s = blocks.filter { $0.source == source && $0.translation == nil }
                .map { TranslationScheduling.standing(of: $0.rect, lens: lens, lead: lead) }
            return s.contains(.lens) ? .lens : s.contains(.leading) ? .leading : s.isEmpty ? .gone : .other
        }
        let batch = Set(f.batch)
        let lensWaiting = blocks.contains { $0.translation == nil && $0.rect.intersects(lens) && pending.contains($0.source) && !batch.contains($0.source) }
        var why = TranslationScheduling.preemption(unfinished: standings, lensWaiting: lensWaiting,
                                                   afterLensPreemption: f.afterLensPreemption, moving: moving)
        if why == nil, let v = planned, !unfinished.isEmpty {
            // What the engine can still deliver, against how long each source stays in the lens.
            let dwells = unfinished.map { source in
                blocks.filter { $0.source == source && $0.translation == nil }
                    .map { TranslationScheduling.dwell(of: $0.rect, lens: lens,
                                                       velocity: TranslationScheduling.velocity(of: $0.rect, v, scrollRegion: velocityRegion)) ?? .infinity }.max() ?? 0
            }
            if let region = velocityRegion,
               unfinished.contains(where: { s in blocks.contains { $0.source == s && $0.translation == nil && !$0.rect.intersects(region) } }) {
                Trace.count("translate.outside_scroll_kept")
            }
            let remaining = translator.remainingSeconds(lines: unfinished.count + f.done.count, delivered: f.done.count,
                                                        elapsed: now - f.started) ?? 0
            if TranslationScheduling.tooLate(dwells: dwells, remaining: remaining) { why = .tooLate }
        }
        guard let why else { return }
        flight?.cut = why
        Trace.count("translate.cancelled")
        Trace.mark("translate cancelled (\(why)): \(standings)", since: Trace.now)
        f.task.cancel()
    }

    private func reconsider() {
        noteLens()
        checkPreempt()
    }

    /// The visible lens in image pixels.
    private var lensRect: CGRect {
        CGRect(x: (visible.minX - origin.x) * scale, y: (visible.minY - origin.y) * scale,
               width: visible.width * scale, height: visible.height * scale)
    }

    /// Measures the lens's wait: when text first stands in the lens untranslated, and when it is translated there or
    /// leaves it (or the capture) without. Called wherever blocks, lens or translations change.
    private func noteLens() {
        let now = Trace.now, lens = lensRect
        if !lensSeen.isEmpty {
            let byID = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for (id, t0) in lensSeen {
                guard let b = byID[id] else { lensSeen[id] = nil; Trace.count("translate.lens_unserved"); continue }
                if b.translation != nil {
                    lensSeen[id] = nil
                    if b.rect.intersects(lens) { Trace.sample("translate.lens_wait_ms", (now - t0) * 1000) } else { Trace.count("translate.lens_unserved") }
                } else if !b.rect.intersects(lens) {
                    lensSeen[id] = nil
                    Trace.count("translate.lens_unserved")
                }
            }
        }
        for b in blocks where b.translation == nil && lensSeen[b.id] == nil && b.rect.intersects(lens) { lensSeen[b.id] = now }
        if let from = settleFrom, !blocks.contains(where: { $0.translation == nil && $0.rect.intersects(lens) }) {
            settleFrom = nil
            Trace.sample("translate.settle_ms", (now - from) * 1000)
        }
    }

    private var lensPending: Bool {
        blocks.contains { $0.translation == nil && pending.contains($0.source) && priority($0.rect).0 == 0 }
    }

    private func nextBatch() -> [String]? {
        // Forget text that is gone or already translated.
        pending.formIntersection(blocks.filter { $0.translation == nil }.map(\.source))
        guard !pending.isEmpty else { return nil }
        let lens = lensRect, now = ProcessInfo.processInfo.systemUptime
        // While content moves at a known speed, start only what will still be in the lens when the engine is done; the
        // rest waits (every pass looks again) until the motion slows or stops.
        // Rules that need the engine's pace stay off until its first result has been seen.
        if let v = motionVelocity(at: now), translator.expectedSeconds(lines: 1) != nil {
            let candidates = blocks.filter { $0.translation == nil && pending.contains($0.source) }
                .map { TranslationScheduling.Candidate(source: $0.source, rect: $0.rect) }
            let batch = TranslationScheduling.batch(from: candidates, lens: lens, velocity: v, scrollRegion: velocityRegion, limit: 3,
                                                    expectedSeconds: { [translator] in translator.expectedSeconds(lines: $0) ?? 0 })
            if let region = velocityRegion,
               batch.contains(where: { s in candidates.contains { $0.source == s && !$0.rect.intersects(region) } }) {
                Trace.count("translate.outside_scroll_admitted")
            }
            return batch.isEmpty ? nil : batch
        }
        var seen = Set<String>()
        // Motion without a speed (an animation, a page flip) still holds back text it has left far behind; `fillTranslations`
        // re-queues it on every pass. Once content is still, `lead` ranks the overscan only and holds nothing back.
        let moving = isMoving(at: now)
        let ordered = blocks.filter { !(moving && TranslationScheduling.isTrailing($0.rect, lens: lens, lead: lead)) }
            .sorted { priority($0.rect) < priority($1.rect) }.map(\.source)
            .filter { pending.contains($0) && seen.insert($0).inserted }
        return Array(ordered.prefix(3))
    }

    /// What the lens shows comes first, in reading order; then the overscan, nearest first.
    private func priority(_ r: CGRect) -> (Int, CGFloat) {
        let lens = lensRect
        if r.intersects(lens) { return (0, r.minY) }
        let dx = max(lens.minX - r.maxX, r.minX - lens.maxX, 0), dy = max(lens.minY - r.maxY, r.minY - lens.maxY, 0)
        // Text on the side things are heading to (a dragged lens, content scrolling in) reaches the lens first.
        let side = CGVector(dx: r.midX < lens.minX ? -1 : r.midX > lens.maxX ? 1 : 0, dy: r.midY < lens.minY ? -1 : r.midY > lens.maxY ? 1 : 0)
        return (1, hypot(dx, dy) / (1 + max(0, side.dx * lead.dx + side.dy * lead.dy)))
    }

    /// One result streamed from the engine; counts it as wasted when its text left the capture meanwhile.
    private func streamed(_ source: String, _ translated: String, epoch: Int, flight id: Int) {
        guard epoch == translationEpoch else { return }
        if flight?.id == id { flight?.done.insert(source) }
        let lens = lensRect
        let standings = blocks.filter { $0.source == source && $0.translation == nil }
            .map { TranslationScheduling.standing(of: $0.rect, lens: lens, lead: lead) }
        if !blocks.contains(where: { $0.source == source }) { Trace.count("translate.wasted") }
        else if !standings.isEmpty, standings.allSatisfy({ $0 == .other }) { Trace.count("translate.landed_outside") }
        receive([source: translated], epoch: epoch)
    }

    private func receive(_ result: [String: String], epoch: Int) {
        guard epoch == translationEpoch else { return }
        var changed = false
        for i in blocks.indices {
            guard let t = result[blocks[i].source], blocks[i].translation != t else { continue }
            blocks[i].translation = t
            blocks[i].image = nil
            changed = true
        }
        reconsider()
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
            guard let translation = b.translation, !translation.isEmpty, translation != b.source else { continue }
            // A piece of a paragraph that goes on in the next column draws its share of the paragraph's one translation.
            let text = b.part.map { FlowSplit.share(of: translation, part: $0) } ?? translation
            guard !text.isEmpty else { continue }
            let heights = b.lines.map(\.height).sorted()
            let lineHeight = heights.isEmpty ? b.rect.height : heights[heights.count / 2]
            let background: BlockRenderer.Background = b.erased.map { .erased($0) }
                ?? .box(b.appearance.backgroundColor, opacity: options.boxOpacity)
            Trace.count("render")
            let rendered = BlockRenderer.render(.init(
                size: b.rect.size, text: text, background: background, appearance: b.appearance,
                lineHeight: lineHeight, fontSize: b.fontSize, originalLineCount: max(1, b.lines.count), spareWidth: b.spareWidth,
                fontStyle: options.fontStyle,
                targetLanguage: options.targetLanguage, scale: scale,
                centered: LineAlignment.isCentered(b.lines.map { ($0.minX, $0.maxX) }, outlined: b.appearance.outlineColor != nil),
                textArea: b.textArea))
            blocks[i].image = rendered?.image
            blocks[i].ink = rendered?.text
            blocks[i].drawnSize = rendered?.fontSize ?? 0
            blocks[i].clipped = rendered?.clipped ?? false
            blocks[i].ellipsis = rendered?.ellipsis ?? false
            if Trace.enabled, let ink = rendered?.text {
                Trace.mark("render '\(b.source.prefix(24))' patch \(TraceNumber.px(b.rect.minX)),\(TraceNumber.px(b.rect.minY)) \(TraceNumber.px(b.rect.width))x\(TraceNumber.px(b.rect.height)) spare \(TraceNumber.px(b.spareWidth)) "
                    + "area \(b.textArea.map { "\(TraceNumber.px($0.minX)),\(TraceNumber.px($0.minY)) \(TraceNumber.px($0.width))x\(TraceNumber.px($0.height))" } ?? "-") ink \(TraceNumber.px(ink.minX)),\(TraceNumber.px(ink.minY)) \(TraceNumber.px(ink.width))x\(TraceNumber.px(ink.height))",
                    since: Trace.now)
            }
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
        let texts = blocks.filter(\.startsParagraph).map { BlockText(frame: CGRect(x: $0.rect.minX / s, y: $0.rect.minY / s, width: $0.rect.width / s, height: $0.rect.height / s),
                                           source: $0.source, translation: $0.translation) }
        // What the self-test's layout line counts: every drawn block, in draw order.
        let drawn = blocks.compactMap { b -> DrawnBlock? in
            guard b.image != nil else { return nil }
            let core = b.lines.dropFirst().reduce(b.lines.first ?? b.rect) { $0.union($1) }
            let text = b.ink.map { $0.offsetBy(dx: b.rect.minX, dy: b.rect.minY) } ?? b.rect
            return DrawnBlock(source: b.source, core: core, patch: b.rect, text: text, fontSize: b.drawnSize, lines: max(1, b.lines.count), clipped: b.clipped,
                              ellipsis: b.ellipsis)
        }
        onSnapshot(OverlaySnapshot(version: version, blocks: out, animated: animated, origin: origin, time: frameTime,
                                   texts: texts, frame: latest?.image, scale: s, drawn: drawn))
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
    /// Measured values (ms…), for the self-test to summarise.
    private static let samples = OSAllocatedUnfairLock(initialState: [String: [Double]]())
    static func sample(_ key: String, _ v: Double) { samples.withLock { $0[key, default: []].append(v) } }
    static func takeSamples() -> [String: [Double]] { samples.withLock { defer { $0 = [:] }; return $0 } }
    /// `MWOYEO_TRACE_LINES` adds the recognized lines of every automatic reader decision to the trace (tools/usecase-bench/tune.sh).
    static let lineDump = enabled && ProcessInfo.processInfo.environment["MWOYEO_TRACE_LINES"] != nil
    #if MAS
    static let dumpDirectory: URL? = nil
    #else
    static let dumpDirectory: URL? = ProcessInfo.processInfo.environment["MWOYEO_DUMP"].map { URL(fileURLWithPath: $0) }
    #endif
}

extension Array {
    func partitioned(by belongs: (Element) -> Bool) -> ([Element], [Element]) {
        var yes: [Element] = [], no: [Element] = []
        for e in self { if belongs(e) { yes.append(e) } else { no.append(e) } }
        return (yes, no)
    }
}

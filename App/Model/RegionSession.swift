import AppKit
import MwoyeoCore
import os

/// Runs one region: capture → pipeline → overlay, plus the draggable lens chrome around it, and keeps it
/// glued to its window when anchored.
///
/// The capture is larger than the lens (overscan): the text around it is read and translated ahead, so dragging the
/// lens or scrolling reveals translations that are already there. The margin widens while things move, and more of it
/// lies where things are heading; the lens moves freely inside it and the capture only re-centres when the lens nears
/// its edge.
///
/// Scroll events over the capture predict where the content is going before the frames show it, so the translations
/// move with the page like the page moves with the finger.
@MainActor
final class RegionSession {
    private(set) var config: RegionConfig
    private(set) var activity = RegionActivity.idle
    private(set) var errorMessage: String?
    var onChange: (() -> Void)?
    /// The region's rect or anchor changed (lens dragged, window followed); persist it.
    var onConfigChange: ((RegionConfig) -> Void)?
    var onCloseRequest: (() -> Void)?
    /// "Show Original" is the app's, not this lens's: the menu item asks the app.
    var onToggleOriginal: (() -> Void)?

    private let capturer = RegionCapturer()
    private let pipeline: RegionPipeline
    private let panel: OverlayPanel
    private let chrome: RegionFrameWindow
    private var fps: Double
    private var trackTimer: Timer?
    private var mouseMonitors: [Any] = []
    private var hiddenByOcclusion = false
    /// The followed window was seen alive in this session (so its ID is not just stale from a relaunch).
    private var anchorSeen = false
    private var translationsVisible = true
    private var dragging = false
    private var captureUpdateRunning = false
    private var captureUpdatePending = false
    /// Captured rect, global Quartz points; contains `config.rect` (the visible lens).
    private var capture: CGRect
    private var wideMargins = false
    private var lastMotion: TimeInterval = 0
    private var calmTimer: Timer?
    /// The dot and glow follow translating only, settled by `BusyDebounce`; notices pass `NoticeGate`.
    private var busyDebounce = BusyDebounce()
    private var busyTimer: Timer?
    private var noticeGate = NoticeGate()
    /// Where things are heading (-1…1 per axis): the lens while dragged, new content while the page scrolls.
    private var lead = CGVector.zero
    private var lastLens: (rect: CGRect, time: TimeInterval)?
    private var predictor = ScrollPredictor()
    /// The area under the pointer that scrolled last (global Quartz points), and the window it belongs to.
    private var scrollArea: CGRect?
    private var scrollWindow: CGWindowID?
    private var lastWheel: TimeInterval = 0
    private let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "session")
    private var settings: AppSettings
    /// The newest snapshot: what the lens's own actions (copy, save, transcripts) work from.
    private var lastSnapshot: OverlaySnapshot?
    private var transcript: TranscriptWriter?
    private var transcriptBegan: TimeInterval = 0
    private var transcriptTimer: Timer?
    private var transcriptAppChecked: TimeInterval = 0

    /// Hands the pipeline's snapshots to the session once it exists (the pipeline is built inside `init`).
    @MainActor private final class SnapshotTap { var handler: ((OverlaySnapshot) -> Void)? }

    init(config: RegionConfig, settings: AppSettings, translator: TranslationService, inpainter: Inpainter?) {
        self.config = config
        self.fps = settings.framesPerSecond
        self.settings = settings
        let frame = ScreenGeometry.appKitRect(fromQuartz: config.rect)
        let panel = OverlayPanel(frame: frame)
        self.panel = panel
        chrome = RegionFrameWindow(region: frame, name: config.name)
        chrome.setDetail(Self.languagePair(settings), badge: settings.activeEngineConfig?.badgeSymbol)
        chrome.setFollowing(config.anchor != nil)
        chrome.setStyle(settings.lensStyle)
        let capture = Self.overscan(config.rect, wide: false)
        self.capture = capture
        let tap = SnapshotTap()
        pipeline = RegionPipeline(options: PipelineOptions(settings, lensApp: AppModel.readerContext(for: config)), capture: capture, translator: translator,
                                  inpainter: inpainter, onSnapshot: { snapshot in Task { @MainActor in panel.apply(snapshot); tap.handler?(snapshot) } })
        capturer.onFrame = { [pipeline] frame in Task { await pipeline.ingest(frame) } }
        capturer.onStop = { [weak self] error in Task { @MainActor in self?.captureStopped(error) } }
        wireChrome()
        tap.handler = { [weak self] in self?.received($0) }
    }

    func start() async {
        await pipeline.setActivityHandler { [weak self] a in Task { @MainActor in self?.setActivity(a) } }
        await pipeline.setMotionHandler { [weak self] in Task { @MainActor in self?.noteMotion() } }
        await pipeline.setScrollHandler { [weak self] r in Task { @MainActor in self?.scrolled(r) } }
        panel.prediction = { [weak self] since, now in self?.predictedScroll(since: since, now: now) }
        await pipeline.setVisible(config.rect)
        panel.orderFrontRegardless()
        chrome.orderFrontRegardless()
        panel.setTranslationsVisible(translationsVisible, animated: false)
        chrome.setOriginal(!translationsVisible)
        do {
            try await capturer.start(rect: capture, fps: fps)
            errorMessage = nil
            chrome.sweep()
        } catch {
            errorMessage = String(localized: "Couldn’t start capturing: \(error.localizedDescription)")
            log.error("capture start failed: \(error.localizedDescription)")
        }
        startTracking()
        watchPointer()
        onChange?()
    }

    func stop() async {
        trackTimer?.invalidate()
        trackTimer = nil
        calmTimer?.invalidate()
        calmTimer = nil
        busyTimer?.invalidate()
        busyTimer = nil
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors = []
        finishTranscript()
        Speaker.shared.stop(config.id)
        await capturer.stop()
        panel.orderOut(nil)
        chrome.orderOut(nil)
    }

    /// A quiet line on the lens's pill for a few seconds.
    func showNotice(_ text: String, seconds: TimeInterval = 6) {
        guard noticeGate.allow(text, now: ProcessInfo.processInfo.systemUptime) else { return }
        chrome.flash(text, seconds: seconds)
    }

    private static func languagePair(_ s: AppSettings) -> String {
        "\(s.sourceLanguage == "auto" ? String(localized: "Auto") : Languages.name(s.sourceLanguage)) → \(Languages.name(s.targetLanguage))"
    }

    func update(settings: AppSettings) async {
        let before = self.settings
        self.settings = settings
        if !settings.savesTranscripts || settings.exportFolder != before.exportFolder
            || settings.sourceLanguage != before.sourceLanguage || settings.targetLanguage != before.targetLanguage
            || settings.transcriptFormats != before.transcriptFormats || settings.activeEngineConfig?.id != before.activeEngineConfig?.id {
            finishTranscript()
        }
        chrome.setDetail(Self.languagePair(settings), badge: settings.activeEngineConfig?.badgeSymbol)
        chrome.setStyle(settings.lensStyle)
        await pipeline.update(options: PipelineOptions(settings, lensApp: AppModel.readerContext(for: config)))
        if settings.framesPerSecond != fps {
            fps = settings.framesPerSecond
            try? await capturer.update(rect: capture, fps: fps)
        }
    }

    func refresh() async { await pipeline.refresh() }

    func setTranslationsVisible(_ visible: Bool) {
        translationsVisible = visible
        panel.setTranslationsVisible(visible && !hiddenByOcclusion)
        chrome.setOriginal(!visible)
    }

    /// Window lens ↔ screen lens. A screen lens follows the window under its centre, if there is one.
    private func toggleFollowing() {
        if config.anchor != nil {
            follow(nil)
        } else if let w = windowUnderLens() {
            follow(w)
        } else {
            NSSound.beep()
            return
        }
        onConfigChange?(config)
    }

    /// The app under the lens changed (dropped on another window, followed another): the pipeline's options carry it.
    private func refreshReaderContext() {
        let options = PipelineOptions(settings, lensApp: AppModel.readerContext(for: config))
        Task { [pipeline] in await pipeline.update(options: options) }
    }

    private func follow(_ w: WindowInfo?) {
        config.follow(w)
        chrome.setName(config.name)
        chrome.setFollowing(w != nil)
        startTracking()
    }

    private func windowUnderLens() -> WindowInfo? {
        WindowInfo.onScreen().first { $0.bounds.contains(CGPoint(x: config.rect.midX, y: config.rect.midY)) }
    }

    private func setActivity(_ a: RegionActivity) {
        guard a != activity else { return }
        activity = a
        settleBusy()
        onChange?()
    }

    private func settleBusy() {
        let now = ProcessInfo.processInfo.systemUptime
        chrome.setBusy(busyDebounce.update(activity == .translating, now: now))
        busyTimer?.invalidate()
        busyTimer = nil
        guard let due = busyDebounce.nextChange else { return }
        busyTimer = Timer.scheduledTimer(withTimeInterval: max(0, due - now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.settleBusy() }
        }
    }

    private func captureStopped(_ error: Error?) {
        guard let error else { return }
        errorMessage = error.localizedDescription
        onChange?()
    }

    // MARK: - Keeping what the lens read

    /// Whether the lens (global Quartz points) is under `point`.
    func contains(_ point: CGPoint) -> Bool { config.rect.contains(point) }

    private func received(_ snapshot: OverlaySnapshot) {
        lastSnapshot = snapshot
        observeTranscript()
    }

    private func lensBlocks() -> [BlockText] {
        lastSnapshot.map { LensText.inLens($0, lens: config.rect) } ?? []
    }

    func copyOriginal() {
        let lines = LensText.originals(lensBlocks())
        guard !lines.isEmpty else { return NSSound.beep() }
        LensText.copy(lines)
        chrome.flash(String(localized: "Copied"))
    }

    func copyTranslation() {
        let lines = LensText.translations(lensBlocks())
        guard !lines.isEmpty else { return NSSound.beep() }
        LensText.copy(lines)
        chrome.flash(String(localized: "Copied"))
    }

    /// Reads the translations in the lens aloud, or stops if this lens is already reading.
    func toggleReadAloud() {
        if Speaker.shared.isReading(config.id) { return Speaker.shared.stop(config.id) }
        let lines = LensText.translations(lensBlocks())
        guard !lines.isEmpty, let voice = Speaker.voice(for: settings.targetLanguage) else { return NSSound.beep() }
        Speaker.shared.read(lines, voice: voice, for: config.id)
    }

    /// The latest captured frame cropped to the lens, with the translations on it as the lens shows them.
    func saveLensImage() {
        guard let s = lastSnapshot, let frame = s.frame else { return NSSound.beep() }
        let showing = translationsVisible && !hiddenByOcclusion
        let layers = showing ? s.blocks.map { LensImage.Layer(frame: $0.frame, image: $0.image) } : []
        let crop = config.rect.offsetBy(dx: -s.origin.x, dy: -s.origin.y)
        let folder = LensExport.capturesFolder(settings.exportFolder), name = LensExport.fileName(config.name), now = Date()
        Task.detached(priority: .utility) { [weak self] in
            var saved = false
            if let image = LensImage.composite(frame: frame, scale: s.scale, layers: layers, crop: crop) {
                let url = LensExport.freeBase(in: folder, "\(name) \(LensExport.stamp(now, seconds: true))", ext: "png").appendingPathExtension("png")
                saved = (try? LensImage.writePNG(image, to: url)) != nil
            }
            await self?.chrome.flash(saved ? String(localized: "Saved") : String(localized: "Couldn’t save image"), seconds: saved ? 1.5 : 4)
        }
    }

    private func observeTranscript() {
        guard settings.savesTranscripts, !hiddenByOcclusion, let s = lastSnapshot else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if transcript == nil {
            transcriptBegan = now
            transcriptAppChecked = 0
            transcript = TranscriptWriter(directory: LensExport.transcriptsFolder(settings.exportFolder), lens: config.name,
                                          sourceCode: settings.sourceLanguage, targetCode: settings.targetLanguage,
                                          formats: settings.transcriptFormats, engine: settings.activeEngineConfig?.name ?? "apple",
                                          onError: { [weak self] in Task { @MainActor in self?.chrome.flash(String(localized: "Couldn’t save transcript"), seconds: 4) } })
            // A line that stays put makes no snapshots; looking again keeps it one line instead of many.
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.observeTranscript() } }
            RunLoop.main.add(t, forMode: .common)
            transcriptTimer = t
        }
        // Which app is in the lens changes rarely; looking costs a window list, so not on every snapshot.
        if now - transcriptAppChecked > 5, settings.transcriptFormats.contains(.jsonl) {
            transcriptAppChecked = now
            transcript?.setApp(AppModel.readerContext(for: config).bundleID)
        }
        transcript?.observe(time: now - transcriptBegan, lines: LensText.observed(s, lens: config.rect))
    }

    /// Closes the open cues; the writer finishes off the capture path. `wait`: the app is quitting.
    func finishTranscript(wait: Bool = false) {
        transcriptTimer?.invalidate()
        transcriptTimer = nil
        guard let t = transcript else { return }
        transcript = nil
        let end = ProcessInfo.processInfo.systemUptime - transcriptBegan
        if wait { t.finishAndWait(time: end) } else { t.finish(time: end) }
    }

    func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let blocks = lensBlocks()
        let original = ActionItem(String(localized: "Show Original")) { [weak self] in self?.onToggleOriginal?() }
        original.state = translationsVisible ? .off : .on
        menu.addItem(original)
        menu.addItem(ActionItem(String(localized: "Copy Original Text"), enabled: !blocks.isEmpty) { [weak self] in self?.copyOriginal() })
        menu.addItem(ActionItem(String(localized: "Copy Translation"), enabled: !LensText.translations(blocks).isEmpty) { [weak self] in self?.copyTranslation() })
        let reading = Speaker.shared.isReading(config.id)
        let voice = Speaker.voice(for: settings.targetLanguage)
        let read = ActionItem(reading ? String(localized: "Stop Reading") : String(localized: "Read Aloud"),
                              enabled: reading || (voice != nil && !LensText.translations(blocks).isEmpty)) { [weak self] in self?.toggleReadAloud() }
        if voice == nil { read.toolTip = String(localized: "No voice for \(Languages.name(settings.targetLanguage)) is installed. Add one in System Settings › Accessibility › Spoken Content.") }
        menu.addItem(read)
        menu.addItem(.separator())
        menu.addItem(ActionItem(String(localized: "Save Lens Image"), enabled: lastSnapshot?.frame != nil) { [weak self] in self?.saveLensImage() })
        addProfileItems(to: menu)
        return menu
    }

    /// "Remember Languages for <App>" / "Forget …" for a lens that follows a window: the app's profile (AppProfiles.swift).
    private func addProfileItems(to menu: NSMenu) {
        guard let anchor = config.anchor, let app = AppModel.app(ofWindow: anchor.windowID) else { return }
        let model = AppModel.shared, existing = model.profile(for: app.bundleID)
        let now = AppProfile(bundleID: app.bundleID, appName: app.name, source: settings.sourceLanguage, target: settings.targetLanguage,
                             customEngineID: settings.customEngineID)
        menu.addItem(.separator())
        if existing != now {
            menu.addItem(ActionItem(String(localized: "Remember Languages for \(app.name)")) { model.remember(now) })
        }
        if existing != nil {
            menu.addItem(ActionItem(String(localized: "Forget Languages for \(app.name)")) { model.forgetProfile(app.bundleID) })
        }
    }

    // MARK: - Lens (drag / resize)

    private func wireChrome() {
        chrome.onMove = { [weak self] frame in self?.lensMoved(frame) }
        chrome.onResize = { [weak self] frame in self?.lensResized(frame) }
        chrome.onCommit = { [weak self] in self?.lensDropped() }
        chrome.onClose = { [weak self] in self?.onCloseRequest?() }
        chrome.onToggleFollowing = { [weak self] in self?.toggleFollowing() }
        chrome.onContextMenu = { [weak self] in self?.contextMenu() }
    }

    private func lensMoved(_ appKitFrame: NSRect) {
        let rect = ScreenGeometry.quartzRect(fromAppKit: appKitFrame), now = ProcessInfo.processInfo.systemUptime
        // Heading: the direction of the last ~100 ms of the drag.
        if let last = lastLens {
            if now - last.time > 0.1 {
                let d = CGVector(dx: rect.midX - last.rect.midX, dy: rect.midY - last.rect.midY), len = hypot(d.dx, d.dy)
                if len > 4 { setLead(CGVector(dx: d.dx / len, dy: d.dy / len)) }
                lastLens = (rect, now)
            }
        } else {
            lastLens = (rect, now)
        }
        if !dragging { dragging = true; noteMotion() }
        config.rect = rect
        // The content stays put, and so do the blocks: only which of them show changes.
        panel.slide(to: appKitFrame)
        fitCapture(allowResize: false)
    }

    /// Moves the lens as if dragged by `delta` (Quartz points, y down) over `duration`, eased. For scripted demos.
    func glide(by delta: CGVector, duration: TimeInterval) async {
        let start = ScreenGeometry.appKitRect(fromQuartz: config.rect)
        let steps = max(1, Int(duration * 60))
        for i in 1...steps {
            let t = Double(i) / Double(steps), e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let f = start.offsetBy(dx: delta.dx * e, dy: -delta.dy * e)
            chrome.setRegion(f)
            lensMoved(f)
            try? await Task.sleep(for: .milliseconds(16))
        }
        lensDropped()
    }

    private func lensResized(_ appKitFrame: NSRect) {
        dragging = true
        config.rect = ScreenGeometry.quartzRect(fromAppKit: appKitFrame)
        panel.slide(to: appKitFrame)
        fitCapture(allowResize: false)
    }

    private func lensDropped() {
        dragging = false
        lastLens = nil
        setLead(.zero)
        fitCapture(allowResize: true)
        // A window lens follows whichever window it was dropped on (off every window, it stays where it is).
        // A screen lens stays pinned.
        if config.anchor != nil { follow(windowUnderLens()) }
        refreshReaderContext()
        onConfigChange?(config)
        updateEmphasis(NSEvent.mouseLocation)
    }

    // MARK: - Overscan

    /// The lens's display, Quartz points.
    private static func display(of lens: CGRect) -> CGRect {
        ScreenGeometry.screen(for: lens).map { ScreenGeometry.quartzRect(fromAppKit: $0.frame) } ?? lens
    }

    static func overscan(_ lens: CGRect, wide: Bool) -> CGRect {
        Overscan.rect(around: lens, wide: wide, display: display(of: lens))
    }

    private func fitCapture(allowResize: Bool) {
        let lens = config.rect
        switch Overscan.plan(lens: lens, capture: capture, wide: wideMargins, allowResize: allowResize, display: Self.display(of: lens), lead: lead) {
        case .keep: break
        case .move(let r):
            capture = r
            // The pipeline must know the new geometry before the capturer delivers its first frame of it.
            Task { await pipeline.captureMoved(to: r.origin); scheduleCaptureUpdate() }
        case .resize(let r):
            capture = r
            Task { await pipeline.captureResized(to: r); scheduleCaptureUpdate() }
        }
        Task { [pipeline] in await pipeline.setVisible(lens) }
    }

    /// Content or lens is moving: read wider until things calm down for a few seconds.
    private func noteMotion() {
        lastMotion = ProcessInfo.processInfo.systemUptime
        if !wideMargins {
            wideMargins = true
            fitCapture(allowResize: true)
        }
        guard calmTimer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkCalm() } }
        RunLoop.main.add(t, forMode: .common)
        calmTimer = t
    }

    private func checkCalm() {
        guard !dragging, ProcessInfo.processInfo.systemUptime - lastMotion > 4 else { return }
        calmTimer?.invalidate()
        calmTimer = nil
        wideMargins = false
        setLead(.zero)
        fitCapture(allowResize: true)
    }

    private func setLead(_ v: CGVector) {
        guard v != lead else { return }
        lead = v
        Task { [pipeline] in await pipeline.setLead(v) }
    }

    // MARK: - Scrolling

    /// A scroll event anywhere: if it scrolls content this lens reads, it predicts the next frames.
    private func wheel(_ e: NSEvent) {
        let p = ScreenGeometry.quartzRect(fromAppKit: NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        guard capture.contains(p), e.scrollingDeltaY != 0 || e.phase == .began else { return }
        if e.phase == .began || e.phase == .mayBegin || (e.phase.isEmpty && e.momentumPhase.isEmpty && e.timestamp - lastWheel > 0.5) {
            // A new gesture: pixels per wheel unit belong to the app (and page) under the pointer.
            let window = WindowInfo.onScreen().first { $0.bounds.contains(p) }
            if window?.id != scrollWindow { predictor.reset(); scrollArea = nil; scrollWindow = window?.id }
            // Until a frame shows what scrolls, guess the lens's part of that window: the lens usually sits on
            // the feed or chat being scrolled, and the first frame that moves corrects the guess.
            if scrollArea == nil, config.rect.contains(p) { scrollArea = config.rect.intersection(window?.bounds ?? config.rect) }
        }
        predictor.wheel(delta: Double(e.scrollingDeltaY), time: e.timestamp, precise: e.hasPreciseScrollingDeltas)
        lastWheel = e.timestamp
        panel.predict()
    }

    /// The frames showed content scrolled: learn how far scroll events move it, and read ahead where it comes from.
    private func scrolled(_ r: ScrollReport) {
        setLead(CGVector(dx: 0, dy: r.shift < 0 ? 1 : -1))
        let p = ScreenGeometry.quartzRect(fromAppKit: NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        guard r.area.contains(p) else { return }
        scrollArea = r.area
        predictor.confirm(shift: Double(r.shift), from: r.from, to: r.to)
    }

    /// The scroll the overlay should show on top of the frame captured at `since`, as of `now`.
    private func predictedScroll(since: TimeInterval, now: TimeInterval) -> (area: CGRect, dy: CGFloat)? {
        guard let area = scrollArea, now - lastWheel < 1 else { return nil }
        return (area, CGFloat(predictor.offset(from: since, to: now)))
    }

    /// Coalesces capture reconfiguration: at most one in flight, always ending on the latest rect.
    private func scheduleCaptureUpdate() {
        guard !captureUpdateRunning else { captureUpdatePending = true; return }
        captureUpdateRunning = true
        Task {
            repeat {
                captureUpdatePending = false
                do { try await capturer.update(rect: capture, fps: fps) } catch {
                    log.error("capture update failed: \(error.localizedDescription)")
                }
            } while captureUpdatePending
            captureUpdateRunning = false
        }
    }

    /// Show the lens chrome fully while the pointer is near the region; a faint outline otherwise.
    private func watchPointer() {
        guard mouseMonitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.updateEmphasis(NSEvent.mouseLocation) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) { mouseMonitors.append(g) }
        // Scroll events of other apps need no accessibility permission (only key events do).
        if let s = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: { [weak self] e in self?.wheel(e) }) { mouseMonitors.append(s) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { handler($0); return $0 }) {
            mouseMonitors.append(l)
        }
    }

    private func updateEmphasis(_ p: NSPoint) {
        let near = chrome.frame.insetBy(dx: -16, dy: -16).contains(p)
        let interior = chrome.regionFrame.insetBy(dx: 24, dy: 24).contains(p)
        chrome.setEmphasized(dragging || (near && !interior))
    }

    // MARK: - Window anchoring

    private func startTracking() {
        trackTimer?.invalidate()
        trackTimer = nil
        guard config.anchor != nil else {
            if hiddenByOcclusion { setOccluded(false) }
            return
        }
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.trackWindow() }
        }
        RunLoop.main.add(t, forMode: .common)
        trackTimer = t
    }

    private func trackWindow() {
        guard var anchor = config.anchor, !dragging else { return }
        let alive = WindowInfo.window(id: anchor.windowID)
        if alive != nil { anchorSeen = true }
        guard let w = alive ?? refind(anchor) else {
            setOccluded(true) // window closed or minimized
            return
        }
        if w.id != anchor.windowID {
            anchorSeen = true
            anchor.windowID = w.id
            config.anchor = anchor
        }
        // Hide while another window covers the region; the capture shows that window, not ours.
        let covered = WindowInfo.windows(above: anchor.windowID).contains { $0.bounds.intersects(config.rect.insetBy(dx: 4, dy: 4)) }
        setOccluded(!w.isOnScreen || covered)

        let target = CGRect(origin: CGPoint(x: w.bounds.minX + anchor.offset.x, y: w.bounds.minY + anchor.offset.y), size: config.rect.size)
        guard abs(target.minX - config.rect.minX) > 0.5 || abs(target.minY - config.rect.minY) > 0.5 else { return }
        let delta = CGVector(dx: target.minX - config.rect.minX, dy: target.minY - config.rect.minY)
        config.rect = target
        let frame = ScreenGeometry.appKitRect(fromQuartz: target)
        panel.move(to: frame)      // content moved with the window: blocks move along
        chrome.setRegion(frame)
        // The capture moves with the window too (slid back onto the display if it would leave it).
        let moved = Self.overscan(target, wide: wideMargins)
        if moved.size == capture.size {
            capture = moved
            Task { await pipeline.captureMoved(to: moved.origin, contentDelta: delta); scheduleCaptureUpdate() }
        }
        fitCapture(allowResize: false)
        onConfigChange?(config)
    }

    /// Window IDs do not survive the app relaunching (or Mwoyeo's): find the window again by app and title. Any
    /// window of the app will do only for an ID that went stale before this session; a window closed while
    /// followed must not hand the lens to its sibling.
    private func refind(_ a: WindowAnchor) -> WindowInfo? {
        let windows = WindowInfo.onScreen()
        return windows.first { $0.appName == a.appName && $0.title == a.title }
            ?? (anchorSeen ? nil : windows.first { $0.appName == a.appName })
    }

    private func setOccluded(_ occluded: Bool) {
        guard occluded != hiddenByOcclusion else { return }
        hiddenByOcclusion = occluded
        panel.setTranslationsVisible(translationsVisible && !occluded)
        occluded ? chrome.orderOut(nil) : chrome.orderFrontRegardless()
    }
}

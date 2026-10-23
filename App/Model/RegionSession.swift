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

    private let capturer: any ScreenCapturing
    /// Where the capture's frames go (the check-logic harness feeds it).
    var frameSink: (@Sendable (CapturedFrame) -> Void)? { capturer.onFrame }
    private let pipeline: RegionPipeline
    private let translator: TranslationService
    private let panel: OverlayPanel
    private let chrome: RegionFrameWindow
    /// The lens window, for the accessibility checks.
    var lensWindow: NSWindow { chrome }
    private var fps: Double
    private var trackTimer: Timer?
    private var mouseMonitors: [Any] = []
    /// Why the lens is off the screen (`OffScreen`); empty while it is on it. Frames reach the pipeline only while it is empty, and they
    /// arrive on the capture's queue, so the one owner of the reasons is behind a lock.
    private let offScreenGate = OSAllocatedUnfairLock(initialState: OffScreen())
    /// The window under the lens is read a few times a second (`SampleGate`), and only while the settings could put context on:
    /// its app, category and confirmed title go to the pipeline for the translator (`LensWatch`, `LensContext`).
    /// It also reads the app under the lens while any app profile exists, for the lens's route (`noteOwner`), though no context is wanted.
    private let sampleGate = OSAllocatedUnfairLock(initialState: SampleGate())
    private let lensWatch = LensWatch()
    /// The lens's confirmed window title as the pipeline last had it, for the translation log's `profile` (`TranscriptWriter.memory`).
    private let titleState = OSAllocatedUnfairLock<String?>(initialState: nil)
    private var contextWanted = false
    /// Why the capture failed, if it did (`CaptureFailure`); the hint says what to do about a refused one.
    private var captureFailure: CaptureFailure?
    /// "Already in <language>" waits for two reads that agree (`TargetLanguageStreak`).
    private var targetStreak = TargetLanguageStreak()
    /// "Translation isn't answering" waits for two failed groups in a row, none translated, after this lens read text (`TranslationWait`).
    private var translationWait = TranslationWait()
    /// This lens's listener on the translator's batches (`TranslationService.observe`), for `translationWait`.
    private var outcomeObserver: UUID?
    /// Takes the hint down when its failures are too old to count, if no newer one comes first (`TranslationWait.lapse`).
    private var troubleClock: Timer?
    /// What the pill says now instead of the languages (`LensHint`).
    private(set) var shownHint: LensHint?
    /// The followed window was seen alive in this session (so its ID is not just stale from a relaunch).
    private var anchorSeen = false
    private var translationsVisible = true
    private var dragging = false
    private var captureUpdateRunning = false
    private var captureUpdatePending = false
    /// The next pass of the capture's updates starts the stream again instead of reconfiguring it.
    private var captureRestartPending = false
    /// Resize tasks pile up behind a pass. Only the capture as it is when one runs is applied, so a size
    /// that was already replaced (grown, then shrunk) is not read. The ticket moves on every request; a call
    /// that was queued for an older one applies nothing.
    private let resizeTicket = OSAllocatedUnfairLock(initialState: 0)
    private var pipelineResizeRunning = false
    /// What the capture does when it stops or the displays change (`CaptureRecovery`), and its state: restarts tried since the stream
    /// last ran healthy, when it last started, whether a restart is waiting or running, the display event settling.
    private let policy: CaptureRecoveryPolicy
    private var restartsTried = 0
    private var captureStartedAt: TimeInterval = 0
    private var recovering = false
    private var recoveryTask: Task<Void, Never>?
    private var displayTask: Task<Void, Never>?
    private var pendingDisplayEvent: CaptureEvent?
    private var stopped = false
    /// The displays now; the check harness lays others out.
    var layoutProvider: @MainActor () -> DisplayLayout = { .current }
    /// What the recovery has done, for the check harness and the debug counters (`capture.restart`, `capture.moved`, `capture.gaveup`).
    struct RecoveryStats: Equatable {
        var restarts = 0
        var moves = 0
        var gaveUp = 0
    }
    private(set) var recoveryStats = RecoveryStats()
    /// The capture is down and nothing is about to start it again: the menu bar icon says so (`MenuBarIcon`).
    var needsAttention: Bool { errorMessage != nil && !recovering }
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
    /// `MWOYEO_PREDICT=off` (film takes of the overlay following the frames alone): the scroll predictor is neither fed nor asked.
    /// The App Store build has no such switch.
    #if MAS
    static let predicts = true
    #else
    static let predicts = !DebugSwitch.isOff("MWOYEO_PREDICT", in: ProcessInfo.processInfo.environment)
    #endif
    /// `MWOYEO_SNAP=instant|dwell` (takes of the two feels of a resize's snap, `LiveSnap`): the feel a lens has. The App Store build has the standard one.
    #if MAS
    static let snapFeel = LiveSnap.standard
    #else
    static let snapFeel = DebugSwitch.snapFeel(in: ProcessInfo.processInfo.environment)
    #endif
    /// The area under the pointer that scrolled last (global Quartz points), and the window it belongs to.
    private var scrollArea: CGRect?
    private var scrollWindow: CGWindowID?
    private var lastWheel: TimeInterval = 0
    private let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "session")
    /// What the lens translates with: `base` with the profile of the app under the lens over it (`route.settings`). The pill, the menu, the
    /// transcript and the hints read this; the app in front is not part of it.
    private var settings: AppSettings
    /// What the app pushed (`AppModel.pushSettings`): the base settings, All apps.
    private var base: AppSettings
    /// The app under the lens as the reads saw it (nil: none known, or no read while no app profile exists).
    private var owner: OwnerTracker
    /// The lens's languages, engine, cache namespace and pace slot (`LensRoute`, design names-and-context §1.3, §8 P1 and P2). The
    /// transcript's writer asks it from its own queue, so it sits behind a lock.
    private let routeState: OSAllocatedUnfairLock<LensRoute>
    var route: LensRoute { routeState.withLock { $0 } }
    /// The newest snapshot: what the lens's own actions (copy, save, transcripts) work from.
    private var lastSnapshot: OverlaySnapshot?
    /// The columns around the lens and its fit (snap, Fit to Column, Auto Fit): the transitions are the extension at the end of this file.
    var fit = LensFit()
    private var transcript: TranscriptWriter?
    /// The "choose a folder" notice shows once until a transcript can be written.
    private var transcriptFolderFlashed = false
    private var transcriptBegan: TimeInterval = 0
    private var transcriptTimer: Timer?
    private var transcriptAppChecked: TimeInterval = 0
    /// What the lens keeps of the lines that left it (`RecentLines`): the lens runs a recorder of its own on the same lines the transcript is
    /// given, since the transcript's belongs to the writer and runs only while the log is on. The stack shows in a panel just outside the lens.
    private var recentRecorder = TranscriptRecorder()
    private var recentLines: RecentLines
    private var recentPanel: RecentLinesPanel?
    /// "Ignore Region…" is waiting for a drag (the screen is dimmed except the lens, and the regions show).
    private let marker = RegionMarker()
    private var marking = false

    /// Hands the pipeline's snapshots to the session once it exists (the pipeline is built inside `init`).
    @MainActor private final class SnapshotTap { var handler: ((OverlaySnapshot) -> Void)? }

    /// - `base`: the base settings (All apps); the lens puts the profile of the app under it over them (`LensRoute`).
    /// - `appUnderLens`: how the window under the lens is read (`appUnderLens`); the checks give a fake one.
    init(config: RegionConfig, settings base: AppSettings, translator: TranslationService, inpainter: Inpainter?,
         capturer: any ScreenCapturing = RegionCapturer(), recovery: CaptureRecoveryPolicy = .standard,
         appUnderLens: @escaping @MainActor (RegionConfig) -> LensWatch.Read? = { LensWatch.window(of: $0) }) {
        // One look at the window under the lens: its app is the reader's context, and with an app profile it is the owner of the route too.
        let window = appUnderLens(config)
        let owner = OwnerTracker(base.appProfiles.isEmpty ? nil : window?.bundleID)
        let route = LensRoute(base: base, over: owner.app, pin: config.profilePin)
        let settings = route.settings
        self.capturer = capturer
        self.translator = translator
        self.policy = recovery
        self.config = config
        self.recentLines = RecentLines(capacity: base.recentLineCount)
        self.fps = settings.framesPerSecond
        self.settings = settings
        self.base = base
        self.owner = owner
        self.appUnderLens = appUnderLens
        self.routeState = OSAllocatedUnfairLock(initialState: route)
        let frame = ScreenGeometry.appKitRect(fromQuartz: config.rect)
        let panel = OverlayPanel(frame: frame)
        self.panel = panel
        chrome = RegionFrameWindow(region: frame, name: config.name)
        chrome.setDetail(Self.languagePair(settings), badge: settings.activeEngineConfig?.badgeSymbol)
        chrome.setFollowing(config.anchor != nil)
        chrome.setAppearance(settings)
        let capture = Self.overscan(config.rect, wide: false)
        self.capture = capture
        let tap = SnapshotTap()
        pipeline = RegionPipeline(options: PipelineOptions(settings, lensApp: Self.readerContext(of: window)), route: route, capture: capture,
                                  translator: translator, inpainter: inpainter, onSnapshot: { snapshot in Task { @MainActor in panel.apply(snapshot); tap.handler?(snapshot) } })
        let gate = offScreenGate, sampling = sampleGate
        capturer.onFrame = { [pipeline, weak self] frame in
            // Covered: the capture shows the window above, whose text is not the user's to have translated (or sent away). Hidden by
            // the person: nothing is read until they bring the lens back.
            let off = gate.withLock { $0 }
            guard off.isEmpty else { Trace.count("lens.dropped.\(off.counterName)"); return }
            if sampling.withLock({ $0.admit(now: ProcessInfo.processInfo.systemUptime) }) { Task { @MainActor in self?.sampleWindow() } }
            Task { await pipeline.ingest(frame) }
        }
        capturer.onStop = { [weak self] error in Task { @MainActor in self?.captureStopped(error) } }
        wireChrome()
        fit.machine = AutoFit.Machine(state: config.autoFit ? .armed : .off)
        tap.handler = { [weak self] in self?.received($0) }
        chrome.onHintAction = { [weak self] in self?.performHint() }
        // The lens's wait for a reader (`ReadWait`) changes outside the model: the pill is told when it does.
        ReaderClients.shared.onHint(pipeline.readerClient) { [weak self] in Task { @MainActor in self?.refreshHint() } }
        setContextWanted(ContextPlan.needsWindow(settings))
        setSampling()
    }

    /// Whether the window under the lens is read at all (`ContextPlan.needsWindow`). Off reads nothing and hands the pipeline nothing,
    /// so a translation goes the old way.
    private func setContextWanted(_ wanted: Bool) {
        guard wanted != contextWanted else { return }
        contextWanted = wanted
        if !wanted {
            lensWatch.reset()
            Task { [pipeline] in await pipeline.setLensContext(nil) }
        }
        setSampling()
    }

    /// The window is read while its document could be used (`contextWanted`) or an app profile could give the app under the lens other
    /// languages or another engine. With neither, nothing is read.
    private func setSampling() {
        let reading = contextWanted || !base.appProfiles.isEmpty
        sampleGate.withLock { $0.enabled = reading }
    }

    /// A capture pass that is due: reads the window the lens covers, takes the route of its app, and hands the pipeline the document it shows.
    func sampleWindow() {
        defer { sampleGate.withLock { $0.finish() } }
        let window = appUnderLens(config)
        Trace.count("lens.window.read")
        if !base.appProfiles.isEmpty { noteOwner(of: window) }
        guard contextWanted else { return }
        let read = lensWatch.ingest(window, lensID: config.id.uuidString, now: ProcessInfo.processInfo.systemUptime)
        if let context = read.context {
            titleState.withLock { $0 = context.confirmedTitle }
            Task { [pipeline] in await pipeline.setLensContext(context) }
        } else if read.gone {
            titleState.withLock { $0 = nil }
            Task { [pipeline] in await pipeline.setLensContext(nil) }
        }
    }

    func start() async {
        await pipeline.setActivityHandler { [weak self] a in Task { @MainActor in self?.setActivity(a) } }
        await pipeline.setNoticeHandler { [weak self] text in Task { @MainActor in self?.showNotice(text) } }
        await pipeline.setMotionHandler { [weak self] in Task { @MainActor in self?.fit.contentMovedAt = ProcessInfo.processInfo.systemUptime; self?.noteMotion() } }
        await pipeline.setScrollHandler { [weak self] r in Task { @MainActor in self?.scrolled(r) } }
        await pipeline.setReadHandler { [weak self] tally in Task { @MainActor in self?.read(tally) } }
        outcomeObserver = await translator.observe { [weak self] event in Task { @MainActor in self?.translationEvent(event) } }
        // The pair of this lens, when it is not the one the launch warmed (an app's profile): its models load while the first read runs.
        Task { [translator, route] in await translator.prewarm(route: route) }
        panel.prediction = { [weak self] since, now in self?.predictedScroll(since: since, now: now) }
        await pipeline.setVisible(config.rect)
        await pipeline.setIgnored(config.ignored)
        panel.setIgnored(config.ignored)
        placeWindows(animated: false)
        chrome.setOriginal(!translationsVisible)
        await startCapture()
        startTracking()
        watchPointer()
        onChange?()
    }

    /// Starts the capture (`start` does, and the checks, which have no windows to bring up).
    func startCapture() async {
        do {
            try await capturer.start(rect: capture, fps: fps)
            captureStartedAt = ProcessInfo.processInfo.systemUptime
            errorMessage = nil
            captureFailure = nil
            chrome.sweep()
        } catch {
            captureFailed(error)
        }
        refreshHint()
    }

    /// After a grant of Screen Recording: a capture that was refused starts again.
    func retryCapture() async {
        guard captureFailure != nil else { return }
        await startCapture()
        onChange?()
    }

    private static func failure(of error: Error) -> CaptureFailure {
        let e = error as NSError
        return CaptureFailure.classify(domain: e.domain, code: e.code)
    }

    func stop() async {
        stopped = true
        recovering = false
        await pipeline.halt()
        if let id = outcomeObserver { await translator.stopObserving(id) }
        outcomeObserver = nil
        troubleClock?.invalidate()
        troubleClock = nil
        recoveryTask?.cancel()
        displayTask?.cancel()
        trackTimer?.invalidate()
        trackTimer = nil
        calmTimer?.invalidate()
        calmTimer = nil
        busyTimer?.invalidate()
        busyTimer = nil
        stopFit()
        mouseMonitors.forEach { NSEvent.removeMonitor($0) }
        mouseMonitors = []
        finishTranscript()
        Speaker.shared.stop(config.id)
        await capturer.stop()
        panel.orderOut(nil)
        chrome.orderOut(nil)
        recentPanel?.orderOut(nil)
    }

    /// A quiet line on the lens's pill for a few seconds.
    func showNotice(_ text: String, seconds: TimeInterval = 6) {
        guard noticeGate.allow(text, now: ProcessInfo.processInfo.systemUptime) else { return }
        chrome.flash(text, seconds: seconds)
    }

    /// The second line of the pill: the lens's own pair.
    var pillDetail: String { Self.languagePair(settings) }

    /// The app the pipeline was last told this lens covers.
    var lensApp: ReaderContext { get async { await pipeline.lensApp } }

    private static func languagePair(_ s: AppSettings) -> String {
        "\(s.sourceLanguage == "auto" ? String(localized: "Auto") : Languages.name(s.sourceLanguage)) → \(Languages.name(s.targetLanguage))"
    }

    /// The base settings changed (or the lens is told them again): the lens takes the profile of the app it covers over them. The app in
    /// front is not an input: a lens over another app's window does not follow it. The push reads the window once.
    func update(settings new: AppSettings) async {
        base = new
        recentLines.setCapacity(new.recentLineCount)
        showRecent()
        let window = appUnderLens(config)
        // With no app profile no owner is known, and none is read for.
        if new.appProfiles.isEmpty { owner = OwnerTracker(nil) } else { _ = takeOwner(of: window) }
        adopt(LensRoute(base: new, over: owner.app, pin: config.profilePin))
        await pushRoute(lensApp: Self.readerContext(of: window))
    }

    /// What the paragraph reader knows of the app a window read found (`AppModel.readerContext(for:)` without its own window read).
    private static func readerContext(of window: LensWatch.Read?) -> ReaderContext {
        window.map { ReaderContext(bundleID: $0.bundleID, category: AppModel.category(ofApp: $0.bundleID)) } ?? ReaderContext()
    }

    /// A window read for the owner of the route (the one place it is counted); true when the owner changed.
    private func takeOwner(of window: LensWatch.Read?, settled: Bool = false) -> Bool {
        Trace.count("lens.owner.read")
        return settled ? owner.settle(window?.bundleID) : owner.note(window?.bundleID)
    }

    /// The app under the lens, from one window read. Another app may have another pair and engine (its profile over the base), so the lens
    /// takes the route of that app and the pipeline is told after; true when it did. `settled`: the lens was dropped somewhere new, and
    /// the read is the answer (`OwnerTracker`).
    @discardableResult
    private func noteOwner(of window: LensWatch.Read?, settled: Bool = false) -> Bool {
        guard takeOwner(of: window, settled: settled) else { return false }
        adopt(LensRoute(base: base, over: owner.app, pin: config.profilePin))
        let context = Self.readerContext(of: window)
        Task { await pushRoute(lensApp: context) }
        return true
    }

    /// The lens's side of a new route: what it shows and keeps follows its settings now. The pipeline is told by `pushRoute`.
    private func adopt(_ new: LensRoute) {
        let before = settings
        routeState.withLock { $0 = new }
        settings = new.settings
        setContextWanted(ContextPlan.needsWindow(settings))
        setSampling()
        if !settings.savesTranscripts || settings.exportFolder != before.exportFolder
            || settings.sourceLanguage != before.sourceLanguage || settings.targetLanguage != before.targetLanguage
            || settings.transcriptFormats != before.transcriptFormats || settings.activeEngineConfig?.id != before.activeEngineConfig?.id {
            finishTranscript()
        }
        chrome.setDetail(pillDetail, badge: settings.activeEngineConfig?.badgeSymbol)
        chrome.setAppearance(settings)
        if settings.sourceLanguage != before.sourceLanguage || settings.targetLanguage != before.targetLanguage { targetStreak.reset() }
        // The lines it kept were translated another way: they are not shown as if they were this one's.
        if lensPair(before) != lensPair(settings) || settings.activeEngineConfig?.id != before.activeEngineConfig?.id { forgetRecent() }
        // What failed before says nothing about another engine or pair.
        if lensPair(before) != lensPair(settings) || settings.engine != before.engine { translationWait.reset() }
        refreshHint()
    }

    /// The pipeline takes the lens's settings and route as they stand now, and the app the window read found.
    private func pushRoute(lensApp: ReaderContext) async {
        await pipeline.setRoute(route)
        await pipeline.update(options: PipelineOptions(settings, lensApp: lensApp))
        if settings.framesPerSecond != fps {
            fps = settings.framesPerSecond
            try? await capturer.update(rect: capture, fps: fps)
        }
    }

    func refresh() async {
        targetStreak.reset()
        translationWait.reset()
        refreshHint()
        await pipeline.refresh()
    }

    /// What the lens's translations show: they follow Show Original, and give way to anything that takes the lens off the screen.
    var showsTranslations: Bool { translationsVisible && offScreen.isEmpty }

    func setTranslationsVisible(_ visible: Bool) {
        translationsVisible = visible
        panel.setTranslationsVisible(showsTranslations)
        chrome.setOriginal(!visible)
        showRecent()
    }

    /// The Hide Lenses key over `lenses`: while any is hidden it brings every one back, otherwise it hides every one. True when they are
    /// hidden now.
    @discardableResult
    static func toggleHiding(_ lenses: some Collection<RegionSession>) -> Bool {
        let hide = !lenses.contains { $0.isHiddenByUser }
        setHiding(hide, in: lenses)
        return hide && !lenses.isEmpty
    }

    static func setHiding(_ hidden: Bool, in lenses: some Collection<RegionSession>) {
        lenses.forEach { $0.setHiddenByUser(hidden) }
    }

    /// The person hid the lens (Hide Lenses): no window of it is up and it reads nothing, whatever else is true of it, until they bring it back.
    var isHiddenByUser: Bool { offScreen.contains(.userHidden) }

    func setHiddenByUser(_ hidden: Bool) { setOffScreen(.userHidden, hidden) }

    /// How many of the lens's two windows (the panel of translations, the frame with the pill) are ordered in; for the checks.
    var windowsUp: Int { [panel, chrome].filter(\.isVisible).count }

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

    /// The app under the lens changed (dropped on another window, followed another): the pipeline's options carry it, and the lens takes the
    /// route of the app now (with an app profile there may be another), not at the next read. One window read serves both.
    private func refreshReaderContext() {
        let window = appUnderLens(config)
        if !base.appProfiles.isEmpty, noteOwner(of: window, settled: true) { return }
        let options = PipelineOptions(settings, lensApp: Self.readerContext(of: window))
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
        if a == .idle { fitSettled() }
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
        guard let error, !stopped else { return }
        errorMessage = error.localizedDescription
        captureFailure = Self.failure(of: error)
        // A revoked grant ends the stream: the hint depends on whether it still stands.
        AppModel.shared.recheckPermission()
        // A stream that ran healthy for a while starts a new episode; one that stops soon after a restart goes on down the backoff.
        if ProcessInfo.processInfo.systemUptime - captureStartedAt > policy.healthy { restartsTried = 0 }
        recover(.streamStopped(Self.stop(of: error)))
        refreshHint()
        onChange?()
    }

    /// A capture that could not start or restart: the lens says what failed (the menu panel shows it) and `recover` decides about trying again.
    private func captureFailed(_ error: Error) {
        errorMessage = String(localized: "Couldn’t start capturing: \(error.localizedDescription)")
        captureFailure = Self.failure(of: error)
        log.error("capture start failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code) \(error.localizedDescription)")
        recover(.streamStopped(Self.stop(of: error)))
    }

    /// A capture that runs: whatever was wrong is over.
    private func captureRecovered() {
        captureStartedAt = ProcessInfo.processInfo.systemUptime
        recovering = false
        guard errorMessage != nil || captureFailure != nil else { return }
        errorMessage = nil
        captureFailure = nil
        refreshHint()
        onChange?()
    }

    private static func stop(of error: Error) -> CaptureStop {
        let e = error as NSError
        return CaptureStop.classify(domain: e.domain, code: e.code)
    }

    // MARK: - Capture recovery

    /// The Mac woke or its displays changed (`DisplayWatcher`). A wake or an undock comes as a burst, and the displays are not all back at once:
    /// it is looked at after `policy.settle` seconds of quiet, once.
    func displaysChanged(_ event: CaptureEvent) {
        guard !stopped else { return }
        // A wake outranks a change of displays: it restarts the capture whatever the displays did.
        if event == .wake || pendingDisplayEvent == nil { pendingDisplayEvent = event }
        displayTask?.cancel()
        displayTask = Task { [weak self, settle = policy.settle] in
            try? await Task.sleep(for: .seconds(settle))
            guard !Task.isCancelled, let self, !self.stopped, let event = self.pendingDisplayEvent else { return }
            self.pendingDisplayEvent = nil
            self.displayTask = nil
            self.recover(event)
        }
    }

    /// Carries out what `CaptureRecovery.decide` says about `event`: starts the capture again (after the backoff for a stop), or moves a lens
    /// whose display is gone and starts it there.
    private func recover(_ event: CaptureEvent) {
        guard !stopped else { return }
        if event == .wake || event == .screensChanged { restartsTried = 0 }
        let action = CaptureRecovery.decide(event, lens: config.rect, followsWindow: config.anchor != nil, streamDisplay: capturer.streamDisplay,
                                            layout: layoutProvider(), failures: restartsTried, policy: policy)
        switch action {
        case .nothing:
            guard case .streamStopped = event else { return }
            recovering = false
            // Not for the grant or the person's own stop: nothing was tried, nothing is given up.
            if case .streamStopped(.other) = event {
                recoveryStats.gaveUp += 1
                Trace.count("capture.gaveup")
                log.error("capture recovery gave up after \(self.restartsTried) restarts")
            }
            onChange?()
        case let .restart(after):
            if case .streamStopped = event { restartsTried += 1 }
            scheduleRestart(after: after)
        case let .move(to):
            relocate(to: to)
            scheduleRestart(after: 0)
        }
    }

    private func scheduleRestart(after delay: TimeInterval) {
        recovering = true
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.recoveryTask = nil
            self.recoveryStats.restarts += 1
            Trace.count("capture.restart")
            self.scheduleCaptureUpdate(restart: true)
        }
    }

    /// The lens's display is gone: the lens goes to `rect` on another one, with its capture, overlay and chrome.
    private func relocate(to rect: CGRect) {
        guard rect != config.rect else { return }
        log.notice("lens display gone: moved from \(NSStringFromRect(self.config.rect)) to \(NSStringFromRect(rect))")
        recoveryStats.moves += 1
        Trace.count("capture.moved")
        config.rect = rect
        capture = Self.overscan(rect, wide: wideMargins, in: layoutProvider())
        let frame = ScreenGeometry.appKitRect(fromQuartz: rect)
        panel.slide(to: frame)
        recentPanel?.setLens(frame)
        chrome.setRegion(frame)
        let moved = capture
        Task { [pipeline] in
            await pipeline.captureResized(to: moved)
            await pipeline.setVisible(rect)
        }
        onConfigChange?(config)
        showNotice(String(localized: "Moved to the main display"))
    }

    // MARK: - What the pill says

    /// Everything the pill's hint depends on, as this lens sees it.
    func hintSignals() -> LensSignals {
        let model = AppModel.shared
        var signals = LensSignals(screen: .init(allowed: model.hasScreenPermission, failure: captureFailure),
                                  recognitionPreparing: model.recognitionPreparing,
                                  recognition: ReaderClients.shared.hint(pipeline.readerClient),
                                  showsTranslations: lastSnapshot?.blocks.isEmpty == false,
                                  alreadyInTarget: targetStreak.shown ? settings.targetLanguage : nil,
                                  translation: translationWait.trouble(at: ProcessInfo.processInfo.systemUptime))
        // The translator's issue is for whatever pair it last failed on: it counts for a lens that translates that pair.
        if case let .languagePackMissing(source, target)? = model.issue, Self.sameLanguage(target, settings.targetLanguage),
           settings.sourceLanguage == "auto" || Self.sameLanguage(source, settings.sourceLanguage) {
            signals.missingPack = PackPair(source: source, target: target)
            signals.packPhase = PackDownload.shared.ledger.phase(of: PackPair(source: source, target: target))
        }
        // A pair with no translation is the setup of a lens whose source is chosen; on Detect it is one block the detector got wrong.
        if case let .unsupportedPair(source, target)? = model.issue, settings.sourceLanguage != "auto",
           Self.sameLanguage(target, settings.targetLanguage), Self.sameLanguage(source, settings.sourceLanguage) {
            signals.unsupportedPair = PackPair(source: source, target: target)
        }
        return signals
    }

    /// Puts the one line the lens has (`LensSignals.hint`) on the pill.
    func refreshHint() {
        let hint = hintSignals().hint()
        watchTroubleLapse()
        guard hint != shownHint else { return }
        shownHint = hint
        chrome.setHint(hint.map(LensHintText.line), actionable: hint?.action != nil, forcesTab: hint?.showsTabAlways ?? false)
        if let hint { Trace.count("lens.hint.\(Self.counterName(hint))") }
        // The menu panel's row for this lens repeats the language hints: it reads the sessions only when told they changed.
        onChange?()
    }

    /// What this lens translates now, as the translator's batches are matched to it (`TranslationRoute.serves`).
    private func lensPair(_ s: AppSettings) -> LensPair {
        LensPair(source: s.sourceLanguage, target: s.targetLanguage, engine: s.activeEngineConfig?.id)
    }

    /// One look at the hint when the failures behind it stop counting; a newer failure moves that time on.
    private func watchTroubleLapse() {
        troubleClock?.invalidate()
        troubleClock = nil
        guard let due = translationWait.lapse else { return }
        let wait = due - ProcessInfo.processInfo.systemUptime
        guard wait > 0 else { return }
        troubleClock = Timer.scheduledTimer(withTimeInterval: wait + 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshHint() }
        }
    }

    private static func sameLanguage(_ a: String, _ b: String) -> Bool {
        Locale.Language(identifier: a).languageCode == Locale.Language(identifier: b).languageCode
    }

    private static func counterName(_ hint: LensHint) -> String {
        switch hint {
        case .allowScreenRecording: "allow"
        case .restartToFinish: "restart"
        case .downloadPack: "pack"
        case .downloadingPack: "pack-downloading"
        case .downloadNotFinished: "pack-not-finished"
        case .pairNotSupported: "pair-not-supported"
        case .preparingRecognition: "preparing"
        case .recognitionNotResponding: "not-responding"
        case .recognitionNeedsDiskSpace: "disk-space"
        case .translationNotAnswering: "translation-failing"
        case .translationSlow: "translation-slow"
        case .alreadyInTarget: "already"
        }
    }

    /// A click on the hint (the pill's, or its line in the menu panel's row).
    func performHint() {
        let model = AppModel.shared
        switch shownHint?.action {
        case .openScreenRecordingSettings?: model.openScreenRecordingSettings()
        case .restart?: model.relaunch()
        case let .downloadPack(pair)?: model.downloadPack(pair)
        case .openTranslationSettings?: model.openSettings(on: .translation)
        case .chooseLanguages?: model.openSettings(on: .general)
        case .openStorageSettings?: model.openStorageSettings()
        case nil: break
        }
    }

    /// What a read found: two in a row that found only text in the target language put "Already in …" on the pill; text to translate
    /// makes the lens wait for it, which is what lets the translator's failures be this lens's (`TranslationWait`).
    func read(_ tally: ReadTally) {
        let before = targetStreak.shown, waiting = translationWait
        targetStreak.read(tally)
        translationWait.read(tally)
        if targetStreak.shown != before || translationWait != waiting { refreshHint() }
    }

    /// What became of a batch of lines the translator worked on (any lens's; only the groups that are this lens's pair count): two failed
    /// in a row say so on the pill, the first translated one takes it down.
    private func translationEvent(_ event: TranslationEvent) {
        guard !stopped else { return }
        let before = translationWait
        translationWait.apply(event, at: ProcessInfo.processInfo.systemUptime, lens: lensPair(settings))
        if translationWait != before { refreshHint() }
    }

    // MARK: - Keeping what the lens read

    /// Whether the lens (global Quartz points) is under `point`.
    func contains(_ point: CGPoint) -> Bool { config.rect.contains(point) }

    /// Every snapshot the pipeline makes, as the panel got it (the checks watch what the lens shows, snapshot by snapshot).
    var snapshotObserver: ((OverlaySnapshot) -> Void)?

    func received(_ snapshot: OverlaySnapshot) {
        let showedTranslations = lastSnapshot?.blocks.isEmpty == false
        lastSnapshot = snapshot
        snapshotObserver?(snapshot)
        if showedTranslations != !snapshot.blocks.isEmpty { refreshHint() }
        observeTranscript()
        noteColumns(snapshot)
        observeRecent()
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
        let showing = showsTranslations
        let layers = showing ? s.blocks.map { LensImage.Layer(frame: $0.frame, image: $0.image) } : []
        let crop = config.rect.offsetBy(dx: -s.origin.x, dy: -s.origin.y)
        // The folder opens for the write only (a person pressed Save): the panel asks when none is chosen or the bookmark went stale.
        let access = ExportFolderGate.shared.access(for: settings, store: { AppModel.shared.chooseExportFolder($1, bookmark: $0) })
        let name = LensExport.fileName(config.name), now = Date()
        Task.detached(priority: .utility) { [weak self] in
            defer { access?.end() }
            var saved = false
            if let access, let image = LensImage.composite(frame: frame, scale: s.scale, layers: layers, crop: crop) {
                let folder = LensExport.capturesFolder(access.url)
                let url = LensExport.freeBase(in: folder, "\(name) \(LensExport.stamp(now, seconds: true))", ext: "png").appendingPathExtension("png")
                saved = (try? LensImage.writePNG(image, to: url)) != nil
            }
            await self?.chrome.flash(saved ? String(localized: "Saved") : String(localized: "Couldn’t save image"), seconds: saved ? 1.5 : 4)
        }
    }

    private func observeTranscript() {
        guard settings.savesTranscripts, !offScreen.contains(.occluded), let s = lastSnapshot else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if transcript == nil {
            // No writer without a folder: a declined panel is not asked again until the person chooses one in Settings.
            guard let access = ExportFolderGate.shared.access(for: settings, store: { AppModel.shared.chooseExportFolder($1, bookmark: $0) }) else {
                if !transcriptFolderFlashed {
                    transcriptFolderFlashed = true
                    chrome.flash(String(localized: "Choose a folder in Settings to save transcripts"), seconds: 4)
                }
                return
            }
            transcriptFolderFlashed = false
            transcriptBegan = now
            transcriptAppChecked = 0
            transcript = TranscriptWriter(directory: LensExport.transcriptsFolder(access.url), access: access, lens: config.name,
                                          sourceCode: settings.sourceLanguage, targetCode: settings.targetLanguage,
                                          formats: settings.transcriptFormats,
                                          engine: { [translator, routeState, chosen = settings.activeEngineConfig?.name ?? "apple"] in
                                              translator.translatedBy($0, route: routeState.withLock { $0 }) ?? chosen },
                                          memory: TranscriptWriter.memory(settings: settings, title: { [titleState] in titleState.withLock { $0 } }),
                                          sent: { [translator, routeState] in translator.sentText(for: $0, route: routeState.withLock { $0 }) },
                                          rulesSkipped: { [translator, routeState] in translator.rulesSkipped(for: $0, route: routeState.withLock { $0 }) },
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

    // MARK: - Regions that are not read, and the lines that left the lens

    /// "Ignore Region…": the person drags over a part of the lens (a HUD, a name tag, a timer); from then on it is not read, translated or drawn
    /// over. The region is kept with the lens as fractions of it.
    func ignoreRegion() async {
        guard !marking, !offScreen.contains(.userHidden) else { return }
        marking = true
        panel.showsIgnored(true)
        defer {
            marking = false
            updateEmphasis(NSEvent.mouseLocation)
        }
        guard let dragged = await marker.mark(in: config.rect, existing: config.ignored.map { $0.rect(in: config.rect) }) else { return }
        addIgnoredRegion(dragged: dragged)
    }

    /// `dragged` (global Quartz points) as a region of the lens; one that lies outside it or is too small is none.
    func addIgnoredRegion(dragged: CGRect) {
        guard let region = IgnoredRegions.region(dragged: dragged, in: config.rect) else { return }
        setIgnored(IgnoredRegions.adding(region, to: config.ignored))
    }

    func clearIgnoredRegions() { setIgnored([]) }

    /// The regions the lens does not read, as it keeps them: the pipeline masks them before reading, the panel draws nothing over them and
    /// outlines them, and the lens is saved with them.
    private func setIgnored(_ list: [UnitRect]) {
        guard list != config.ignored else { return }
        config.ignored = list
        panel.setIgnored(list)
        Task { [pipeline] in await pipeline.setIgnored(list) }
        onConfigChange?(config)
        chrome.flash(list.isEmpty ? String(localized: "Ignored regions cleared") : String(localized: "Region ignored"))
    }

    /// The regions' outlines show while the pointer is over the lens, or one is being marked.
    private func updateIgnoredOutlines(pointer p: NSPoint) {
        panel.showsIgnored(marking || chrome.regionFrame.insetBy(dx: -16, dy: -16).contains(p))
    }

    /// "Keep Recent Lines": the lines that leave the lens stay in a small stack just outside it.
    func setKeepsRecent(_ on: Bool) {
        guard on != config.keepsRecent else { return }
        config.keepsRecent = on
        if on { observeRecent() } else { forgetRecent() }
        onConfigChange?(config)
    }

    func toggleKeepsRecent() { setKeepsRecent(!config.keepsRecent) }

    /// The lens's lines as the recorder sees them (a snapshot came, or the lens moved over other lines).
    private func observeRecent() {
        guard config.keepsRecent, let s = lastSnapshot else { return }
        let observed = LensText.observed(s, lens: config.rect)
        let ignored = config.ignored.map { $0.rect(in: CGRect(origin: .zero, size: config.rect.size)) }
        let now = ProcessInfo.processInfo.systemUptime
        recentLines.observe(recentRecorder.observe(time: now, lines: observed), lines: observed, ignored: ignored, at: now)
        showRecent()
    }

    /// The stack as the lines say, below the lens or above it; off the screen with no lines, with Show Original, with the lens hidden or covered.
    private func showRecent() {
        guard config.keepsRecent, showsTranslations else { recentPanel?.orderOut(nil); return }
        let panel = recentPanel ?? RecentLinesPanel(lens: ScreenGeometry.appKitRect(fromQuartz: config.rect))
        recentPanel = panel
        panel.setLens(ScreenGeometry.appKitRect(fromQuartz: config.rect))
        let now = ProcessInfo.processInfo.systemUptime
        panel.show(recentLines.stack(at: now))
        Trace.mark("recent shows: \(recentLines.report(at: now))", since: Trace.now)
        panel.refresh(in: recentLines.nextLift(at: now)) { [weak self] in self?.showRecent() }
    }

    /// The lines the lens kept are forgotten (another language or engine, the option turned off).
    private func forgetRecent() {
        recentLines.clear()
        recentRecorder = TranscriptRecorder()
        recentPanel?.orderOut(nil)
    }

    /// For the captures: the lens as it looks once `snapshot` was read (its blocks drawn), as a snapshot of its pipeline would show it.
    func showForCapture(_ snapshot: OverlaySnapshot) {
        panel.apply(snapshot)
        received(snapshot)
    }

    /// For the captures: the regions' outlines as they show while the pointer is over the lens.
    func previewIgnoredOutlines(_ on: Bool) { panel.showsIgnored(on) }

    /// How long a line that left waits before the stack shows it (`RecentLines.hold`); the checks that feed lines one look after another run it at 0.
    var recentHold: TimeInterval {
        get { recentLines.hold }
        set { recentLines.hold = newValue }
    }
    /// The lines the lens keeps now, newest first, for the checks.
    var keptRecentLines: [RecentLines.Line] { recentLines.stack }
    /// What the stack's panel shows now, for the checks, and where it is (AppKit coordinates) and on which side of the lens.
    var recentPanelLines: [String] { recentPanel?.isVisible == true ? recentPanel?.lines ?? [] : [] }
    var recentPanelPlace: (frame: NSRect, below: Bool)? { recentPanel.map { ($0.frame, $0.isBelow) } }

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
        addFitItems(to: menu)
        addGameItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(ActionItem(String(localized: "Save Lens Image"), enabled: lastSnapshot?.frame != nil) { [weak self] in self?.saveLensImage() })
        addProfileItems(to: menu)
        return menu
    }

    /// The title of the lens menu's one submenu that is not the profile's.
    static var gamesTitle: String { String(localized: "Games & Video") }

    /// What a game or a video asks of a lens, in one submenu (progressive disclosure: a lens over a page shows one row for it, not three): Ignore
    /// Region…, Clear Ignored Regions (only while a region is ignored) and Keep Recent Lines.
    private func addGameItems(to menu: NSMenu) {
        let sub = NSMenu()
        sub.autoenablesItems = false
        sub.addItem(ActionItem(String(localized: "Ignore Region…"), enabled: !marking) { [weak self] in Task { await self?.ignoreRegion() } })
        if !config.ignored.isEmpty {
            sub.addItem(ActionItem(String(localized: "Clear Ignored Regions")) { [weak self] in self?.clearIgnoredRegions() })
        }
        let keep = ActionItem(String(localized: "Keep Recent Lines")) { [weak self] in self?.toggleKeepsRecent() }
        keep.state = config.keepsRecent ? .on : .off
        sub.addItem(keep)
        let item = NSMenuItem(title: Self.gamesTitle, action: nil, keyEquivalent: "")
        item.submenu = sub
        menu.addItem(item)
    }

    /// The app under the lens: the window it follows, else the topmost window under its centre (`LensWatch.window(of:)`). The check harness
    /// and the captures name one, because a window of this app is never in the list.
    var appUnderLens: @MainActor (RegionConfig) -> LensWatch.Read?
    /// "Forget <App>…" asks before it removes a memory (`LensMemoryMenu.forgetAlert`, which says the note only when the profile has one); the check
    /// harness answers for it (addendum A3).
    var confirmsForgetting: @MainActor (_ app: String, _ names: Int, _ hasNote: Bool) -> Bool = { app, names, hasNote in
        NSApp.activate(ignoringOtherApps: true)
        return LensMemoryMenu.forgetAlert(app: app, names: names, hasNote: hasNote).runModal() == .alertFirstButtonReturn
    }

    /// The profile's memory in the menu, for every lens whose app is known, anchored or not (design names-and-context §3.2, §6.4): the names that
    /// apply, "Memory for <name>…" (Settings with the sheet of the profile the lens uses: its head, else the app), "Remember Languages" when the
    /// pair or engine differs from the remembered ones (it keeps the memory), and "Forget" (with an alert when the profile has a memory). With a
    /// profile in the file (L1) one more item, "Profile: …", holds the one submenu: what Auto picks, the choice for every lens, and the two
    /// ways to make a profile.
    private func addProfileItems(to menu: NSMenu) {
        guard let app = appUnderLens(config) else { return }
        let model = AppModel.shared, name = LensMemoryMenu.cut(app.appName)
        let here = LanguageChoice(source: settings.sourceLanguage, target: settings.targetLanguage, customEngineID: settings.customEngineID)
        // The profile the lens is using: the head of its chain while that is a profile, else the app's own (made by the first edit).
        let head = ProfileWords.head(model.settings, bundleID: app.bundleID, title: app.title, lensPin: config.profilePin)
        let existing = head.profile ?? model.profile(for: app.bundleID)
        let shownName = head.profile.map { LensMemoryMenu.cut($0.name) } ?? name
        menu.addItem(.separator())
        if let line = LensMemoryMenu.infoLine(app: head.profile?.name ?? app.appName, appNames: existing?.entries.count ?? 0,
                                              allApps: model.settings.glossaryPairs.count, words: .current) {
            let info = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            info.isEnabled = false
            menu.addItem(info)
        }
        var target = head.profile.map { MemoryTarget(id: $0.id, name: $0.name, kind: .profile) } ?? MemoryTarget(id: app.bundleID, name: app.appName)
        // The lens's opening: its app, window title and last line, for "Add Condition" and the Script's Test sample (design §6.3, rewrite-rules §7).
        let last = lensBlocks().last
        (target.lensBundleID, target.lensAppName, target.lensTitle, target.lensSource, target.lensTranslation) =
            (app.bundleID, app.appName, app.title.isEmpty ? nil : app.title, last?.source, last?.translation)
        menu.addItem(ActionItem(String(localized: "Memory for \(shownName)…")) { model.openProfile(target) })
        if !model.settings.appProfiles.isEmpty { menu.addItem(profileItem(app: app, head: head, here: here, model: model)) }
        if existing?.languages != here {
            menu.addItem(ActionItem(String(localized: "Remember Languages for \(shownName)")) { model.rememberLanguages(here, for: app.bundleID, named: app.appName) })
        }
        guard let existing else { return }
        let confirm = confirmsForgetting
        if existing.hasMemory {
            menu.addItem(ActionItem(String(localized: "Forget \(shownName)…")) {
                if confirm(existing.name, existing.entries.count, !existing.note.isEmpty) { model.removeProfile(id: existing.id) }
            })
        } else {
            menu.addItem(ActionItem(String(localized: "Forget Languages for \(shownName)")) { model.removeProfile(id: existing.id) })
        }
    }

    /// "Profile: <head>" with its one submenu (design §6.4): what Auto picks (dimmed), "Auto", "All Apps Only", the profiles (≤ 8, then "More in
    /// Settings…"), and "New Profile for This Window…" / "New Profile…". A choice pins this lens alone (`RegionConfig.profilePin`, §1.3, addendum A1);
    /// the checkmark follows the pin in effect, the lens's own over the menu bar's. While the menu bar pins every lens and this lens has no pin of its
    /// own, "Auto" is dimmed (it would change nothing): the bar's own "Auto" returns every lens.
    private func profileItem(app: LensWatch.Read, head: ChainLink, here: LanguageChoice, model: AppModel) -> NSMenuItem {
        let settings = model.settings, profiles = settings.appProfiles
        let pin = settings.pin(lens: config.profilePin)
        let item = NSMenuItem(title: ProfileWords.caption(head: head, pin: pin, owner: config.profilePin == nil ? .menuBar : .lens, limit: LensMemoryMenu.nameLimit),
                              action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let auto = ProfileWords.head(settings.withoutPin, bundleID: app.bundleID, title: app.title)
        // At most 48 characters, cut at the tail, as the info line is (design §6.4).
        let pick = String(localized: "Auto picks \(auto.profile.map { LensMemoryMenu.cut($0.name) } ?? String(localized: "All Apps")): \(ProfileWords.why(head: auto.profile, bundleID: app.bundleID, title: app.title))")
        let picks = NSMenuItem(title: pick.count > LensMemoryMenu.lineLimit ? String(pick.prefix(LensMemoryMenu.lineLimit - 1)) + "…" : pick,
                               action: nil, keyEquivalent: "")
        picks.isEnabled = false
        sub.addItem(picks)
        let autoItem = ActionItem(String(localized: "Auto"), enabled: config.profilePin != nil || settings.profilePin == nil) { [weak self] in self?.setProfilePin(nil) }
        autoItem.state = pin == .auto ? .on : .off
        sub.addItem(autoItem)
        sub.addItem(.separator())
        let all = ActionItem(String(localized: "All Apps Only")) { [weak self] in self?.setProfilePin(AppProfile.allAppsID) }
        all.state = pin == .allAppsOnly ? .on : .off
        sub.addItem(all)
        for p in profiles.prefix(8) {
            let row = ActionItem(LensMemoryMenu.cut(p.name)) { [weak self] in self?.setProfilePin(p.id) }
            row.state = pin == .profile(p.id) ? .on : .off
            sub.addItem(row)
        }
        if profiles.count > 8 {
            sub.addItem(ActionItem(String(localized: "More in Settings…")) { _ = model.openSettings(on: .translation) })
        }
        sub.addItem(.separator())
        let pair = here
        let title = app.title
        let last = lensBlocks().last
        let newWindow = ActionItem(String(localized: "New Profile for This Window…"), enabled: !title.isEmpty) {
            let phrase = ContextText.truncated(title, toCharacters: ProfileCondition.maxTitleLength)
            let profileName = ContextText.truncated(title, toCharacters: AppProfile.maxNameLength)
            let draft = AppProfile(bundleID: "", appName: profileName, source: pair.source, target: pair.target,
                                   id: ProfileIDs.fresh(named: profileName, in: model.settings.appProfiles), name: profileName,
                                   when: [ProfileCondition(app: app.bundleID, titleContains: phrase)])
            model.openProfile(MemoryTarget(id: draft.id, name: profileName, kind: .new, draft: draft, focusesPhrase: true,
                                           lensBundleID: app.bundleID, lensAppName: app.appName, lensTitle: title,
                                           lensSource: last?.source, lensTranslation: last?.translation))
        }
        sub.addItem(newWindow)
        sub.addItem(ActionItem(String(localized: "New Profile…")) {
            let profileName = String(localized: "New Profile")
            let draft = AppProfile(bundleID: "", appName: profileName, source: pair.source, target: pair.target,
                                   id: ProfileIDs.fresh(named: profileName, in: model.settings.appProfiles), name: profileName, when: [])
            model.openProfile(MemoryTarget(id: draft.id, name: profileName, kind: .new, draft: draft,
                                           lensBundleID: app.bundleID, lensAppName: app.appName, lensTitle: title,
                                           lensSource: last?.source, lensTranslation: last?.translation))
        })
        item.submenu = sub
        return item
    }

    /// This lens's own pin (design §1.3, addendum A1): nil is Auto, `all` All apps only, an id a profile. It is kept with the lens (`onConfigChange`
    /// writes it to `regions`) and the lens takes the route of it at once (`update(settings:)` lays the pin over the profile it reads).
    func setProfilePin(_ pin: String?) {
        guard config.profilePin != pin else { return }
        config.profilePin = pin
        onConfigChange?(config)
        Task { await update(settings: base) }
    }

    // MARK: - Lens (drag / resize)

    private func wireChrome() {
        chrome.onMove = { [weak self] frame in self?.lensMoved(frame) }
        chrome.onResize = { [weak self] frame in self?.lensResized(frame) }
        chrome.onCommit = { [weak self] in self?.lensDropped() }
        chrome.onClose = { [weak self] in self?.onCloseRequest?() }
        chrome.onToggleFollowing = { [weak self] in self?.toggleFollowing() }
        chrome.onContextMenu = { [weak self] in self?.contextMenu() }
        // A screen reader's actions and text (RegionFrameWindow, Accessibility).
        chrome.onToggleOriginal = { [weak self] in self?.onToggleOriginal?() }
        chrome.onPause = { Task { await AppModel.shared.togglePause() } }
        chrome.translationLines = { [weak self] in LensText.translations(self?.lensBlocks() ?? []) }
        chrome.onFit = { [weak self] in self?.fitToColumn() }
        chrome.fitTitle = { [weak self] in self?.fitTitle ?? String(localized: "Fit to Column") }
        chrome.onSnapResize = { [weak self] in self?.snapResized($0) ?? $0 }
        chrome.onSettle = { [weak self] in self?.settleFrame(for: $0) }
        chrome.onSettleResize = { [weak self] in self?.settleResized($0) }
        // The ring's outline bows and settles over the frame; the panel's clip is cut by the very same one (`LensSkin`, motion contract 9.5).
        panel.outline = { [weak chrome] in chrome?.outline() }
        chrome.onOutline = { [weak panel] in panel?.restyle() }
    }

    /// The picker's click (global Quartz points) placed this lens: its outline takes hold from the first frame it shows (`RegionFrameWindow.takeHold`).
    func takeHold(at click: CGPoint) {
        chrome.takeHold(at: ScreenGeometry.appKitRect(fromQuartz: CGRect(origin: click, size: .zero)).origin)
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
        traceFrame("move", rect)
        snapMoved(rect)
        // The content stays put, and so do the blocks: only which of them show changes.
        panel.slide(to: appKitFrame)
        recentPanel?.setLens(appKitFrame)
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
        traceFrame("resize", config.rect)
        noteResized()
        panel.slide(to: appKitFrame)
        recentPanel?.setLens(appKitFrame)
        fitCapture(allowResize: false)
    }

    /// The lens was dropped (the checks drop one without a drag).
    func lensDropped() {
        dragging = false
        lastLens = nil
        setLead(.zero)
        noteDropped()
        fitCapture(allowResize: true)
        Task { await armResizeRead() }
        // A window lens follows whichever window it was dropped on (off every window, it stays where it is).
        // A screen lens stays pinned.
        if config.anchor != nil { follow(windowUnderLens()) }
        refreshReaderContext()
        onConfigChange?(config)
        updateEmphasis(NSEvent.mouseLocation)
        // Other lines are in the lens now, and the ones it left are in the stack.
        observeRecent()
    }

    // MARK: - Overscan

    /// The lens's display, Quartz points (the lens itself where no display shows any of it).
    private static func display(of lens: CGRect, in layout: DisplayLayout) -> CGRect {
        layout.display(showing: lens) ?? lens
    }

    private func display(of lens: CGRect) -> CGRect { Self.display(of: lens, in: layoutProvider()) }

    /// `layout`: the displays as the session sees them (`layoutProvider`); nil at construction, when the real ones are looked at.
    static func overscan(_ lens: CGRect, wide: Bool, in layout: DisplayLayout? = nil) -> CGRect {
        Overscan.rect(around: lens, wide: wide, display: display(of: lens, in: layout ?? .current))
    }

    private func fitCapture(allowResize: Bool) {
        let lens = config.rect
        switch Overscan.plan(lens: lens, capture: capture, wide: wideMargins, allowResize: allowResize, display: display(of: lens), lead: lead, band: fit.band) {
        case .keep: break
        case .move(let r):
            capture = r
            // The pipeline must know the new geometry before the capturer delivers its first frame of it.
            Task { await pipeline.captureMoved(to: r.origin); scheduleCaptureUpdate() }
        case .resize(let r):
            capture = r
            schedulePipelineResize()
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
        guard Self.predicts else { return }
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
        fit.contentMovedAt = ProcessInfo.processInfo.systemUptime
        setLead(CGVector(dx: 0, dy: r.shift < 0 ? 1 : -1))
        let p = ScreenGeometry.quartzRect(fromAppKit: NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        guard r.area.contains(p) else { return }
        scrollArea = r.area
        if Self.predicts { predictor.confirm(shift: Double(r.shift), from: r.from, to: r.to) }
    }

    /// The scroll the overlay should show on top of the frame captured at `since`, as of `now`.
    private func predictedScroll(since: TimeInterval, now: TimeInterval) -> (area: CGRect, dy: CGFloat)? {
        guard Self.predicts, let area = scrollArea, now - lastWheel < 1 else { return nil }
        return (area, CGFloat(predictor.offset(from: since, to: now)))
    }

    /// One pipeline resize at a time, always the capture as it is when the call runs. A call queued for a
    /// size the lens has already left applies nothing, and the capturer is reconfigured once, for the size that remains.
    private func schedulePipelineResize() {
        resizeTicket.withLock { $0 += 1 }
        guard !pipelineResizeRunning else { return }
        pipelineResizeRunning = true
        Task {
            var saw = -1
            while !stopped {
                let ticket = resizeTicket.withLock { $0 }
                let r = capture
                await pipeline.captureResized(to: r, ticket: ticket, tickets: resizeTicket, deferRead: true)
                saw = ticket
                if saw == resizeTicket.withLock({ $0 }) { break }
            }
            pipelineResizeRunning = false
            if stopped { return }
            if saw != resizeTicket.withLock({ $0 }) { schedulePipelineResize() }
            else {
                await armResizeRead()
                scheduleCaptureUpdate()
            }
        }
    }

    /// The read of a grow that `captureResized` held back (`deferRead`) starts once the lens rests on its size: not while a drag goes on (the
    /// drop calls this), not while a resize is still being applied (its end calls this). A jump of the lens (Fit to Column) ends its resize
    /// before its drop, and its drop finds the capture already at its size.
    private func armResizeRead() async {
        guard !dragging, !pipelineResizeRunning else { return }
        await pipeline.armDeferredResizeRead()
    }

    /// Coalesces capture reconfiguration: at most one in flight, always ending on the latest rect.
    private func scheduleCaptureUpdate(restart: Bool = false) {
        if restart { captureRestartPending = true }
        guard !captureUpdateRunning else { captureUpdatePending = true; return }
        captureUpdateRunning = true
        Task {
            repeat {
                captureUpdatePending = false
                let restarting = captureRestartPending
                captureRestartPending = false
                do {
                    if restarting { try await capturer.start(rect: capture, fps: fps) } else { try await capturer.update(rect: capture, fps: fps) }
                    captureRecovered()
                } catch {
                    log.error("capture \(restarting ? "restart" : "update") failed: \(error.localizedDescription)")
                    if !stopped { captureFailed(error); onChange?() }
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
        updateIgnoredOutlines(pointer: p)
    }

    // MARK: - Window anchoring

    private func startTracking() {
        trackTimer?.invalidate()
        trackTimer = nil
        guard config.anchor != nil else {
            if offScreen.contains(.occluded) { setOccluded(false) }
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
        recentPanel?.setLens(frame)
        chrome.setRegion(frame)
        // The capture moves with the window too (slid back onto the display if it would leave it).
        let moved = Self.overscan(target, wide: wideMargins, in: layoutProvider())
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

    /// A covered, closed or minimized window takes the lens off the screen and stops its reading: the capture shows whatever is above it.
    func setOccluded(_ occluded: Bool) { setOffScreen(.occluded, occluded) }

    /// The reasons the lens is off the screen, as they are now (`OffScreen`).
    var offScreen: OffScreen { offScreenGate.withLock { $0 } }

    /// Adds `reason` to the reasons the lens is off the screen, or takes it away. The windows follow the reasons that are left, and so does
    /// the reading: with the first reason it stops, and with the last one gone one fresh frame is asked for, since content that did not
    /// change sends none.
    func setOffScreen(_ reason: OffScreen, _ on: Bool) {
        let (before, after) = offScreenGate.withLock { reasons -> (OffScreen, OffScreen) in
            let before = reasons
            if on { reasons.insert(reason) } else { reasons.remove(reason) }
            return (before, reasons)
        }
        guard after != before else { return }
        placeWindows(animated: !before.union(after).contains(.userHidden))
        switch (before.isEmpty, after.isEmpty) {
        case (true, false): Trace.count("lens.paused.\(reason.counterName)")
        case (false, true):
            Trace.count("lens.resumed.\(reason.counterName)")
            scheduleCaptureUpdate()
        default: break
        }
    }

    /// The windows as the reasons say: the frame with the pill is up only while nothing keeps the lens off the screen, the panel of
    /// translations is up unless the person hid the lens (a covered lens fades its translations out in place), and what it shows follows
    /// Show Original.
    private func placeWindows(animated: Bool) {
        let reasons = offScreen
        panel.setTranslationsVisible(showsTranslations, animated: animated)
        reasons.isEmpty ? chrome.orderFrontRegardless() : chrome.orderOut(nil)
        reasons.contains(.userHidden) ? panel.orderOut(nil) : panel.orderFrontRegardless()
        showRecent()
    }
}

// MARK: - Fit to Column, snap, Auto Fit (docs/design/lens-fit.md)

/// Where the columns are is `ColumnFit` (Core); when a lens acts on them is `AutoFit`'s table; this is what the session carries out: it takes the
/// columns of each snapshot to screen points, answers the drag's questions (the pull of a column's edge, where a drop settles), animates the lens
/// to a column through the frame window (so the capture and the translations follow as they follow a hand), and reads wider once (a probe) where
/// the capture cut a column.
extension RegionSession {
    /// What a double-click says while the newest snapshot is older than the last motion of the content.
    private static var reading: String { String(localized: "Reading…") }

    // MARK: Columns

    /// A snapshot's columns, in global points with their edges marked (`ColumnFit.marked`), and what waits for a snapshot: a probe, the next judgement.
    func noteColumns(_ s: OverlaySnapshot) {
        // Snapshots hop to the main actor one by one: an older one that comes late must not replace a newer one.
        guard s.version >= fit.version else { return }
        let capture = CGRect(origin: s.origin, size: s.captureSize)
        // An edge is known against what was read, not against the capture: a capture that has just grown holds the strips it uncovered unread, and the
        // blocks end where the old read did (film4 F4/F5: a snap target and a fit 44 pt short of the column).
        let read = s.read.offsetBy(dx: s.origin.x, dy: s.origin.y)
        fit.columns = ColumnFit.marked(s.columns.map { $0.offset(dx: s.origin.x, dy: s.origin.y) }, capture: read, display: display(of: config.rect))
        fit.targets = ColumnFit.Targets(columns: fit.columns)
        fit.version = s.version
        fit.receivedAt = ProcessInfo.processInfo.systemUptime
        fit.captured = read
        if Trace.enabled {
            Trace.mark("lens columns: n=\(fit.columns.count) " + fit.columns.map {
                "[\(TraceNumber.px($0.left))..\(TraceNumber.px($0.right)) blocks=\($0.blocks) lines=\($0.lines) edges=\($0.leftKnown && $0.rightKnown ? "known" : "unknown")]"
            }.joined(separator: " "), since: Trace.now)
        }
        if let probe = fit.probe, let band = fit.band, s.version > probe.version, read.minX <= band.minX + 1, read.maxX >= band.maxX - 1 {
            probeArrived(probe)
        } else {
            fitSettled()
        }
        if s.cut { reachColumns() }
    }

    /// The read dropped a paragraph the capture's side cuts and the lens meets (`OverlaySnapshot.cut`): its lines end at the capture's edge, so there is nothing to lay
    /// out for the lens. The capture becomes the band (the display's width at the lens's rows, as a probe's) until the lens is moved or resized, and the next read holds the
    /// column whole (film4 F16: a lens drawn short of its column showed the page's English, since every line of its paragraph was cut). A hand on the lens waits.
    private func reachColumns() {
        guard Reach.wants(cut: true, widened: fit.band != nil, probing: fit.probe != nil, handOn: dragging || fit.handOn), offScreen.isEmpty else { return }
        Trace.count("lens.reach")
        Trace.mark("reach: the capture cuts a paragraph the lens meets, reading the band", since: Trace.now)
        fit.band = Overscan.band(around: config.rect, display: display(of: config.rect))
        fitCapture(allowResize: true)
    }

    /// The room a fit may take: the lens's display, and the window a window lens follows.
    private func fitBounds() -> CGRect {
        let d = display(of: config.rect)
        guard let anchor = config.anchor, let w = WindowInfo.window(id: anchor.windowID) else { return d }
        let room = d.intersection(w.bounds)
        return room.isNull || room.isEmpty ? d : room
    }

    /// The capture's rect now (global points): the checks see a probe's band in it.
    var captureRect: CGRect { capture }

    private var fitScale: CGFloat { chrome.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// What Fit to Column can say about the column under the lens now.
    private enum FitAnswer { case column(ColumnFit.Column), none, reading }

    private var fitAnswer: FitAnswer {
        guard fit.version > 0 else { return .none }
        // A snapshot that does not hold the lens (it was dragged out of it, the next read is not in), or that is older than the last motion of the
        // content (a zoom, a sideways scroll may have moved the columns), says nothing yet: wait for the next.
        guard fit.captured.contains(config.rect), fit.receivedAt >= fit.contentMovedAt else { return .reading }
        return ColumnFit.under(config.rect, in: fit.columns).map(FitAnswer.column) ?? .none
    }

    // MARK: Menu, double-click, VoiceOver

    /// "Undo Fit" while the lens's old rect is held, else "Fit to Column".
    var fitTitle: String { fit.undo == nil ? String(localized: "Fit to Column") : String(localized: "Undo Fit") }

    func addFitItems(to menu: NSMenu) {
        var enabled = fit.undo != nil, tip: String?
        if !enabled {
            switch fitAnswer {
            case .column: enabled = true
            case .none: tip = String(localized: "Move the lens over one column of text.")
            case .reading: tip = Self.reading
            }
        }
        let row = ActionItem(fitTitle, enabled: enabled) { [weak self] in self?.fitToColumn() }
        row.toolTip = enabled ? nil : tip
        menu.addItem(row)
        let auto = ActionItem(String(localized: "Auto Fit")) { [weak self] in self?.toggleAutoFit() }
        auto.state = config.autoFit ? .on : .off
        menu.addItem(auto)
    }

    /// Fit to Column: the lens's width becomes the column's, its top and height stay. A second call, while the old rect is held, takes it back.
    func fitToColumn() {
        guard !fit.animating, fit.probe == nil, !fit.handOn else { return }
        if let back = fit.undo {
            fit.undo = nil
            move(to: back, edges: nil)
            return
        }
        switch fitAnswer {
        case .none:
            Trace.mark("fit: no column under the lens (\(fit.columns.count) columns)", since: Trace.now)
            chrome.flash(String(localized: "No column here"))
        case .reading:
            Trace.mark("fit: waiting for a newer snapshot (captured \(fit.captured), lens \(config.rect))", since: Trace.now)
            chrome.flash(Self.reading)
        case .column(let column):
            fitNow(to: column)
        }
    }

    private func fitNow(to column: ColumnFit.Column) {
        switch ColumnFit.fitted(config.rect, to: column, within: fitBounds(), scale: fitScale) {
        case .unchanged:
            chrome.flash(String(localized: "Fitted to column"))
        case .probe(let sides):
            startProbe(sides, reason: .manual)
        case .to(let rect, let runsOff):
            fit.undo = config.rect
            move(to: rect, edges: AutoFit.Edges(left: column.left, right: column.right), auto: false, column: column)
            chrome.flash(runsOff ? String(localized: "The column runs off the screen") : String(localized: "Fitted to column"))
        }
    }

    func toggleAutoFit() { setAutoFit(!config.autoFit) }

    /// This lens's Auto Fit, on or off (the menu's row). Turned on, the lens is judged against what it reads now.
    func setAutoFit(_ on: Bool) {
        guard config.autoFit != on else { return }
        config.autoFit = on
        onConfigChange?(config)
        apply(AutoFit.step(fit.machine, on ? .enable : .disable))
        if on { fit.gate.rearm(); fitSettled() }
    }

    // MARK: Animation

    /// One line a frame of the lens's own motion (a hand's or a fit's): the frame-timing log of the feel recordings (addendum A2).
    func traceFrame(_ kind: String, _ rect: CGRect) {
        guard Trace.enabled else { return }
        Trace.mark("lens frame \(kind) \(rect.minX) \(rect.minY) \(rect.width) \(rect.height)", since: Trace.now)
    }

    /// Takes the lens to `rect` (global points) with the window's spring, then commits it as a drop does. `edges`: the column's, remembered as the
    /// last fit (nil: an undo, which fits nothing).
    private func move(to rect: CGRect, edges: AutoFit.Edges?, auto: Bool = false, column: ColumnFit.Column? = nil) {
        if let column {
            Trace.count(auto ? "lens.fit.auto" : "lens.fit.manual")
            Trace.mark("fit: \(auto ? "auto" : "manual") column=\(column.left)..\(column.right) lens=\(config.rect.minX)..\(config.rect.maxX) -> \(rect.minX)..\(rect.maxX) steps=1", since: Trace.now)
        }
        fit.animatingTo = rect
        // The translation is laid out for the lens it will be before it is: the strip it grows over shows Korean when the lens gets there.
        Task { [pipeline] in await pipeline.planLens(for: rect) }
        // The ring's outline plays this moment over the frame (`LensSkin.choreography`): an undo fits nothing.
        let moment: LensSkin.Moment = auto ? .autoFit : edges == nil ? .undoFit : .fit
        chrome.animate(to: ScreenGeometry.appKitRect(fromQuartz: rect), duration: auto ? LensMotion.autoFit : LensMotion.fit, moment: moment) { [weak self] finished in
            guard let self else { return }
            fit.animatingTo = nil
            if finished {
                if let edges { apply(AutoFit.step(fit.machine, auto ? .animationDone(edges) : .fitted(edges))) }
            } else {
                apply(AutoFit.step(fit.machine, .dragged))
            }
            lensDropped()
        }
    }

    // MARK: Snap

    /// The pull of a column's edge on `rect` (the lens as the hand put it): a guide while an edge is within reach, one alignment tick as it comes in.
    private func evaluateSnap(_ rect: CGRect, edges: ColumnFit.Sides) -> ColumnFit.Snap? {
        let free = !settings.lensSnap || fit.commandDown()
        let next = ColumnFit.snap(rect, edges: edges, targets: fit.targets, previous: fit.snap, bypass: free)
        switch ColumnFit.change(from: fit.snap, to: next) {
        case .enter(let snap):
            Trace.count("lens.snap.enter")
            Trace.mark("snap: edge=\(snap.edge == .left ? "left" : "right") target=\(snap.target.x) offset=\(snap.offset)", since: Trace.now)
            let top = max(snap.target.top, display(of: rect).minY), bottom = min(snap.target.bottom, display(of: rect).maxY)
            panel.showGuide(ScreenGeometry.appKitRect(fromQuartz: CGRect(x: snap.target.x, y: top, width: 0, height: max(0, bottom - top))))
            // A move is the window server's: no events, so the tick is ours. A resize has events and the system's filter plays it.
            if edges == .both { AlignmentHaptic.tick() }
        case .leave:
            panel.hideGuide()
        case .none:
            break
        }
        fit.snap = next
        return next
    }

    /// A move frame (`lensMoved`): the first of a hand's moves takes the old rect of a fit away and tells Auto Fit; every one asks the snap.
    func snapMoved(_ rect: CGRect) {
        guard !fit.animating, !fit.settling else { return }
        if !fit.handOn { beginHand() }
        _ = evaluateSnap(rect, edges: .both)
    }

    private func beginHand() {
        fit.handOn = true
        fit.undo = nil
        endProbe()
        apply(AutoFit.step(fit.machine, .dragged))
    }

    /// A resize drag's frame (AppKit) after the snap: the right edge where `LiveSnap` shows it while the guide is up (the guide and the tick: from 8 pt, kept
    /// to 12, hysteresis), the rest as the hand made it. ⌘ held, or Snap off: nothing pulls.
    func snapResized(_ appKitFrame: NSRect) -> NSRect {
        let hand = ScreenGeometry.quartzRect(fromAppKit: appKitFrame)
        let snap = evaluateSnap(hand, edges: .right)
        let free = !settings.lensSnap || fit.commandDown()
        var shown = appKitFrame
        shown.size.width = fit.live.width(hand: hand, snap: snap, targets: free ? ColumnFit.Targets() : fit.targets, at: fit.now())
        if Trace.enabled { Trace.mark("snap: live hand=\(hand.maxX) edge=\(hand.minX + shown.width) guide=\(snap != nil) capturing=\(fit.live.capturing)", since: Trace.now) }
        return shown
    }

    /// A resize let go at `appKitFrame` (which carries what `LiveSnap` shows) while the guide was up: the rest of the way onto the column's edge, as a glide.
    /// Nothing when the edge is on it already (the `instant` feel always, the `dwell` one once the hand has held).
    func settleResized(_ appKitFrame: NSRect) -> NSRect? {
        defer { panel.hideGuide() }
        guard let snap = fit.snap, !fit.commandDown() else { return nil }
        let rest = snap.target.x - ScreenGeometry.quartzRect(fromAppKit: appKitFrame).maxX
        guard abs(rest) >= 0.01 else { return nil }
        var settled = appKitFrame
        settled.size.width = max(ColumnFit.minWidth, appKitFrame.width + rest)
        fit.settling = true
        return settled
    }

    /// A resize frame (`lensResized`): the hand's own makes Auto Fit off for this lens; a fit's frames are not.
    func noteResized() {
        guard !fit.animating else { return }
        let first = !fit.handOn
        if first { fit.handOn = true; fit.undo = nil; endProbe() }
        apply(AutoFit.step(fit.machine, .resized))
        if first { scoutEdges() }
    }

    /// The first frame of a hand's resize, with a column near the lens whose right edge the read ended at: the capture does not follow the corner, so
    /// the snap would have no target where the column really ends (film4 F4). The capture becomes the band for one read, the drag goes on meanwhile,
    /// and the drop ends it. A lens with Snap off, or none of whose columns are cut, reads nothing more.
    private func scoutEdges() {
        guard settings.lensSnap, fit.band == nil, ColumnFit.unknownEdges(near: config.rect, in: fit.columns).contains(.right) else { return }
        Trace.count("lens.fit.scout")
        fit.probe = LensFit.Probe(sides: .right, reason: .scout, since: ProcessInfo.processInfo.systemUptime, version: fit.version)
        fit.band = Overscan.band(around: config.rect, display: display(of: config.rect))
        fitCapture(allowResize: true)
    }

    /// Where a lens let go at `appKitFrame` settles: onto the edge it was pulled to, within reach.
    func settleFrame(for appKitFrame: NSRect) -> NSRect? {
        defer { panel.hideGuide() }
        guard let snap = fit.snap, snap.offset != 0 else { return nil }
        let room = ScreenGeometry.appKitRect(fromQuartz: display(of: config.rect))
        var settled = appKitFrame.offsetBy(dx: snap.offset, dy: 0)
        settled.origin.x = min(max(settled.minX, room.minX), room.maxX - settled.width)
        guard settled != appKitFrame else { return nil }
        fit.settling = true
        return settled
    }

    /// The lens was dropped (`lensDropped`): the snap and its guide are over, the next settle is judged afresh against the columns now.
    func noteDropped() {
        let byHand = fit.handOn
        fit.handOn = false
        fit.settling = false
        fit.snap = nil
        fit.live.reset()
        panel.hideGuide()
        if fit.probe?.reason == .scout { endProbe() }
        if fit.probe == nil, fit.band != nil {
            fit.band = nil
            settleBusy()
        }
        if byHand, fit.machine.state != .off { fit.gate.rearm(); scheduleJudgement(after: fit.calm + 0.05) }
    }

    // MARK: Auto Fit

    /// A read settled, or the lens or the page stopped moving: judge the newest snapshot once (`AutoFit.step`).
    func fitSettled() {
        guard fit.machine.state != .off, !fit.animating, fit.probe == nil else { return }
        switch fit.gate.check(version: fit.version, now: ProcessInfo.processInfo.systemUptime, lastMotion: lastMotion, calm: fit.calm, idle: activity == .idle,
                              dragging: dragging, onScreen: offScreen.isEmpty) {
        case .no: return
        case .wait(let seconds): scheduleJudgement(after: seconds + 0.05)
        case .judge: apply(AutoFit.step(fit.machine, .settled(fitContext)))
        }
    }

    private var fitContext: AutoFit.Context {
        AutoFit.Context(calm: true, lens: config.rect, bounds: fitBounds(), column: ColumnFit.under(config.rect, in: fit.columns), scale: fitScale)
    }

    private func scheduleJudgement(after seconds: TimeInterval) {
        fit.settleTimer?.invalidate()
        fit.settleTimer = Timer.scheduledTimer(withTimeInterval: max(0.05, seconds), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fitSettled() }
        }
    }

    /// Carries out the action a row of the table named.
    private func apply(_ step: (machine: AutoFit.Machine, action: AutoFit.Action)) {
        fit.machine = step.machine
        switch step.action {
        case .none, .commit:
            break
        case .grow(let rect):
            let column = ColumnFit.under(config.rect, in: fit.columns)
            fit.undo = config.rect
            move(to: rect, edges: column.map { AutoFit.Edges(left: $0.left, right: $0.right) }, auto: true, column: column)
        case .probe(let sides):
            startProbe(sides, reason: .auto)
        case .skip(let reason):
            Trace.count("lens.fit.skipped.\(reason.rawValue)")
            Trace.mark("autofit skipped: \(reason.rawValue)", since: Trace.now)
            endProbe()
        case .restoreCapture:
            endProbe()
        case .disable:
            config.autoFit = false
            onConfigChange?(config)
            endProbe()
            chrome.flash(String(localized: "Auto Fit off"))
        }
    }

    // MARK: Probe

    /// One wider read: the capture is the display's width at the lens's rows until the snapshot comes (`Overscan.band`), never during a drag.
    private func startProbe(_ sides: ColumnFit.Sides, reason: LensFit.Probe.Reason) {
        guard !dragging else { return }
        fit.probe = LensFit.Probe(sides: sides, reason: reason, since: ProcessInfo.processInfo.systemUptime, version: fit.version)
        fit.band = Overscan.band(around: config.rect, display: display(of: config.rect))
        Trace.count("lens.fit.probe")
        chrome.setBusy(true)
        fitCapture(allowResize: true)
        fit.probeTimer?.invalidate()
        fit.probeTimer = Timer.scheduledTimer(withTimeInterval: fit.probeTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.probeLapsed() }
        }
    }

    /// The probe's snapshot is in: the edges are known now (or are the display's), and the fit is made from them.
    private func probeArrived(_ probe: LensFit.Probe) {
        fit.probe = nil
        fit.probeTimer?.invalidate()
        switch probe.reason {
        case .auto:
            apply(AutoFit.step(fit.machine, .probed(fitContext)))
            if fit.machine.state != .fitting { endProbe() }
        case .scout:
            break           // the read is in: the snap has its targets. The capture stays the band until the drop.
        case .manual:
            guard case .column(let column) = fitAnswer, case .to(let rect, let runsOff) = ColumnFit.fitted(config.rect, to: column, within: fitBounds(), scale: fitScale) else {
                chrome.flash(String(localized: "No column here"))
                return endProbe()
            }
            fit.undo = config.rect
            move(to: rect, edges: AutoFit.Edges(left: column.left, right: column.right), auto: false, column: column)
            chrome.flash(runsOff ? String(localized: "The column runs off the screen") : String(localized: "Fitted to column"))
        }
    }

    private func probeLapsed() {
        guard let probe = fit.probe else { return }
        Trace.mark("fit probe lapsed after \(fit.probeTimeout) s", since: Trace.now)
        switch probe.reason {
        case .auto: apply(AutoFit.step(fit.machine, .probeLapsed))
        case .manual: chrome.flash(Self.reading)
        case .scout: return
        }
        endProbe()
    }

    /// The capture goes back to its usual shape and the pill to what the reading says.
    private func endProbe() {
        fit.probe = nil
        fit.probeTimer?.invalidate()
        fit.probeTimer = nil
        guard fit.band != nil else { return }
        fit.band = nil
        fitCapture(allowResize: true)
        settleBusy()
    }

    func stopFit() {
        fit.probeTimer?.invalidate()
        fit.settleTimer?.invalidate()
        fit.probeTimer = nil
        fit.settleTimer = nil
    }
}

/// Why a lens is off the screen. A lens is on it while the set is empty, and reads only then; each reason is one row of `names`, which
/// names its work counters (`lens.dropped.<name>`, `lens.paused.<name>`, `lens.resumed.<name>`).
struct OffScreen: OptionSet, Sendable {
    let rawValue: Int
    /// Its window is covered, closed or minimized: the capture shows what is above it, not what the lens is for.
    static let occluded = OffScreen(rawValue: 1 << 0)
    /// The person pressed Hide Lenses.
    static let userHidden = OffScreen(rawValue: 1 << 1)

    private static let names: [(reason: OffScreen, name: String)] = [(.occluded, "occluded"), (.userHidden, "hidden")]
    /// The name of the first reason in the set that has one, in the order of `names`.
    var counterName: String { Self.names.first { contains($0.reason) }?.name ?? "none" }
}

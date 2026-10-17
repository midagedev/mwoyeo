import AppKit
import MwoyeoCore
import MwoyeoEngines
import Observation
import os

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            if settings.shortcuts != oldValue.shortcuts { HotKeys.shared.apply(settings.shortcuts) }
            if settings.checksForUpdates != oldValue.checksForUpdates { Updates.shared.schedule(enabled: settings.checksForUpdates) }
            pushSettings()
        }
    }

    /// The app in front, other than Mwoyeo (see AppProfiles.swift); its profile, if any, lays over the base settings.
    var frontmostBundleID: String? {
        didSet { if frontmostBundleID != oldValue { pushSettings() } }
    }

    /// What translates now: the base settings with the frontmost app's profile over them.
    var effectiveSettings: AppSettings { settings.effective(frontmost: frontmostBundleID) }

    private func pushSettings() {
        let s = effectiveSettings
        Task {
            await translator.update(settings: s)
            for session in sessions.values { await session.update(settings: s) }
        }
    }

    private(set) var regions: [RegionConfig] = [] {
        didSet { save() }
    }

    private(set) var translationsVisible = true
    private(set) var isPaused = false
    private(set) var issue: TranslationIssue?
    /// The engine notice the user closed. It stays closed while that same issue lasts.
    private(set) var dismissedIssue: TranslationIssue?
    private(set) var hasScreenPermission = CGPreflightScreenCaptureAccess()
    private(set) var inpaintingAvailable = false
    /// Bumped when any session's activity/error changes, so views re-read them.
    private(set) var sessionTick = 0

    @ObservationIgnored let translator: TranslationService
    /// Where added engines keep their API keys (the Keychain; memory only when `MWOYEO_MEMORY_SECRETS` is set, for captures).
    @ObservationIgnored let secrets: any SecretStore
    @ObservationIgnored private var sessions: [UUID: RegionSession] = [:]
    @ObservationIgnored private(set) var inpainter: Inpainter?
    @ObservationIgnored private let picker = RegionPicker()
    @ObservationIgnored private var picking = false
    /// The app's preferences; `MWOYEO_DEFAULTS_SUITE` names a scratch domain instead (the capture harness must not touch the real ones).
    @ObservationIgnored private let defaults = ProcessInfo.processInfo.environment["MWOYEO_DEFAULTS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? .standard
    @ObservationIgnored private let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "app")

    private init() {
        let s = (defaults.data(forKey: "settings")).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
        settings = s
        let store: any SecretStore = ProcessInfo.processInfo.environment["MWOYEO_MEMORY_SECRETS"] != nil ? MemorySecrets() : KeychainSecrets()
        secrets = store
        translator = TranslationService(settings: s, secrets: store)
        regions = (defaults.data(forKey: "regions")).flatMap { try? JSONDecoder().decode([RegionConfig].self, from: $0) } ?? []
    }

    private func save() {
        if let d = try? JSONEncoder().encode(settings) { defaults.set(d, forKey: "settings") }
        if let d = try? JSONEncoder().encode(regions) { defaults.set(d, forKey: "regions") }
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        HotKeys.shared.setHandler(.addLens) { [weak self] in Task { await self?.addRegion() } }
        HotKeys.shared.setHandler(.toggleOriginal) { [weak self] in self?.toggleTranslations() }
        HotKeys.shared.setHandler(.pause) { [weak self] in Task { await self?.togglePause() } }
        HotKeys.shared.setHandler(.refresh) { [weak self] in Task { await self?.refreshAll() } }
        HotKeys.shared.setHandler(.saveLensImage) { [weak self] in self?.lensForShortcut()?.saveLensImage() }
        HotKeys.shared.setHandler(.copyOriginal) { [weak self] in self?.lensForShortcut()?.copyOriginal() }
        HotKeys.shared.setHandler(.readAloud) { [weak self] in self?.lensForShortcut()?.toggleReadAloud() }
        HotKeys.shared.apply(settings.shortcuts)
        // Transcripts written so far are closed before the app goes.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessions.values.forEach { $0.finishTranscript(wait: true) } }
        }
        Updates.shared.schedule(enabled: settings.checksForUpdates)
        startWatchingFrontmostApp()
        ImageTranslation.shared.openFromLaunchArguments()

        await translator.setIssueHandler { issue in Task { @MainActor in AppModel.shared.received(issue) } }
        TextRecognizer.setNoticeHandler { issue in Task { @MainActor in AppModel.shared.recognitionNotice(issue) } }
        await translator.setRejectionHandler { id, fields in Task { @MainActor in AppModel.shared.learned(fields, for: id) } }
        await translator.prewarm()
        inpainter = await Task.detached(priority: .userInitiated) { Inpainter.load() }.value
        inpaintingAvailable = inpainter != nil
        Self.warmUpVision()

        if !settings.hasCompletedOnboarding || !hasScreenPermission {
            WindowPresenter.shared.showOnboarding()
        }
        if hasScreenPermission {
            for r in regions where r.isEnabled { await startSession(r) }
        }
        // `--add-region x,y,w,h` (global points, top-left origin): place a lens without picking, for scripted demos.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--add-region"), i + 1 < args.count, hasScreenPermission {
            let v = args[i + 1].split(separator: ",").compactMap { Double($0) }
            if v.count == 4 {
                var config = RegionConfig(name: "", rect: CGRect(x: v[0], y: v[1], width: v[2], height: v[3]))
                config.follow(nil)
                regions.append(config)
                await startSession(config)
                // `--glide dx,dy,seconds,after;…` then drags that lens by script (after = pause before each move).
                if let g = args.firstIndex(of: "--glide"), g + 1 < args.count, let session = sessions[config.id] {
                    let moves = args[g + 1].split(separator: ";").map { $0.split(separator: ",").compactMap { Double($0) } }
                    Task {
                        for m in moves where m.count == 4 {
                            try? await Task.sleep(for: .seconds(m[3]))
                            await session.glide(by: CGVector(dx: m[0], dy: m[1]), duration: m[2])
                        }
                    }
                }
            }
        }
    }

    /// The accurate text recognizer takes tens of seconds to load the first time; do it before the user needs it.
    private static func warmUpVision() {
        Task.detached(priority: .utility) { await loadVision() }
    }

    /// Runs the older recognizers once on a blank image, so their models are loaded when the first real picture comes: they
    /// are what a read uses while the newest models are not ready. Those are loaded by a child process (the app asks them
    /// in this process only after it has finished, see `SwiftVisionWarm`), which this starts; this does not wait for it.
    static func loadVision() async {
        let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.setFillColor(.white)
        ctx?.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        if let img = ctx?.makeImage() {
            await TextRecognizer.warmOlder(img)
            await TextRecognizer.prepareSwift()
        }
    }

    func recheckPermission() {
        hasScreenPermission = CGPreflightScreenCaptureAccess()
    }

    func requestPermission() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
        recheckPermission()
    }

    // MARK: - Regions

    func addRegion() async {
        guard !picking else { return }
        recheckPermission()
        guard hasScreenPermission else {
            WindowPresenter.shared.showOnboarding()
            return
        }
        picking = true
        defer { picking = false }
        guard let result = await picker.pick() else { return }
        var config = RegionConfig(name: "", rect: result.rect)
        config.follow(result.window)
        regions.append(config)
        if isPaused { isPaused = false; for r in regions where r.isEnabled && sessions[r.id] == nil { await startSession(r) } }
        else { await startSession(config) }
    }

    func remove(_ id: UUID) async {
        await sessions.removeValue(forKey: id)?.stop()
        regions.removeAll { $0.id == id }
        sessionTick += 1
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) async {
        guard let i = regions.firstIndex(where: { $0.id == id }) else { return }
        regions[i].isEnabled = enabled
        if enabled, !isPaused { await startSession(regions[i]) } else { await sessions.removeValue(forKey: id)?.stop() }
        sessionTick += 1
    }

    func shortcut(_ action: HotKeyAction) -> String? { settings.shortcuts[action.rawValue]?.display }

    func activity(of id: UUID) -> RegionActivity { sessions[id]?.activity ?? .idle }
    func error(of id: UUID) -> String? { sessions[id]?.errorMessage }
    func isRunning(_ id: UUID) -> Bool { sessions[id] != nil }

    var isBusy: Bool { sessions.values.contains { $0.activity != .idle } }

    /// The lens a lens shortcut acts on: the one under the pointer, else the newest.
    private func lensForShortcut() -> RegionSession? {
        let p = ScreenGeometry.quartzRect(fromAppKit: NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        return regions.last { sessions[$0.id]?.contains(p) == true }.flatMap { sessions[$0.id] }
            ?? regions.last { sessions[$0.id] != nil }.flatMap { sessions[$0.id] }
    }

    private func startSession(_ config: RegionConfig) async {
        guard sessions[config.id] == nil else { return }
        let s = RegionSession(config: config, settings: effectiveSettings, translator: translator, inpainter: inpainter)
        s.onChange = { [weak self] in self?.sessionTick += 1 }
        s.onConfigChange = { [weak self] updated in
            guard let self, let i = regions.firstIndex(where: { $0.id == updated.id }) else { return }
            regions[i].rect = updated.rect
            regions[i].anchor = updated.anchor
            regions[i].name = updated.name
        }
        s.onCloseRequest = { [weak self] in Task { await self?.remove(config.id) } }
        s.onToggleOriginal = { [weak self] in self?.toggleTranslations() }
        sessions[config.id] = s
        s.setTranslationsVisible(translationsVisible)
        await s.start()
    }

    // MARK: - Engines

    /// The added engine in use, nil for Apple.
    var activeEngine: EngineConfig? { settings.activeEngineConfig }

    /// Adds `engine` (its key, if any, is already in the Keychain) and switches to it.
    func addEngine(_ engine: EngineConfig) {
        settings.engines.append(engine)
        settings.customEngineID = engine.id
    }

    func updateEngine(_ engine: EngineConfig) {
        guard let i = settings.engines.firstIndex(where: { $0.id == engine.id }) else { return }
        settings.engines[i] = engine
    }

    /// A copy under a new id, with its own (empty) key slot.
    func duplicateEngine(_ id: UUID) {
        guard let e = settings.engines.first(where: { $0.id == id }) else { return }
        settings.engines.append(EngineConfig(name: String(localized: "\(e.name) copy"), kind: e.kind))
    }

    /// Removes the engine, its saved key and what it learned about its server.
    func removeEngine(_ id: UUID) {
        try? secrets.setSecret(nil, for: id)
        settings.engineRejections[id] = nil
        if settings.customEngineID == id { settings.customEngineID = nil }
        settings.engines.removeAll { $0.id == id }
    }

    /// nil picks Apple.
    func selectEngine(_ id: UUID?) {
        settings.customEngineID = id
    }

    /// A radio of the engine group: an Apple choice (which also leaves any added engine) or an added engine.
    func select(_ choice: EngineSelection) {
        switch choice {
        case let .builtIn(c):
            settings.engine = c
            selectEngine(nil)
        case let .added(id):
            selectEngine(id)
        }
    }

    private func learned(_ fields: [String], for id: UUID) {
        guard settings.engines.contains(where: { $0.id == id }) else { return }
        let saved = fields.isEmpty ? nil : fields
        if settings.engineRejections[id] != saved { settings.engineRejections[id] = saved }
    }

    /// The issue the menu panel shows: the current one unless the user closed it.
    var shownIssue: TranslationIssue? { issue == dismissedIssue ? nil : issue }

    /// The user closed the engine notice.
    func dismissIssue() {
        if case .engineUnavailable? = issue { dismissedIssue = issue }
    }

    /// What an incoming issue does: the dismissed record that survives it (only the same issue keeps it), and whether
    /// the lenses are told (once per engine issue, never for one the user closed).
    nonisolated static func step(old: TranslationIssue?, new: TranslationIssue?, dismissed: TranslationIssue?)
        -> (dismissed: TranslationIssue?, tellLenses: Bool) {
        let closed = new != nil && new == dismissed
        guard case .engineUnavailable? = new else { return (nil, false) }
        return (closed ? dismissed : nil, new != old && !closed)
    }

    /// The text recognizer's notice, or its end. Only the recognizer ends it: a translation that went well says nothing
    /// about reading.
    func recognitionNotice(_ new: TranslationIssue?) {
        if let new { received(new) } else if issue?.isTextRecognition == true { issue = nil }
    }

    /// Shows the issue in the menu panel, and once on every lens when an engine gave way to Apple.
    func received(_ new: TranslationIssue?) {
        if new == nil, issue?.isTextRecognition == true { return }
        let step = Self.step(old: issue, new: new, dismissed: dismissedIssue)
        issue = new
        dismissedIssue = step.dismissed
        if step.tellLenses {
            for s in sessions.values { s.showNotice(new?.headline ?? "") }
        }
    }

    // MARK: - Global actions

    func toggleTranslations() {
        translationsVisible.toggle()
        sessions.values.forEach { $0.setTranslationsVisible(translationsVisible) }
    }

    func togglePause() async {
        isPaused.toggle()
        if isPaused {
            for s in sessions.values { await s.stop() }
            sessions.removeAll()
        } else {
            for r in regions where r.isEnabled { await startSession(r) }
        }
        sessionTick += 1
    }

    func refreshAll() async {
        await translator.invalidateAvailability()
        for s in sessions.values { await s.refresh() }
    }

    func languagePacksChanged() async {
        received(nil)
        await refreshAll()
    }
}

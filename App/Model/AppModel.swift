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
            saveSettings()
            if settings.shortcuts != oldValue.shortcuts { HotKeys.shared.apply(settings.shortcuts) }
            #if !MAS
            if settings.checksForUpdates != oldValue.checksForUpdates { Updates.shared.schedule(enabled: settings.checksForUpdates) }
            #endif
            pushSettings()
            if settings.savesTranscripts, !oldValue.savesTranscripts || settings.exportFolder != oldValue.exportFolder {
                learnedFile?.savingTurnedOn(for: learnedCounts.filter { $0.value.usable > 0 }.map(\.key))
            }
        }
    }

    /// The app in front, other than Mwoyeo (see AppProfiles.swift); its profile, if any, lays over the base settings for what has no lens of
    /// its own: the menu bar's language bar, the image window, the service's own route. A lens translates with the profile of the app UNDER
    /// it (`RegionSession`, `LensRoute`), so the app in front does not reach it.
    var frontmostBundleID: String? {
        didSet { if frontmostBundleID != oldValue { pushFront() } }
    }

    /// What translates now where no lens decides: the base settings with the frontmost app's profile over them.
    var effectiveSettings: AppSettings { settings.effective(frontmost: frontmostBundleID) }

    /// The service gets the settings in effect for the app in front (its own route), and every lens the base settings, which each lays
    /// the profile of its own app over (`RegionSession.update`).
    private func pushSettings() {
        let front = effectiveSettings, base = settings
        lastPush = Task {
            await translator.update(settings: front)
            for session in sessions.values { await session.update(settings: base) }
        }
    }

    /// The app in front changed: only what has no lens of its own follows it.
    private func pushFront() {
        let front = effectiveSettings
        lastPush = Task { await translator.update(settings: front) }
    }

    /// The last push (the check harness waits for it).
    @ObservationIgnored private var lastPush: Task<Void, Never>?
    func pushed() async { await lastPush?.value }

    private(set) var regions: [RegionConfig] = [] {
        didSet { saveRegions() }
    }

    /// What is wrong in settings.json as last read (empty when nothing is); Settings › General shows the first.
    private(set) var settingsIssues: [SettingsFileIssue] = []

    private(set) var translationsVisible = true
    private(set) var isPaused = false
    private(set) var issue: TranslationIssue?
    /// The engine notice the user closed. It stays closed while that same issue lasts.
    private(set) var dismissedIssue: TranslationIssue?
    private(set) var hasScreenPermission = CGPreflightScreenCaptureAccess()
    private(set) var inpaintingAvailable = false
    /// Bumped when any session's activity/error changes, so views re-read them.
    private(set) var sessionTick = 0
    /// The tab Settings opens on: a lens's "Download <language>" lands on Translation, where the pack comes down.
    var settingsTab = SettingsTab.general

    @ObservationIgnored let translator: TranslationService
    /// How many learned rows each app has (`learnedRowsChanged` sets it); a view of the Memory sheet reads it to know when to look again.
    var learnedCounts: [String: LearnedCounts] = [:]
    /// Writes the apps' learned rows beside the transcripts while Save transcripts is on (`LearnedMemoryWriter`).
    @ObservationIgnored var learnedFile: LearnedMemoryWriter?
    /// Where added engines keep their API keys (`SecretStoreChoice`: the Keychain; memory only when `MWOYEO_MEMORY_SECRETS` is set, for captures).
    @ObservationIgnored let secrets: any SecretStore
    /// settings.json, the source of truth of `settings`; the preferences keep a copy for a downgrade.
    @ObservationIgnored let settingsFile = SettingsFileStore()
    /// True while a reload from the file is applied: the file already says it, so it is not written back.
    @ObservationIgnored private var applyingFile = false
    @ObservationIgnored private var loggedIssues: [SettingsFileIssue] = []
    @ObservationIgnored private var sessions: [UUID: RegionSession] = [:]
    @ObservationIgnored private(set) var inpainter: Inpainter?
    @ObservationIgnored private let picker = RegionPicker()
    /// Hears the Mac wake and the displays change, for the lenses' captures (`CaptureRecovery`).
    @ObservationIgnored private var displayWatcher: DisplayWatcher?
    @ObservationIgnored private var picking = false
    /// The one-shot that looks at the lens hints again when the text recognizer's setup has run long enough to show.
    @ObservationIgnored private var setupClock: Timer?
    /// While a lens asks to allow Screen Recording: looks at the grant once a second, so that the lens moves on the moment it is given.
    @ObservationIgnored private var grantClock: Timer?
    /// The app's preferences; `MWOYEO_DEFAULTS_SUITE` names a scratch domain instead (the capture harness must not touch the real ones).
    #if MAS
    @ObservationIgnored private let defaults = UserDefaults.standard
    #else
    @ObservationIgnored private let defaults = ProcessInfo.processInfo.environment["MWOYEO_DEFAULTS_SUITE"].flatMap { UserDefaults(suiteName: $0) } ?? .standard
    #endif
    @ObservationIgnored private let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "app")

    private init() {
        let blob = defaults.data(forKey: "settings")
        let saved = blob.flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
        var s = settingsFile.startup(fallback: saved)
        // After a downgrade to a version before the file and back, what that version changed is newer than settings.json.
        let newer = Self.olderVersionChanges(blob: blob, mirror: defaults.data(forKey: Self.mirrorKey))
        if !newer.isEmpty, var d = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(s))) as? [String: Any] {
            d.merge(newer) { $1 }
            if let data = try? JSONSerialization.data(withJSONObject: d), let merged = try? JSONDecoder().decode(AppSettings.self, from: data) {
                s = merged
                settingsFile.save(s)
            }
        }
        // The first start of the version that asks: the DMG's engines in settings.json are allowed once; the App Store build allows none.
        s.enginePermissions.launch(engines: s.engines, grantsExisting: !Distribution.isAppStore)
        settings = s
        settingsIssues = settingsFile.issues
        let store = SecretStoreChoice.current()
        secrets = store
        translator = TranslationService(settings: s, secrets: store)
        regions = (defaults.data(forKey: "regions")).flatMap { try? JSONDecoder().decode([RegionConfig].self, from: $0) } ?? []
        // The preferences' copy follows the file (a downgrade keeps the settings); the file itself is not touched here.
        if s != saved || defaults.data(forKey: Self.mirrorKey) != blob, let d = try? JSONEncoder().encode(s) { mirror(d) }
    }

    /// The preferences get the whole settings (a downgrade to a version before the file keeps them); the file gets its keys.
    private func saveSettings() {
        if let d = try? JSONEncoder().encode(settings) { mirror(d) }
        guard !applyingFile else { return }
        settingsFile.save(settings)
        settingsIssues = settingsFile.issues
    }

    /// The preferences' copy, and the same bytes under `mirrorKey`: a later difference means an older version wrote them.
    private func mirror(_ d: Data) {
        defaults.set(d, forKey: "settings")
        defaults.set(d, forKey: Self.mirrorKey)
    }

    private static let mirrorKey = "settingsMirror"

    /// The keys whose values a version before the settings file (1.1.0) changed in the preferences since this version last
    /// wrote them (`mirror`); empty when nothing did. Compared as JSON values, so re-encoding alone changes nothing.
    nonisolated static func olderVersionChanges(blob: Data?, mirror: Data?) -> [String: Any] {
        guard let blob, let mirror, blob != mirror,
              let b = (try? JSONSerialization.jsonObject(with: blob)) as? [String: Any],
              let m = (try? JSONSerialization.jsonObject(with: mirror)) as? [String: Any] else { return [:] }
        return b.filter { key, value in !(m[key].map { ($0 as AnyObject).isEqual(value) } ?? false) }
    }

    private func saveRegions() {
        if let d = try? JSONEncoder().encode(regions) { defaults.set(d, forKey: "regions") }
    }

    /// settings.json changed on disk: its valid keys apply as a change in Settings would (lenses, engine and shortcuts follow).
    func settingsFileChanged() {
        let result = settingsFile.fileChanged(current: settings)
        settingsIssues = settingsFile.issues
        if let first = settingsIssues.first, settingsIssues != loggedIssues {
            loggedIssues = settingsIssues
            log.notice("settings file: \(self.settingsIssues.count) issue(s), first at line \(first.line ?? 0): \(first.message, privacy: .public)")
        }
        guard let result else { return }
        applyingFile = true
        settings = result.settings
        applyingFile = false
        if !result.changed.isEmpty { log.notice("settings reloaded: \(result.changed.joined(separator: ", "), privacy: .public)") }
    }

    /// The folder for saved images and transcripts, chosen in a panel: its path for display, its bookmark to open it again.
    func chooseExportFolder(_ url: URL, bookmark: Data) {
        settings.exportFolder = url.path
        settings.exportBookmark = bookmark
    }

    /// Applies the keys of a settings.json from the GitHub version (the App Store build's one-time import) over the current
    /// settings, through the same checks as the app's own file: a key that is wrong is reported and left as it is, text that is
    /// not JSON changes nothing. Keys kept out of the file (the folder bookmark, onboarding) stay.
    func importSettings(from url: URL) -> SettingsImport {
        guard let data = try? Data(contentsOf: url) else { return SettingsImport(applied: [], issues: [.init(line: nil, message: "the file could not be read")], parsed: false) }
        let result = SettingsFileStore.importResult(data, over: settings)
        if result.parsed, !result.changed.isEmpty {
            settings = result.settings
        }
        return SettingsImport(applied: result.changed, issues: result.issues, parsed: result.parsed)
    }

    func openSettingsFile() { NSWorkspace.shared.open(settingsFile.url) }
    func showSettingsFile() { NSWorkspace.shared.activateFileViewerSelecting([settingsFile.url]) }

    // MARK: - Lifecycle

    func bootstrap() async {
        // A relaunch (`relaunch()`) starts before the old process is gone: its shortcuts and its lenses wait for it.
        await Relaunch.waitForPredecessor()
        HotKeys.shared.setHandler(.addLens) { [weak self] in Task { await self?.addRegion() } }
        HotKeys.shared.setHandler(.toggleOriginal) { [weak self] in self?.toggleTranslations() }
        HotKeys.shared.setHandler(.hideLenses) { [weak self] in self?.toggleLensesHidden() }
        HotKeys.shared.setHandler(.pause) { [weak self] in Task { await self?.togglePause() } }
        HotKeys.shared.setHandler(.refresh) { [weak self] in Task { await self?.refreshAll() } }
        HotKeys.shared.setHandler(.saveLensImage) { [weak self] in self?.lensForShortcut()?.saveLensImage() }
        HotKeys.shared.setHandler(.copyOriginal) { [weak self] in self?.lensForShortcut()?.copyOriginal() }
        HotKeys.shared.setHandler(.readAloud) { [weak self] in self?.lensForShortcut()?.toggleReadAloud() }
        HotKeys.shared.apply(settings.shortcuts)
        settingsFile.startWatching { [weak self] in self?.settingsFileChanged() }
        // Transcripts written so far are closed before the app goes.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessions.values.forEach { $0.finishTranscript(wait: true) } }
        }
        displayWatcher = DisplayWatcher { [weak self] event in self?.displaysChanged(event) }
        #if !MAS
        Updates.shared.schedule(enabled: settings.checksForUpdates)
        #endif
        startWatchingFrontmostApp()
        #if !MAS
        ImageTranslation.shared.openFromLaunchArguments()
        #endif

        await translator.setIssueHandler { issue in Task { @MainActor in AppModel.shared.received(issue) } }
        TextRecognizer.setNoticeHandler { issue in Task { @MainActor in AppModel.shared.recognitionNotice(issue) } }
        VisionSetup.shared.onChange = { [weak self] in self?.visionSetupChanged() }
        await translator.setRejectionHandler { id, fields in Task { @MainActor in AppModel.shared.learned(fields, for: id) } }
        learnedFile = LearnedMemoryWriter.live(settings: { AppModel.shared.settings },
                                               store: { AppModel.shared.chooseExportFolder($1, bookmark: $0) },
                                               records: { await AppModel.shared.translator.learnedRows(for: $0) })
        await translator.setLearnedHandler { bundleID in Task { @MainActor in AppModel.shared.learnedRowsChanged(bundleID) } }
        await translator.prewarm()
        inpainter = await Task.detached(priority: .userInitiated) { Inpainter.load() }.value
        inpaintingAvailable = inpainter != nil
        // The warm-up starts at launch, granted or not, and stays so (lens-robust, 2026-10-18; tools/ocr-probe/relaunch-cold.sh). A relaunch
        // restarts the cold compile (killed at 30 s: 62.0 s after the relaunch, against 64.3 s undisturbed), so one could wait for the
        // grant of Screen Recording. Waiting never shortens a first wait: someone who must relaunch after granting pays the 64 s from the
        // relaunch either way (the compile of the first process is lost in both), and someone who need not relaunch pays the time they
        // took to grant on top of it. Someone who granted before launching starts it at once in both.
        Self.warmUpVision(settings.sourceLanguage)

        if !settings.hasCompletedOnboarding || !hasScreenPermission {
            WindowPresenter.shared.showOnboarding()
        }
        if hasScreenPermission {
            for r in regions where r.isEnabled { await startSession(r) }
        }
        #if !MAS
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
        #endif
    }

    /// The accurate text recognizer takes tens of seconds to load the first time; do it before the user needs it.
    private static func warmUpVision(_ source: String) {
        Task.detached(priority: .utility) { await loadVision(source: source) }
    }

    /// The initialization of the text models for the source language ("auto": detected), so that they are loaded when the first
    /// real picture comes (`TextRecognizer.warmUp`).
    static func loadVision(source: String = "auto") async {
        await TextRecognizer.warmUp(languages: source == "auto" ? [] : [Locale.Language(identifier: source)])
    }

    /// The Mac woke or its displays changed: every lens looks at its capture once things have settled.
    private func displaysChanged(_ event: CaptureEvent) {
        sessions.values.forEach { $0.displaysChanged(event) }
    }

    /// A lens needs the person: Screen Recording is missing for lenses that are on, or a lens's capture is down for good. The menu bar
    /// icon wears a badge for it (`MenuBarIcon`).
    var lensNeedsAttention: Bool {
        _ = sessionTick   // the sessions are not observed: their changes bump this
        let enabled = regions.filter(\.isEnabled).count
        return !isPaused && MenuBarIcon.needsAttention(permissionGranted: hasScreenPermission, enabledLenses: enabled,
                                                       lensesDown: sessions.values.filter(\.needsAttention).count)
    }

    func recheckPermission() {
        let was = hasScreenPermission
        hasScreenPermission = CGPreflightScreenCaptureAccess()
        if hasScreenPermission != was { permissionChanged() }
    }

    func requestPermission() {
        if !CGRequestScreenCaptureAccess() { openScreenRecordingSettings() }
        recheckPermission()
    }

    /// System Settings on Privacy & Security › Screen Recording.
    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// System Settings on General › Storage, where the person frees space (the pane's id is the bundle id of Storage.appex).
    func openStorageSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
    }

    /// The grant came or went while the app ran. After a grant, saved lenses that could not start do now (until now they
    /// stayed dead until the next launch), and a lens whose capture was refused tries once more: if this process cannot use
    /// the grant yet, the lens says to restart.
    private func permissionChanged() {
        refreshHints()
        guard hasScreenPermission, !isPaused else { return }
        Task {
            for r in regions where r.isEnabled && sessions[r.id] == nil { await startSession(r) }
            for s in sessions.values { await s.retryCapture() }
        }
    }

    /// Starts the app again and quits this one; the saved lenses open in the new one. A grant of Screen Recording takes
    /// effect only in a process started after it.
    func relaunch() { Relaunch.run() }

    /// A lens's "Download <language>": Settings on Translation, with the pack's download sheet up. A pair whose sheet is up already
    /// only brings that window forward. Without a way to open Settings there is no window for the sheet: the ask ends as a download
    /// that did not finish, which every surface then says (never a download that "runs" with nothing to show it).
    func downloadPack(_ pair: PackPair) {
        PackDownload.shared.request(pair, in: .settings)
        if !openSettings(on: .translation) { Task { await PackDownload.shared.abandon(pair, in: .settings) } }
    }

    /// Settings on `tab` in front of the other windows; false when the app has no way to open it yet (`openSettingsAction`).
    @discardableResult
    func openSettings(on tab: SettingsTab) -> Bool {
        settingsTab = tab
        NSApp.activate(ignoringOtherApps: true)
        guard let open = openSettingsAction else { return false }
        open()
        return true
    }

    /// The app whose Memory sheet Settings (Translation) shows, if any: a lens's "Memory for <App>…" sets it (`openMemory`), the sheet's
    /// Done clears it.
    var memoryTarget: MemoryTarget?

    /// Opens the Settings window; set by the menu bar item's view (`SettingsOpener`), the only holder of SwiftUI's `openSettings`.
    @ObservationIgnored var openSettingsAction: (() -> Void)?

    // MARK: - What the lenses say

    /// The text recognizer is in its first-time setup, or macOS is still preparing a recognizer for the source language.
    var recognitionPreparing: Bool {
        if case .textRecognitionStarting? = issue { return true }
        let (gate, now) = VisionSetupDisplay.current
        return gate.shouldShowProgress(now: now) && !VisionSetupDisplay.failed(gate) && !VisionSetupDisplay.allDone(gate)
    }

    /// Every lens looks at what it should say again (an issue, the setup, the grant changed).
    func refreshHints() {
        sessions.values.forEach { $0.refreshHint() }
        let needsGrant = sessions.values.contains { $0.shownHint == .allowScreenRecording }
        if needsGrant, grantClock == nil {
            let t = Timer(timeInterval: 1, repeats: true) { _ in Task { @MainActor in AppModel.shared.recheckPermission() } }
            RunLoop.main.add(t, forMode: .common)
            grantClock = t
        } else if !needsGrant {
            grantClock?.invalidate()
            grantClock = nil
        }
    }

    /// The text recognizer's setup moved on. Its progress shows after `SwiftVisionGate.showAfter` seconds of a step, which no
    /// event marks: one look at that moment.
    func visionSetupChanged() {
        refreshHints()
        setupClock?.invalidate()
        setupClock = nil
        let (gate, now) = VisionSetupDisplay.current
        let due = gate.steps.values.compactMap { state -> TimeInterval? in
            if case let .running(since) = state { since + SwiftVisionGate.showAfter - now } else { nil }
        }.filter { $0 > 0 }.min()
        guard let due else { return }
        setupClock = Timer.scheduledTimer(withTimeInterval: due + 0.05, repeats: false) { _ in
            Task { @MainActor in AppModel.shared.refreshHints() }
        }
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
        RegionSession.setHiding(false, in: sessions.values)   // a lens added while the others are hidden brings them back
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
        refreshHints()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) async {
        guard let i = regions.firstIndex(where: { $0.id == id }) else { return }
        regions[i].isEnabled = enabled
        if enabled, !isPaused { await startSession(regions[i]) } else { await sessions.removeValue(forKey: id)?.stop() }
        sessionTick += 1
        refreshHints()
    }

    func shortcut(_ action: HotKeyAction) -> String? { settings.shortcuts[action.rawValue]?.display }

    func activity(of id: UUID) -> RegionActivity { sessions[id]?.activity ?? .idle }
    func error(of id: UUID) -> String? { sessions[id]?.errorMessage }

    /// What this lens's pill says now when it is about the language pair (a pack to download, downloading, not finished, no translation):
    /// the menu panel repeats it in the lens's row, with the same action. Other hints stay on the pill.
    func languageHint(of id: UUID) -> LensHint? {
        (capturedHints[id] ?? sessions[id]?.shownHint).flatMap { $0.isAboutLanguages ? $0 : nil }
    }

    /// `--capture-ui` puts a hint on a lens row without a running lens (a capture has no Screen Recording grant to start one with).
    @ObservationIgnored var capturedHints: [UUID: LensHint] = [:]

    /// The click on that line, wherever it was clicked: the pill's or the row's.
    func performHint(of id: UUID) { sessions[id]?.performHint() }

    /// Some lens says the language pair's trouble itself: the panel's own banner for the same issue would only say it twice.
    var lensesSayLanguageTrouble: Bool {
        sessions.values.contains { $0.shownHint?.isAboutLanguages == true } || capturedHints.values.contains { $0.isAboutLanguages }
    }
    func isRunning(_ id: UUID) -> Bool { sessions[id] != nil }

    /// A lens the check harness made (a `RegionSession` with a capturer of its own): it hears every push as the ones `startSession` makes do.
    func attach(_ session: RegionSession, id: UUID) { sessions[id] = session }
    func detach(_ id: UUID) { sessions[id] = nil }

    var isBusy: Bool { sessions.values.contains { $0.activity != .idle } }

    /// The lens a lens shortcut acts on: the one under the pointer, else the newest.
    private func lensForShortcut() -> RegionSession? {
        let p = ScreenGeometry.quartzRect(fromAppKit: NSRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        return regions.last { sessions[$0.id]?.contains(p) == true }.flatMap { sessions[$0.id] }
            ?? regions.last { sessions[$0.id] != nil }.flatMap { sessions[$0.id] }
    }

    private func startSession(_ config: RegionConfig) async {
        guard sessions[config.id] == nil else { return }
        // A saved lens may have been left on a display this Mac no longer has (an unplugged one, a smaller resolution): it comes up on the
        // main display instead of off every screen.
        var config = config
        var moved = false
        if case let .move(to) = CaptureRecovery.decide(.launch, lens: config.rect, followsWindow: config.anchor != nil, streamDisplay: nil,
                                                       layout: .current, failures: 0) {
            config.rect = to
            moved = true
            if let i = regions.firstIndex(where: { $0.id == config.id }) { regions[i].rect = to }
        }
        let s = RegionSession(config: config, settings: settings, translator: translator, inpainter: inpainter)
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
        if moved { s.showNotice(String(localized: "Moved to the main display")) }
    }

    // MARK: - Engines

    /// The added engine in use, nil for Apple.
    var activeEngine: EngineConfig? { settings.activeEngineConfig }

    /// Adds `engine` (its key, if any, is already in the Keychain) and switches to it.
    func addEngine(_ engine: EngineConfig) {
        settings.engines.append(engine)
        settings.customEngineID = engine.id
    }

    /// Replaces the engine of the same id with `engine`. The Settings sheet builds `engine` from its own fields (address, model,
    /// headers), which do not include `context`, so an `engine` without one keeps the context the stored engine has (the user's,
    /// or one an agent wrote in settings.json).
    func updateEngine(_ engine: EngineConfig) {
        guard let i = settings.engines.firstIndex(where: { $0.id == engine.id }) else { return }
        var updated = engine
        updated.context = engine.context ?? settings.engines[i].context
        settings.engines[i] = updated
    }

    /// The person ticked (or cleared) "Send the text the lens reads to <host>" in the engine's sheet; only the sheet calls this.
    func setSendingAllowed(_ allowed: Bool, for engine: EngineConfig) {
        settings.enginePermissions.set(allowed, for: engine)
    }

    /// A copy under a new id, with its own (empty) key slot. It is the same user's engine, so its context is copied.
    func duplicateEngine(_ id: UUID) {
        guard let e = settings.engines.first(where: { $0.id == id }) else { return }
        settings.engines.append(EngineConfig(name: String(localized: "\(e.name) copy"), kind: e.kind, context: e.context))
    }

    /// Removes the engine, its saved key and what it learned about its server.
    func removeEngine(_ id: UUID) {
        try? secrets.setSecret(nil, for: id)
        settings.engineRejections[id] = nil
        settings.enginePermissions.forget(id)
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
        if let new { received(new) } else if issue?.isTextRecognition == true { issue = nil; refreshHints() }
    }

    /// Shows the issue in the menu panel, and once on every lens when an engine gave way to Apple.
    func received(_ new: TranslationIssue?) {
        if new == nil, issue?.isTextRecognition == true { return }
        let step = Self.step(old: issue, new: new, dismissed: dismissedIssue)
        let changed = issue != new
        issue = new
        dismissedIssue = step.dismissed
        if step.tellLenses {
            for s in sessions.values { s.showNotice(new?.headline ?? "") }
        }
        if changed { refreshHints() }
    }

    // MARK: - Global actions

    func toggleTranslations() {
        translationsVisible.toggle()
        sessions.values.forEach { $0.setTranslationsVisible(translationsVisible) }
    }

    /// Some lens is hidden by the Hide Lenses key; false with no lens up (Pause takes them down, and the lenses it brings back are new).
    var lensesHidden: Bool {
        _ = sessionTick   // the sessions are not observed: their changes bump this
        return sessions.values.contains { $0.isHiddenByUser }
    }

    /// Hide Lenses: while any lens is hidden, every lens comes back with the lines it had; otherwise every lens goes off the screen and reads nothing.
    func toggleLensesHidden() {
        RegionSession.toggleHiding(sessions.values)
        sessionTick += 1
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
        refreshHints()
    }

    func refreshAll() async {
        await translator.invalidateAvailability()
        for s in sessions.values { await s.refresh() }
    }

    func languagePacksChanged() async {
        PackDownload.shared.packsChanged()
        received(nil)
        await refreshAll()
    }
}

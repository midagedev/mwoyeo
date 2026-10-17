import AppKit
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
    private(set) var hasScreenPermission = CGPreflightScreenCaptureAccess()
    private(set) var inpaintingAvailable = false
    /// Bumped when any session's activity/error changes, so views re-read them.
    private(set) var sessionTick = 0

    @ObservationIgnored let translator: TranslationService
    @ObservationIgnored private var sessions: [UUID: RegionSession] = [:]
    @ObservationIgnored private(set) var inpainter: Inpainter?
    @ObservationIgnored private let picker = RegionPicker()
    @ObservationIgnored private var picking = false
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "app")

    private init() {
        let s = (defaults.data(forKey: "settings")).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
        settings = s
        translator = TranslationService(settings: s)
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

        await translator.setIssueHandler { issue in Task { @MainActor in AppModel.shared.issue = issue } }
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
        Task.detached(priority: .utility) {
            let ctx = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.setFillColor(.white)
            ctx?.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
            if let img = ctx?.makeImage() {
                _ = try? await TextRecognizer.lines(in: img, languages: [Locale.Language(identifier: "ja")], fast: false)
                _ = try? await TextRecognizer.blocks(in: img, languages: [])
            }
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
        issue = nil
        await refreshAll()
    }
}

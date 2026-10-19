import AppKit
import MwoyeoCore

/// What an edit of one app's memory did (`AppModel.setMemoryNote` and the like). The Memory sheet shows `.full` and `.invalid`.
enum MemoryEdit: Equatable {
    /// Written to the profile (and so to settings.json).
    case saved
    /// The app has no profile; an edit never creates one (a profile also fixes the app's language pair).
    case noProfile
    /// The profile already has `AppProfile.maxEntries` rows.
    case full
    /// The row has no source or no translation.
    case invalid
}

/// How many learned rows an app has: `usable` ones go into requests, `waiting` ones have been seen once.
struct LearnedCounts: Equatable {
    var usable = 0
    var waiting = 0

    init(_ records: [ContextMemory.LearnedRecord] = []) {
        usable = records.filter(\.isUsable).count
        waiting = records.count - usable
    }
}

/// Per-app language profiles. The app in front picks which one applies, so only one pair is in effect at a time:
/// a lens over a window of another app translates with the pair of the app you are using, not the one it covers.
extension AppModel {
    /// Follows the frontmost app. Mwoyeo itself never counts (opening Settings must not drop the profile in use).
    func startWatchingFrontmostApp() {
        let me = Bundle.main.bundleIdentifier
        func note(_ app: NSRunningApplication?) {
            guard let id = app?.bundleIdentifier, id != me else { return }
            frontmostBundleID = id
        }
        note(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { note(app) }
        }
    }

    /// The profile in effect now.
    var activeProfile: AppProfile? { AppProfiles.profile(for: frontmostBundleID, in: settings.appProfiles) }

    func profile(for bundleID: String) -> AppProfile? { AppProfiles.profile(for: bundleID, in: settings.appProfiles) }

    /// The language bar's edits: they go to the profile in effect, else to the base settings.
    func setLanguages(source: String? = nil, target: String? = nil) {
        if let p = activeProfile, let i = settings.appProfiles.firstIndex(of: p) {
            if let source { settings.appProfiles[i].source = source }
            if let target { settings.appProfiles[i].target = target }
        } else {
            if let source { settings.sourceLanguage = source }
            if let target { settings.targetLanguage = target }
        }
    }

    func remember(_ profile: AppProfile) {
        settings.appProfiles = AppProfiles.remembering(profile, in: settings.appProfiles)
    }

    func forgetProfile(_ bundleID: String) {
        settings.appProfiles.removeAll { $0.bundleID == bundleID }
    }

    /// The app that owns window `id`, for a lens that follows it.
    static func app(ofWindow id: CGWindowID) -> (bundleID: String, name: String)? {
        guard let w = WindowInfo.window(id: id), let app = NSRunningApplication(processIdentifier: w.pid),
              let bundleID = app.bundleIdentifier else { return nil }
        return (bundleID, app.localizedName ?? w.appName)
    }
}

/// What the paragraph reader knows about the app a lens covers.
extension AppModel {
    /// The app under a lens: the window it follows, else the topmost window under its centre.
    static func readerContext(for config: RegionConfig) -> ReaderContext {
        let app: (bundleID: String, name: String)?
        if let anchor = config.anchor {
            app = Self.app(ofWindow: anchor.windowID)
        } else if let w = WindowInfo.onScreen().first(where: { $0.bounds.contains(CGPoint(x: config.rect.midX, y: config.rect.midY)) }),
                  let running = NSRunningApplication(processIdentifier: w.pid), let id = running.bundleIdentifier {
            app = (id, running.localizedName ?? w.appName)
        } else {
            app = nil
        }
        guard let app else { return ReaderContext() }
        return ReaderContext(bundleID: app.bundleID, category: category(ofApp: app.bundleID))
    }

    /// `LSApplicationCategoryType` from the app's Info.plist; nil when the app has none or the plist cannot be read (the decider
    /// then goes by the bundle ID and the layout).
    static func category(ofApp bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
    }
}

/// The memory of one app, as the Memory sheet edits it (design §3): the note, the names and terms, the context override, and the
/// rows the app learned. The user's part is the profile's (`appProfiles[].note`, `.entries`, `.context` in settings.json); the learned
/// rows are the translator's, in RAM. Nothing here creates a profile: the sheet is entered from an existing profile's menu.
extension AppModel {
    private func editProfile(_ bundleID: String, _ body: (inout AppProfile) -> MemoryEdit) -> MemoryEdit {
        guard let i = settings.appProfiles.firstIndex(where: { $0.bundleID == bundleID }) else { return .noProfile }
        var p = settings.appProfiles[i]
        let result = body(&p)
        if result == .saved, p != settings.appProfiles[i] { settings.appProfiles[i] = p }
        return result
    }

    /// The note for the translator. Trimmed and cut at `AppProfile.maxNoteLength`; empty clears it.
    @discardableResult
    func setMemoryNote(_ note: String, for bundleID: String) -> MemoryEdit {
        editProfile(bundleID) { $0.note = note; return .saved }
    }

    /// Adds a name or term, or replaces the row whose source is `replacing` (the source may change). See `AppProfile.setEntry`.
    @discardableResult
    func setMemoryEntry(_ entry: MemoryEntry, replacing src: String? = nil, for bundleID: String) -> MemoryEdit {
        editProfile(bundleID) { p in
            switch p.setEntry(entry, replacing: src) {
            case .saved: .saved
            case .full: .full
            case .invalid: .invalid
            }
        }
    }

    func removeMemoryEntry(src: String, for bundleID: String) {
        _ = editProfile(bundleID) { $0.removeEntry(src: src); return .saved }
    }

    /// The app's own context choice; nil follows the engine (and the default, which is off).
    @discardableResult
    func setContextOverride(_ override: AppContextOverride?, for bundleID: String) -> MemoryEdit {
        editProfile(bundleID) { $0.context = override; return .saved }
    }

    // MARK: learned rows

    /// The app's learned rows, including those waiting for a second sighting (`LearnedRecord.isUsable` tells them apart).
    func learnedRows(for bundleID: String) async -> [ContextMemory.LearnedRecord] { await translator.learnedRows(for: bundleID) }

    /// "Pin": the learned row becomes a name of the app's profile (a user row, saved in settings.json) and leaves the learned rows.
    /// Not the translator's own pin, which would last until the next request: the memory follows the profile.
    func pinLearned(src: String, for bundleID: String) async -> PinResult {
        let key = MemoryEntry.id(forSource: src)
        let row = await translator.learnedRows(for: bundleID).first { $0.entry.id == key }
        var profiles = settings.appProfiles
        let result = AppProfiles.pin(row?.entry, bundleID: bundleID, in: &profiles)
        if result == .pinned { settings.appProfiles = profiles }
        if result == .pinned || result == .alreadyYours { await translator.removeLearned(src: src, for: bundleID) }
        return result
    }

    func removeLearned(src: String, for bundleID: String) async { await translator.removeLearned(src: src, for: bundleID) }

    /// "Forget learned".
    func forgetLearned(for bundleID: String) async { await translator.forgetLearned(for: bundleID) }

    /// "Start fresh": the transcript and who's who of the app's current document go, and so do its cached lines.
    func startFresh(for bundleID: String) async { await translator.startFresh(for: bundleID) }

    /// The translator told that an app's usable learned rows changed: the counts follow, and the learned-memory file is written.
    func learnedRowsChanged(_ bundleID: String) {
        Task {
            let records = await translator.learnedRows(for: bundleID)
            let counts = LearnedCounts(records)
            if learnedCounts[bundleID] != counts { learnedCounts[bundleID] = counts }
            learnedFile?.changed(bundleID)
        }
    }

    // MARK: the "Sent:" line

    /// The engine sheet's "Sent:" line for `engine` as the sheet has it now (its pending switches too), over the apps' written memory.
    func sentPreview(forEngine engine: EngineConfig) -> SentSummary {
        ContextPreview.engineSummary(engine: engine, profiles: settings.appProfiles, category: { Self.category(ofApp: $0) })
    }

    /// What `engine` could be sent beyond the lines to translate: the lines of the window, the memory written for these apps.
    func contextDisclosure(forEngine engine: EngineConfig) -> EnginePermissions.ContextDisclosure {
        EnginePermissions.disclosure(engine, profiles: settings.appProfiles)
    }

    /// What the engine in effect while this app is in front is sent of this app, as fields (and `text`, the English line). Apple Translation
    /// takes no context. The pairing is the request path's (`ContextRoute`).
    func sentPreview(for bundleID: String) -> SentSummary {
        let pairing = ContextRoute.own(bundleID, in: settings)
        return ContextPreview.summary(engine: pairing.engine, profile: pairing.profile, appName: pairing.profile?.appName ?? bundleID,
                                      category: Self.category(ofApp: bundleID), learnedUsable: learnedCounts[bundleID]?.usable ?? 0)
    }

    /// The other added engines that get this app's memory or context when another app is in front and a lens covers this app's window
    /// ("Also sent to …" under the Memory sheet's "Sent:" line). Empty in the usual case: one engine for everything.
    func otherReceivers(of bundleID: String) -> [EngineConfig] { ContextRoute.otherReceivers(of: bundleID, in: settings) }
}

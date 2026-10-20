import AppKit
import MwoyeoCore

/// What an edit of one app's memory did (`AppModel.setMemoryNote` and the like). The Memory sheet shows `.full` and `.invalid`.
enum MemoryEdit: Equatable {
    /// Written to the profile (and so to settings.json); the first edit of an app without a profile makes it (`AppSettings.ensuringProfile`).
    case saved
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

extension AppSettings {
    /// The pair a new profile of `bundleID` takes: what `effective(frontmost:)` gives while that app is in front (the base choice, as the app
    /// has no profile), and no engine of its own, so it follows the base. Nothing translates differently when the profile is made.
    func newProfilePair(for bundleID: String) -> LanguageChoice {
        let now = effective(frontmost: bundleID)
        return LanguageChoice(source: now.sourceLanguage, target: now.targetLanguage, customEngineID: nil)
    }

    /// The index in `appProfiles` of the profile of `bundleID`, made first when the app has none: `AppProfiles.ensuring`, the one place a
    /// profile is made, with `newProfilePair`. The Memory sheet's first edit, Pin and MCP `set_memory` all come here.
    @discardableResult
    mutating func ensuringProfile(for bundleID: String, appName: String) -> Int {
        AppProfiles.ensuring(bundleID, appName: appName, in: &appProfiles, creatingWith: newProfilePair(for: bundleID))
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

    /// The lens menu's "Remember Languages for <App>": the pair and the engine go into the app's profile, and its note, names, context
    /// choice and reader stay (`AppProfiles.remembering(_:for:appName:in:)`).
    func rememberLanguages(_ choice: LanguageChoice, for bundleID: String, named name: String) {
        settings.appProfiles = AppProfiles.remembering(choice, for: bundleID, appName: name, in: settings.appProfiles)
    }

    /// The lens menu's "Memory for <App>…": Settings on Translation with the app's Memory sheet up. Opening makes no profile; the first
    /// edit does. Without a way to open Settings (`openSettingsAction`) nothing is left waiting for the next time it opens.
    func openMemory(of bundleID: String, named name: String) {
        memoryTarget = MemoryTarget(id: bundleID, name: name)
        if !openSettings(on: .translation) { memoryTarget = nil }
    }

    /// What an app is called when only its bundle ID is known (the sheet opened without a lens, an agent's call): its profile's name, else
    /// the installed app's, else the bundle ID.
    func displayName(ofApp bundleID: String) -> String {
        profile(for: bundleID)?.appName ?? MCPWorld.installedName(bundleID) ?? bundleID
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
/// rows are the translator's, in RAM. Opening the sheet makes no profile; the first edit that changes something does, through the one
/// function every profile is made by (`AppSettings.ensuringProfile`).
extension AppModel {
    /// - `name`: what the app is called, for a profile this edit makes; nil asks `displayName(ofApp:)`.
    private func editProfile(_ bundleID: String, named name: String?, _ body: (inout AppProfile) -> MemoryEdit) -> MemoryEdit {
        var edited = settings
        let i = edited.ensuringProfile(for: bundleID, appName: name ?? displayName(ofApp: bundleID))
        var p = edited.appProfiles[i]
        let result = body(&p)
        // An edit that changed nothing (an empty note over no note) or failed leaves the app as it was, a missing profile still missing.
        if result == .saved, p != edited.appProfiles[i] {
            edited.appProfiles[i] = p
            settings.appProfiles = edited.appProfiles
        }
        return result
    }

    /// The note for the translator. Trimmed and cut at `AppProfile.maxNoteLength`; empty clears it.
    @discardableResult
    func setMemoryNote(_ note: String, for bundleID: String, named name: String? = nil) -> MemoryEdit {
        editProfile(bundleID, named: name) { $0.note = note; return .saved }
    }

    /// Adds a name or term, or replaces the row whose source is `replacing` (the source may change). See `AppProfile.setEntry`.
    @discardableResult
    func setMemoryEntry(_ entry: MemoryEntry, replacing src: String? = nil, for bundleID: String, named name: String? = nil) -> MemoryEdit {
        editProfile(bundleID, named: name) { p in
            switch p.setEntry(entry, replacing: src) {
            case .saved: .saved
            case .full: .full
            case .invalid: .invalid
            }
        }
    }

    func removeMemoryEntry(src: String, for bundleID: String, named name: String? = nil) {
        _ = editProfile(bundleID, named: name) { $0.removeEntry(src: src); return .saved }
    }

    /// The app's own context choice; nil follows the engine (and the default, which is off).
    @discardableResult
    func setContextOverride(_ override: AppContextOverride?, for bundleID: String, named name: String? = nil) -> MemoryEdit {
        editProfile(bundleID, named: name) { $0.context = override; return .saved }
    }

    // MARK: learned rows

    /// The app's learned rows, including those waiting for a second sighting (`LearnedRecord.isUsable` tells them apart).
    func learnedRows(for bundleID: String) async -> [ContextMemory.LearnedRecord] { await translator.learnedRows(for: bundleID) }

    /// "Pin": the learned row becomes a name of the app's profile (a user row, saved in settings.json) and leaves the learned rows.
    /// Not the translator's own pin, which would last until the next request: the memory follows the profile. An app without a profile
    /// gets one (`AppProfiles.pin`), as for any first edit.
    func pinLearned(src: String, for bundleID: String, named name: String? = nil) async -> PinResult {
        let key = MemoryEntry.id(forSource: src)
        let row = await translator.learnedRows(for: bundleID).first { $0.entry.id == key }
        var edited = settings
        let result = AppProfiles.pin(row?.entry, bundleID: bundleID, appName: name ?? displayName(ofApp: bundleID),
                                     creatingWith: edited.newProfilePair(for: bundleID), in: &edited.appProfiles)
        if result == .pinned { settings.appProfiles = edited.appProfiles }
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
        ContextPreview.engineSummary(engine: engine, profiles: settings.appProfiles, category: { Self.category(ofApp: $0) },
                                     glossary: settings.glossaryPairs)
    }

    /// What `engine` could be sent beyond the lines to translate: the lines of the window, the memory written for these apps.
    func contextDisclosure(forEngine engine: EngineConfig) -> EnginePermissions.ContextDisclosure {
        EnginePermissions.disclosure(engine, profiles: settings.appProfiles)
    }

    /// What the engine in effect while this app is in front is sent of this app, as fields (and `text`, the English line). Apple Translation
    /// takes no context. The pairing is the request path's (`ContextRoute`).
    func sentPreview(for bundleID: String, named name: String? = nil) -> SentSummary {
        let pairing = ContextRoute.own(bundleID, in: settings)
        return ContextPreview.summary(engine: pairing.engine, profile: pairing.profile, appName: pairing.profile?.appName ?? name ?? bundleID,
                                      category: Self.category(ofApp: bundleID), learnedUsable: learnedCounts[bundleID]?.usable ?? 0,
                                      glossary: settings.glossaryPairs)
    }

    /// The other added engines that get this app's memory or context when another app is in front and a lens covers this app's window
    /// ("Also sent to …" under the Memory sheet's "Sent:" line). Empty in the usual case: one engine for everything.
    func otherReceivers(of bundleID: String) -> [EngineConfig] { ContextRoute.otherReceivers(of: bundleID, in: settings) }
}

/// The memory block of the lens menu (design names-and-context §3.2, §3.3): the item names, the info line above "Memory for …", and the
/// alert "Forget <App>…" asks. Pure but for the words, so `check-logic` drives it with its own.
enum LensMemoryMenu {
    /// The app's name in an item is cut in the middle here, the info line at the tail at `lineLimit`.
    static let nameLimit = 24
    static let lineLimit = 48

    /// `name` cut in the middle at `nameLimit` characters: the first twelve, "…", the last eleven.
    static func cut(_ name: String) -> String {
        guard name.count > nameLimit else { return name }
        return String(name.prefix(nameLimit / 2)) + "…" + String(name.suffix(nameLimit / 2 - 1))
    }

    /// The words of the info line, in the app's language; the app's name is its own.
    struct Words {
        var names: (Int) -> String
        var allApps: (Int) -> String

        @MainActor static var current: Words {
            Words(names: { String(localized: "Names: \($0)") }, allApps: { String(localized: "all apps \($0)") })
        }
    }

    /// "Names: 5 — <App> 3 · all apps 2": how many names apply to a lens over the app, and whose they are. At most `lineLimit` characters,
    /// cut at the tail; nil while no row applies (the line is left out of the menu). A scope with no names is not mentioned.
    static func infoLine(app: String, appNames: Int, allApps: Int, words: Words) -> String? {
        guard appNames + allApps > 0 else { return nil }
        var scopes: [String] = []
        if appNames > 0 { scopes.append("\(cut(app)) \(appNames)") }
        if allApps > 0 { scopes.append(words.allApps(allApps)) }
        let line = "\(words.names(appNames + allApps)) — \(scopes.joined(separator: " · "))"
        return line.count > lineLimit ? String(line.prefix(lineLimit - 1)) + "…" : line
    }

    /// Forgetting an app that has a memory removes the memory with the languages, so it asks first (§3.2).
    static func forgetAlert(app: String, names: Int) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Forget the languages and the memory for \(app)?")
        alert.informativeText = String(localized: "Its note and \(names) names are removed.")
        alert.addButton(withTitle: String(localized: "Forget")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert
    }

    @MainActor static func askToForget(app: String, names: Int) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return forgetAlert(app: app, names: names).runModal() == .alertFirstButtonReturn
    }
}

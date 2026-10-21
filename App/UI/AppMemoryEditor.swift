import Foundation
import MwoyeoCore
import Observation

/// The profile a sheet is opened on (`AppModel.memoryTarget`): an app (a lens's "Memory for <App>…", whose profile is made by the first
/// edit), a profile of the list (Settings › Translation › Profiles), All apps, or a profile being made by hand (`draft`, stored by its
/// first edit, so pressing Done on an untouched one leaves nothing behind). Design names-and-context §6.3.
struct MemoryTarget: Identifiable {
    enum Kind: Equatable {
        /// `id` is a bundle ID.
        case app
        /// `id` is a profile's id.
        case profile
        /// All apps: the glossary, the amount and (R9) the rules of every chain.
        case allApps
        /// `draft` is the profile being made; `id` is its id.
        case new
    }

    var id: String
    /// What the app is called when it has no profile yet (the lens gave it).
    var name: String? = nil
    var kind: Kind = .app
    var draft: AppProfile? = nil
    /// "New Profile for This Window…": the phrase is focused and selected when Customize opens.
    var focusesPhrase = false
    /// The lens the sheet was opened from: its app and its confirmed window title, for "Add Condition" (design §6.3 a).
    var lensBundleID: String? = nil
    var lensAppName: String? = nil
    var lensTitle: String? = nil
    /// The lens's last line and its translation, for the Script's Test sample (design rewrite-rules §7).
    var lensSource: String? = nil
    var lensTranslation: String? = nil

    static let allApps = MemoryTarget(id: AppProfile.allAppsID, kind: .allApps)
}

/// The words of a profile on its row, its sheet and the menus (design §6.2, §6.3): one owner, so the three say the same. Pure but for the
/// installed apps' names.
enum ProfileWords {
    /// `s` cut in the middle at `limit` characters: the first half, "…", the rest (as `LensMemoryMenu.cut`).
    static func cut(_ s: String, at limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit / 2)) + "…" + String(s.suffix(limit / 2 - 1))
    }

    /// What an app is called: the profile of that bundle ID, else the installed app, else the last part of the bundle ID.
    @MainActor static func appName(_ bundleID: String, in profiles: [AppProfile]) -> String {
        if let p = profiles.first(where: { $0.id == bundleID }) { return p.name }
        if let installed = MCPWorld.installedName(bundleID) { return installed }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    /// Where a profile is used, for its row (priority 2): "In Emulator", "“月涙譚” in Emulator", "Title has “Preprint”", "In Safari +2",
    /// "Picked by hand".
    @MainActor static func whereLine(_ p: AppProfile, in profiles: [AppProfile]) -> String {
        let when = p.when.filter { !$0.isEmpty }
        guard let first = when.first else { return String(localized: "Picked by hand") }
        let more = when.count - 1
        var line: String
        switch (first.app, first.titleContains) {
        case let (app?, phrase?) where !app.isEmpty && !phrase.isEmpty:
            line = String(localized: "“\(phrase)” in \(appName(app, in: profiles))")
        case let (_, phrase?) where !(phrase.isEmpty):
            line = String(localized: "Title has “\(phrase)”")
        default:
            line = String(localized: "In \(appName(first.app ?? p.id, in: profiles))")
        }
        if more > 0 { line += " +\(more)" }
        return line
    }

    /// What a profile keeps, for its row (priority 0): "note · 12 names · 2 rewrites · script"; nil while it keeps nothing.
    static func memoryLine(_ p: AppProfile) -> String? {
        var parts: [String] = []
        if !p.note.isEmpty { parts.append(String(localized: "note")) }
        if !p.entries.isEmpty { parts.append(String(localized: "\(p.entries.count) names")) }
        if let rules = rulesLine(rewrites: p.rewrites.count, script: p.script != nil) { parts.append(rules) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "2 rewrites · script": what a profile's rules hold, in the row and in Customize's summary; nil while it holds none.
    static func rulesLine(rewrites: Int, script: Bool) -> String? {
        var parts: [String] = []
        if rewrites > 0 { parts.append(String(localized: "\(rewrites) rewrites")) }
        if script { parts.append(String(localized: "script")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The tooltip of a row: the note and the names in full (the first dozen).
    static func full(_ p: AppProfile) -> String? {
        guard p.hasMemory else { return nil }
        var lines: [String] = []
        if !p.note.isEmpty { lines.append(p.note) }
        lines += p.entries.prefix(12).map { "\($0.src) → \($0.dst)" }
        if p.entries.count > 12 { lines.append("…") }
        return lines.joined(separator: "\n")
    }

    /// What removing a profile takes with it (the confirmation's message): the note only when there is one, the names only when there are some.
    static func removeDetail(names: Int, hasNote: Bool) -> String? {
        switch (hasNote, names > 0) {
        case (true, true): String(localized: "Its note and \(names) names go with it.")
        case (true, false): String(localized: "Its note goes with it.")
        case (false, true): String(localized: "Its \(names) names go with it.")
        default: nil
        }
    }

    /// "Japanese → Korean".
    static func pair(_ source: String, _ target: String) -> String { "\(Languages.name(source)) → \(Languages.name(target))" }

    /// The amount an override says, in a sentence's middle: "only the line", "names and note", "nearby lines", "conversation 3".
    static func amount(_ c: AppContextOverride?) -> String {
        switch c?.mode {
        case nil, .memory?: String(localized: "names and note")
        case .off?: String(localized: "only the line")
        case .nearby?: String(localized: "nearby lines")
        case .conversation?: String(localized: "conversation \(c?.previousLines ?? 0)")
        }
    }
}

/// The profile menus' words (design §6.4, §6.5): the lens menu's "Profile: …" item and the menu bar's caption say the same thing.
extension ProfileWords {
    /// The first link of the chain of the window `(bundleID, title)`, under a lens's own pin when it has one (`RegionConfig.profilePin`, addendum A1),
    /// else under the menu bar's (`settings.profilePin`): a profile, or All apps.
    static func head(_ settings: AppSettings, bundleID: String?, title: String?, lensPin: String? = nil) -> ChainLink {
        ProfileChain.chain(for: WindowFacts(bundleID: bundleID, title: (title ?? "").isEmpty ? nil : title), profiles: settings.appProfiles,
                           pin: settings.pin(lens: lensPin)).first ?? .allApps
    }

    /// Who holds the pin the caption shows: the lens ("pinned") or the menu bar ("every lens").
    enum PinOwner { case lens, menuBar }

    /// "Profile: Auto" (Auto, All apps first), "Profile: Anime" (Auto, a profile first), "Profile: Anime (pinned)" / "(every lens)" (pinned), "Profile:
    /// All Apps Only". The name is cut in the middle at `limit`.
    static func caption(head: ChainLink, pin: ProfilePin, owner: PinOwner, limit: Int) -> String {
        switch pin {
        case .allAppsOnly:
            return String(localized: "Profile: All Apps Only")
        case .profile(let id) where head.id == id:
            let name = cut(head.name, at: limit)
            return owner == .lens ? String(localized: "Profile: \(name) (pinned)") : String(localized: "Profile: \(name) (every lens)")
        default:
            return head.profile.map { String(localized: "Profile: \(cut($0.name, at: limit))") } ?? String(localized: "Profile: Auto")
        }
    }

    /// Why Auto picks `head` for the window: "the app", "title has “…”", or "nothing matches" (All apps first).
    static func why(head: AppProfile?, bundleID: String?, title: String?) -> String {
        guard let head else { return String(localized: "nothing matches") }
        let matching = head.when.filter { $0.matches(app: bundleID, title: (title ?? "").isEmpty ? nil : title) }
        if let phrase = matching.max(by: { $0.narrowness < $1.narrowness })?.titleContains, !phrase.isEmpty {
            return String(localized: "title has “\(cut(phrase, at: 24))”")
        }
        return String(localized: "the app")
    }
}

extension AppSettings {
    /// The same settings with every lens on Auto: what Auto would pick (the lens menu's dimmed "Auto picks …" line).
    var withoutPin: AppSettings {
        var s = self
        s.profilePin = nil
        return s
    }

    /// What a lens is pinned to: its own pin over the menu bar's (design §1.3, addendum A1).
    func pin(lens: String?) -> ProfilePin {
        var s = self
        if let lens { s.profilePin = lens }
        return s.pin
    }
}

extension AppModel {
    /// Removes the profile with this id, and the pin to it (a pin to no profile is a settings.json issue).
    func removeProfile(id: String) {
        settings.appProfiles.removeAll { $0.id == id }
        if settings.profilePin == id { settings.profilePin = nil }
    }
}

/// The ids profiles made by hand get (design §5.1): a slug of the name, else `profile-<n>`, never one taken.
enum ProfileIDs {
    static func fresh(named name: String, in profiles: [AppProfile]) -> String {
        let taken = Set(profiles.map(\.id))
        let slug = String(name.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(40))
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        if AppProfile.isValidID(slug), !taken.contains(slug) { return slug }
        var n = profiles.count + 1
        while taken.contains("profile-\(n)") { n += 1 }
        return "profile-\(n)"
    }
}

/// What the profile sheet does, apart from drawing it: one profile's note, names and terms, conditions, languages, context choice and
/// learned rows, edited live through `AppModel` (so through settings.json), and read back when the file changes. The sheet only shows
/// this and calls it, and `check-logic` drives the same calls (design names-and-context §6.3).
///
/// The user's part is the profile's (`profiles[].note`, `.entries`, `.context`, …); a row on screen that is not complete yet (a name
/// without its translation, a name another row already has) stays on screen as a draft and is stored when it is. The learned rows are
/// the translator's, in RAM. A profile that is not stored yet (an app's, or one made by hand) is stored by its first edit.
@MainActor
@Observable
final class AppMemoryEditor {
    /// The caps, from Core: settings.json and its validator use the same numbers.
    static let maxNote = AppProfile.maxNoteLength
    static let maxRows = AppProfile.maxEntries
    static let maxEntryNote = MemoryEntry.maxEntryNote
    static let maxName = MemoryEntry.maxName
    static let maxAddressing = MemoryEntry.maxAddressing

    /// One name or term of the sheet.
    struct Row: Identifiable, Equatable {
        let id: UUID
        var src = ""
        var dst = ""
        var kind = EntryKind.term
        var gender: Gender?
        var note = ""
        var reading = ""
        /// How the row is used (design §10). A row nobody chose a mode for follows `defaultApply` until it is stored.
        var apply = EntryApply.hint
        var applyIsDefault = true
        /// Rows of "speaks to … in …"; one with no name yet stays on screen and is left out of the stored entry.
        var addressing: [AddressDraft] = []
        /// What is stored in the profile for this row, read back after the write; nil while the row is a draft.
        var stored: MemoryEntry?
        var problem: Problem?

        init(id: UUID = UUID()) { self.id = id }

        init(_ entry: MemoryEntry, id: UUID = UUID()) {
            self.id = id
            src = entry.src
            dst = entry.dst
            kind = entry.kind
            gender = entry.gender
            note = entry.note
            reading = entry.reading ?? ""
            apply = entry.apply
            applyIsDefault = false
            addressing = entry.addressing.map { AddressDraft(to: $0.to, register: $0.register) }
            stored = entry
        }

        /// What the fields say, cut to the caps the model cuts to; nil while the name or its translation is empty.
        var entry: MemoryEntry? {
            let e = MemoryEntry(src: src, dst: dst, kind: kind, gender: gender, note: note, reading: reading.isEmpty ? nil : reading,
                                addressing: addressing.map { Addressing(to: $0.to, register: $0.register) }.filter { !$0.to.isEmpty },
                                apply: apply)
            return e.src.isEmpty || e.dst.isEmpty ? nil : e
        }

        /// Nothing typed at all: such a draft is dropped when the sheet closes.
        var isBlank: Bool { src.isEmpty && dst.isEmpty && note.isEmpty && reading.isEmpty && addressing.isEmpty }
    }

    /// An addressing row as typed. Core's `Addressing` collapses spaces when it is made, which would eat the space typed in "Mary Ann".
    struct AddressDraft: Equatable, Identifiable {
        let id = UUID()
        var to = ""
        var register = Register.polite
    }

    enum Problem: Equatable {
        /// The name or its translation is empty: nothing is stored yet.
        case incomplete
        /// Another row has this name (two rows with the same name are one name).
        case duplicate
        /// The profile keeps `maxRows` names already.
        case full
    }

    /// The context choice of the profile, as the picker shows it (design §6.3 c): follow All apps, or one of the four amounts.
    enum ContextChoice: Hashable, CaseIterable {
        case follow, off, memory, nearby, conversation
    }

    let target: MemoryTarget
    @ObservationIgnored let model: AppModel

    /// The note as typed (cut at `maxNote`); the model keeps it trimmed.
    private(set) var note = ""
    private(set) var rows: [Row] = []
    /// The rows whose details are open.
    var expanded: Set<UUID> = []
    /// The profile's learned rows, usable and waiting.
    private(set) var learned: [ContextMemory.LearnedRecord] = []
    /// A line under the learned rows: a pin that did not fit.
    private(set) var learnedNotice: String?
    /// The profile keeps a conversation: "Start Fresh" is offered only then (ui-audit 10.2).
    private(set) var keepsConversation = false
    /// "Start fresh" waits for the person's yes inside the sheet.
    var confirmingFresh = false
    /// "Title Contains…": the phrase being typed for a condition that is not stored until it holds a character (an empty condition is invalid).
    var pendingPhrase: String?
    /// The profile is gone (forgotten while the sheet was open): the sheet closes. An app that never had one is not gone: the sheet shows an
    /// empty memory, and the first edit makes the profile.
    private(set) var gone = false
    /// The profile has been stored while this sheet was open.
    private var hadProfile = false
    /// The id of the profile this sheet edits once it is stored or found.
    private var resolvedID: String?
    /// The profile as it will be stored by the first edit: an app's (the bundle ID is its id) or the one made by hand.
    private var draft: AppProfile?

    // Rewrites and Script (design rewrite-rules §7; the methods are in `ScriptEditor.swift`).
    /// A rewrite row being made: it is on screen after the stored ones and is stored once its Find holds a character (an empty Find is a settings.json issue).
    var pendingRewrite: RewriteRow?
    /// What the pure checks and the script service say of the rows and the script, by `RewriteIssue.item` (a row's index, or `RewriteIssue.script`).
    var rewriteIssues: [RewriteIssue] = []
    /// The line the Script's Test works on, and what it made of it.
    var sample = ""
    var testResult: ScriptTestResult?
    /// The side that runs and checks regex rows and scripts: the app's service, or a fake in a gate.
    @ObservationIgnored var service: any RewriteService = ScriptConnection.shared
    @ObservationIgnored var checking: Task<Void, Never>?

    init(target: MemoryTarget, model: AppModel) {
        self.target = target
        self.model = model
        switch target.kind {
        case .allApps:
            break
        case .profile:
            resolvedID = target.id
        case .new:
            draft = target.draft
            resolvedID = target.draft?.id ?? target.id
        case .app:
            if let i = Self.appProfileIndex(target.id, in: model.settings.appProfiles) {
                resolvedID = model.settings.appProfiles[i].id
            } else {
                let pair = model.settings.newProfilePair(for: target.id)
                draft = AppProfile(bundleID: target.id, appName: target.name ?? model.displayName(ofApp: target.id), source: pair.source, target: pair.target)
                resolvedID = target.id
            }
        }
        sample = target.lensSource ?? ""
        reload()
    }

    convenience init(bundleID: String, model: AppModel, appName: String? = nil) {
        self.init(target: MemoryTarget(id: bundleID, name: appName), model: model)
    }

    /// The profile of an app (design §6.4: "with All apps as head, the app, as today"): the one whose id is the bundle ID, else the one
    /// that is only that app, else one with that app and no title. Nil when the app has none.
    static func appProfileIndex(_ bundleID: String, in list: [AppProfile]) -> Int? {
        list.firstIndex { $0.id == bundleID }
            ?? list.firstIndex { $0.when == [ProfileCondition(app: bundleID)] }
            ?? list.firstIndex { p in p.when.contains { $0.app == bundleID && ($0.titleContains ?? "").isEmpty } }
    }

    var isAllApps: Bool { target.kind == .allApps }

    /// How many pairs All apps' glossary holds ("Glossary: n pairs").
    var glossaryCount: Int { model.settings.glossaryPairs.count }

    private var storedIndex: Int? {
        guard let id = resolvedID else { return nil }
        return model.settings.appProfiles.firstIndex { $0.id == id }
    }

    /// The profile as stored, else the one the first edit will store; nil for All apps.
    var profile: AppProfile? { storedIndex.map { model.settings.appProfiles[$0] } ?? draft }

    /// Whether the profile is in settings.json yet.
    var isStored: Bool { storedIndex != nil }

    /// The profile's name, else what the lens called the app.
    var title: String { isAllApps ? String(localized: "All apps") : (profile?.name ?? target.name ?? target.id) }

    /// The bundle ID of the app the profile is for (its first app condition); nil for a preset, a title-only profile and All apps.
    var appBundleID: String? {
        guard let p = profile else { return nil }
        return p.when.compactMap(\.app).first
    }

    /// The key the learned rows, the conversation and "Sent:" are kept under (`MergedChain.learnedKey`): the profile's id.
    var learnedKey: String? { isAllApps ? nil : profile?.id }

    /// The translator's count of this profile's learned rows; it changes when a row is learned, forgotten, removed or pinned.
    var learnedCounts: LearnedCounts? { learnedKey.flatMap { model.learnedCounts[$0] } }

    // MARK: writing

    /// Applies `body` to the profile and stores it: in place when it is stored, appended (with the cap of the file) when it is the draft. An edit
    /// that changes nothing (an empty note over no note) stores nothing, a missing profile staying missing.
    @discardableResult
    func write(_ body: (inout AppProfile) -> MemoryEdit) -> MemoryEdit {
        var edited = model.settings.appProfiles
        if let i = storedIndex {
            var p = edited[i]
            let result = body(&p)
            if result == .saved, p != edited[i] {
                edited[i] = p
                model.settings.appProfiles = edited
            }
            return result
        }
        guard let d = draft else { return .invalid }
        var p = d
        let result = body(&p)
        guard result == .saved else { return result }
        if p != d {
            guard edited.count < AppProfile.maxProfiles else { return .full }
            edited.append(p)
            model.settings.appProfiles = edited
            draft = nil
            hadProfile = true
        } else {
            draft = p
        }
        return result
    }

    // MARK: reading

    /// Everything from the profile, drafts kept: the first read, and after a change of the file.
    private func reload() {
        guard let p = profile else { if !isAllApps { gone = hadProfile }; return }
        if isStored { hadProfile = true }
        if p.note != Self.cleaned(note) { note = p.note }
        let known = Dictionary(rows.compactMap { r in r.stored.map { ($0.id, r) } }, uniquingKeysWith: { a, _ in a })
        var next = p.entries.map { e in Row(e, id: known[e.id]?.id ?? UUID()) }
        next += rows.filter { $0.stored == nil && !$0.isBlank }
        rows = next
        expanded.formIntersection(rows.map(\.id))
    }

    /// The model changed under the sheet (the file was edited, a pin landed): follow it unless it is only what this editor wrote.
    func reconcile() {
        if isAllApps { return }
        guard let p = profile else { gone = hadProfile; return }
        if isStored { hadProfile = true } else if hadProfile { gone = true; return }
        // Order is the screen's (a draft that was stored joins the profile at its end), so compare as sets.
        let mine = rows.compactMap(\.stored).sorted { $0.id < $1.id }
        if mine != p.entries.sorted(by: { $0.id < $1.id }) || p.note != Self.cleaned(note) { reload() }
    }

    /// The note, trimmed and cut as the model keeps it.
    static func cleaned(_ note: String) -> String {
        AppProfile(bundleID: "", appName: "", source: "", target: "", note: note).note
    }

    // MARK: the note

    func setNote(_ text: String) {
        note = String(text.prefix(Self.maxNote))
        write { $0.note = note; return .saved }
    }

    // MARK: names and terms

    var canAddRow: Bool { rows.count < Self.maxRows }

    /// A new empty row, open for typing; nil at the cap.
    @discardableResult
    func addRow() -> UUID? {
        guard canAddRow else { return nil }
        let row = Row()
        rows.append(row)
        return row.id
    }

    func row(_ id: UUID) -> Row? { rows.first { $0.id == id } }

    /// The mode a new row gets (design §10): Both when the engine in effect takes no hints and the name has 2+ characters (so a name written
    /// for Apple works at once; a one-character Han name replaced breaks a word), else Hint.
    func defaultApply(for src: String) -> EntryApply { !takesHints && src.count >= 2 ? .both : .hint }

    /// Changes one row as the person typed, cuts the text to the caps at the field, and stores the row when it is complete.
    func edit(_ id: UUID, _ change: (inout Row) -> Void) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        var r = rows[i]
        let before = r.apply
        change(&r)
        if r.apply != before { r.applyIsDefault = false }
        r.src = String(r.src.prefix(Self.maxName))
        r.dst = String(r.dst.prefix(Self.maxName))
        r.note = String(r.note.prefix(Self.maxEntryNote))
        r.reading = String(r.reading.prefix(Self.maxName))
        r.addressing = Array(r.addressing.prefix(Self.maxAddressing)).map { var a = $0; a.to = String(a.to.prefix(Self.maxName)); return a }
        if r.applyIsDefault { r.apply = defaultApply(for: r.src) }
        rows[i] = r
        commit(i)
    }

    /// Stores `rows[i]`, or takes its stored entry out of the profile while it cannot be stored.
    private func commit(_ i: Int) {
        var r = rows[i]
        guard let entry = r.entry else {
            unstore(&r)
            r.problem = r.isBlank ? nil : .incomplete
            rows[i] = r
            return
        }
        let id = entry.id
        if rows.enumerated().contains(where: { $0.offset != i && $0.element.stored?.id == id }) {
            unstore(&r)
            r.problem = .duplicate
            rows[i] = r
            return
        }
        let old = r.stored?.src
        switch write({ p in
            switch p.setEntry(entry, replacing: old) {
            case .saved: .saved
            case .full: .full
            case .invalid: .invalid
            }
        }) {
        case .saved:
            r.stored = profile?.entries.first { $0.id == id }
            r.problem = nil
        case .full:
            unstore(&r)
            r.problem = .full
        case .invalid:
            unstore(&r)
            r.problem = .incomplete
        }
        rows[i] = r
    }

    private func unstore(_ r: inout Row) {
        if let s = r.stored { write { $0.removeEntry(src: s.src); return .saved } }
        r.stored = nil
    }

    func removeRow(_ id: UUID) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        if let s = rows[i].stored { write { $0.removeEntry(src: s.src); return .saved } }
        rows.remove(at: i)
        expanded.remove(id)
    }

    /// A draft nobody typed in is dropped when the sheet closes.
    func closing() {
        commitPending()
        rows.removeAll { $0.stored == nil && $0.isBlank }
    }

    // MARK: how a row is used (design §10)

    /// "Tell the translator · ≈ 9 tokens", "Swap into the text · free", "Both · ≈ 9 tokens": the cost of `apply` for the row.
    func cost(of apply: EntryApply, row: Row) -> String {
        let tokens = ContextMemory.hintCost(row.entry ?? MemoryEntry(src: row.src.isEmpty ? "…" : row.src, dst: row.dst.isEmpty ? "…" : row.dst, kind: row.kind))
        switch apply {
        case .hint: return String(localized: "Tell the translator · ≈ \(tokens) tokens")
        case .replace: return String(localized: "Swap into the text · free")
        case .both: return String(localized: "Both · ≈ \(tokens) tokens")
        }
    }

    /// With Apple Translation in effect "Both" is the mode a name works with (design §10: "recommended for names").
    var recommendsBoth: Bool { !takesHints }

    /// The rows on Tell that could be swapped into the text as well, while the engine in effect takes no hints (design §6.3's callout).
    var swappableHintRows: [Row] { takesHints ? [] : rows.filter { $0.stored != nil && $0.apply == .hint && $0.src.count >= 2 } }

    /// "Swap Them In": those rows become Both.
    func swapThemIn() {
        for r in swappableHintRows { edit(r.id) { $0.apply = .both } }
    }

    // MARK: the engine in effect

    /// The added engine in effect for the profile (its own, else All apps'); nil is Apple Translation.
    var engineInEffect: EngineConfig? {
        let s = model.settings
        if let choice = profile?.engine {
            switch choice {
            case .apple: return nil
            case .added(let id): if let e = s.engines.first(where: { $0.id == id }) { return e }
            }
        }
        return s.activeEngineConfig
    }

    var engineName: String { engineInEffect?.name ?? String(localized: "Apple Translation") }

    /// The engines of the list, for the sheet's pickers; and what "Same as All apps" means for the engine.
    var engines: [EngineConfig] { model.settings.engines }
    var allAppsEngineName: String { model.settings.activeEngineConfig?.name ?? String(localized: "Apple Translation") }
    var allProfiles: [AppProfile] { model.settings.appProfiles }

    /// The engine takes hint rows: a chat server or Anthropic; DeepL only through its instructions; Apple, a template and a command not at all
    /// (design §4.1, §10).
    var takesHints: Bool {
        guard let e = engineInEffect else { return false }
        if case .deepL = e.kind { return e.allow.deepLInstructions }
        return EngineContextRules.shows(e.kind)
    }

    /// The engine takes context at all (design §6.3 c): a chat server, Anthropic and DeepL.
    var takesContext: Bool { engineInEffect.map { EngineContextRules.shows($0.kind) } ?? false }

    /// The engine learns names from its replies (not DeepL, not Apple).
    var learns: Bool { engineInEffect.map { EngineContextRules.asksLearned($0.kind) && EngineContextRules.shows($0.kind) } ?? false }

    /// The engine denies the lines the profile asks for (design §6.3 c): its sheet says "only the line".
    var linesAskedButDenied: Bool {
        guard let e = engineInEffect, takesContext, !e.allow.lines else { return false }
        return amount.sendsLines
    }

    // MARK: Customize: what the profile sets

    /// The amount the profile (else All apps) sends.
    var amount: ContextAmount {
        if let c = (isAllApps ? model.settings.context : (profile?.context ?? model.settings.context)) { return ContextAmount(c) }
        return .memory
    }

    var contextChoice: ContextChoice {
        let c = isAllApps ? model.settings.context : profile?.context
        switch c?.mode {
        case nil: return isAllApps ? .memory : .follow
        case .off?: return .off
        case .memory?: return .memory
        case .nearby?: return .nearby
        case .conversation?: return .conversation
        }
    }

    /// How many earlier lines "Conversation" sends.
    var earlierLines: Int { (isAllApps ? model.settings.context : profile?.context)?.previousLines ?? AppContextOverride.defaultPreviousLines }

    /// "Same as All apps (names and note)": what a profile that sets nothing gets.
    var allAppsWords: String { ProfileWords.amount(model.settings.context) }

    func setContext(_ choice: ContextChoice) {
        let lines = earlierLines
        let value: AppContextOverride?
        switch choice {
        case .follow: value = nil
        case .off: value = AppContextOverride(mode: .off)
        case .memory: value = isAllApps ? nil : AppContextOverride(mode: .memory)
        case .nearby: value = AppContextOverride(mode: .nearby)
        case .conversation: value = AppContextOverride(mode: .conversation, previousLines: lines)
        }
        if isAllApps {
            model.settings.context = value
        } else {
            write { $0.context = value; return .saved }
        }
    }

    func setEarlierLines(_ n: Int) {
        guard contextChoice == .conversation else { return }
        let value = AppContextOverride(mode: .conversation, previousLines: n)
        if isAllApps { model.settings.context = value } else { write { $0.context = value; return .saved } }
    }

    /// "Learn names and terms": the profile's own switch (nil follows All apps').
    var learnsNames: Bool { isAllApps ? model.settings.useLearned : (profile?.useLearned ?? model.settings.useLearned) }

    func setLearnsNames(_ on: Bool) {
        if isAllApps { model.settings.useLearned = on } else { write { $0.useLearned = on == model.settings.useLearned ? nil : on; return .saved } }
    }

    // MARK: Customize: when it is used, languages

    func setName(_ text: String) {
        let name = String(text.prefix(AppProfile.maxNameLength))
        write { $0.name = name; return .saved }
    }

    func setSource(_ s: String) { write { $0.source = s; return .saved } }
    func setTarget(_ s: String) { write { $0.target = s; return .saved } }

    /// The engine popup: nil follows All apps; `.apple` is Apple Translation; `.added` an engine of the list.
    func setEngine(_ choice: ProfileEngine?) { write { $0.engine = choice; return .saved } }

    func setReader(_ choice: ParagraphReader?) { write { $0.paragraphReader = choice; return .saved } }

    var canAddCondition: Bool { (profile?.when.count ?? 0) < AppProfile.maxConditions }

    func addCondition(_ c: ProfileCondition) {
        guard canAddCondition else { return }
        write { p in
            guard !p.when.contains(c) else { return .saved }
            p.when.append(c)
            return .saved
        }
    }

    func removeCondition(at i: Int) {
        write { p in
            guard p.when.indices.contains(i) else { return .saved }
            p.when.remove(at: i)
            return .saved
        }
    }

    /// The phrase of a title condition as typed (cut at `ProfileCondition.maxTitleLength`); an emptied phrase of a condition with no app removes it.
    func setPhrase(_ text: String, at i: Int) {
        let phrase = String(text.prefix(ProfileCondition.maxTitleLength))
        write { p in
            guard p.when.indices.contains(i) else { return .saved }
            // A profile named by its phrase (a window's title) keeps following it while the person edits the phrase.
            if let old = p.when[i].titleContains, !old.isEmpty, p.name == ContextText.truncated(old, toCharacters: AppProfile.maxNameLength) {
                p.name = phrase.isEmpty ? p.name : phrase
            }
            p.when[i].titleContains = phrase.isEmpty ? nil : phrase
            if p.when[i].isEmpty { p.when.remove(at: i) }
            return .saved
        }
    }

    /// The pending phrase becomes a condition once it holds a character; an empty one is dropped.
    func commitPending() {
        guard let text = pendingPhrase else { return }
        pendingPhrase = nil
        let phrase = String(text.prefix(ProfileCondition.maxTitleLength))
        if !phrase.isEmpty { addCondition(ProfileCondition(titleContains: phrase)) }
    }

    // MARK: header and Customize's summary (design §6.3)

    /// "Used when the title has “月涙譚” in Emulator", "Used in Safari", "Used when you pick it", "Used everywhere else".
    var usedWords: String {
        guard let p = profile else { return String(localized: "Used everywhere else") }
        let when = p.when.filter { !$0.isEmpty }
        guard let first = when.first else { return String(localized: "Used when you pick it") }
        let profiles = model.settings.appProfiles
        var line: String
        switch (first.app, first.titleContains) {
        case let (app?, phrase?) where !app.isEmpty && !phrase.isEmpty:
            line = String(localized: "Used when the title has “\(phrase)” in \(ProfileWords.appName(app, in: profiles))")
        case let (_, phrase?) where !phrase.isEmpty:
            line = String(localized: "Used when the title has “\(phrase)”")
        default:
            line = String(localized: "Used in \(ProfileWords.appName(first.app ?? p.id, in: profiles))")
        }
        if when.count > 1 { line += " +\(when.count - 1)" }
        return line
    }

    /// "Used in Safari · Japanese → Korean · Apple Translation".
    var captionLine: String {
        guard let p = profile else {
            let s = model.settings
            return "\(usedWords) · \(ProfileWords.pair(s.sourceLanguage, s.targetLanguage)) · \(engineName)"
        }
        return "\(usedWords) · \(ProfileWords.pair(p.source, p.target)) · \(engineName)"
    }

    /// What Customize says beside its label: what differs from All apps ("Local Qwen · conversation 3 · learns · 2 rewrites · script"), else what
    /// it holds. One line, tail cut by the view; also the value of its accessibility element.
    var customizeSummary: String {
        var parts: [String] = []
        if let p = profile {
            if p.engine != nil, p.engine?.fileValue != model.settings.customEngineID?.uuidString { parts.append(engineName) }
            if let c = p.context { parts.append(ProfileWords.amount(c)) }
            if let learn = p.useLearned, learn != model.settings.useLearned { parts.append(learn ? String(localized: "learns names") : String(localized: "does not learn")) }
            if p.paragraphReader != nil { parts.append(p.paragraphReader?.title ?? "") }
            if p.when.count > 1 { parts.append(String(localized: "\(p.when.count) conditions")) }
        } else if isAllApps {
            if model.settings.context != nil { parts.append(ProfileWords.amount(model.settings.context)) }
            if model.settings.useLearned { parts.append(String(localized: "learns names")) }
        }
        if let rules = ProfileWords.rulesLine(rewrites: rewrites.count, script: script != nil) { parts.append(rules) }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return isAllApps ? String(localized: "Context") : String(localized: "When, languages, context, rewrites")
    }

    /// Customize starts open for a profile that uses more than one app condition's worth, or that is being made by hand (design §6.3); the
    /// state is not kept.
    var customizeStartsOpen: Bool {
        guard let p = profile else { return target.kind == .new }
        return Self.startsOpen(p, kind: target.kind)
    }

    static func startsOpen(_ p: AppProfile, kind: MemoryTarget.Kind) -> Bool {
        if kind == .new { return true }
        let oneApp = p.when.count == 1 && (p.when[0].titleContains ?? "").isEmpty
        return !oneApp || p.engine != nil || p.context != nil || p.useLearned != nil || p.paragraphReader != nil || !p.rewrites.isEmpty || p.script != nil
    }

    // MARK: what is sent

    /// The engine sheet's "Sent:" line for this profile's chain, as the request path would send it. Nil for All apps and a profile with
    /// Apple Translation in effect (it takes no context, the sheet says nothing).
    var sent: SentSummary? {
        guard let p = profile, engineInEffect != nil else { return nil }
        let s = model.settings
        let chain = ProfileChain.merge([.profile(p), .allApps], base: s.chainBase(bundleID: p.bundleID))
        let category = appBundleID.flatMap { AppModel.category(ofApp: $0) }
        return ContextPreview.summary(engine: engineInEffect, chain: chain, appName: p.name, category: category,
                                      learnedUsable: model.learnedCounts[p.id]?.usable ?? 0)
    }

    // MARK: learned rows

    func refreshLearned() async {
        guard let key = learnedKey else { learned = []; keepsConversation = false; return }
        learned = await model.learnedRows(for: key)
            .sorted { ($0.isUsable ? 0 : 1, $0.entry.src.lowercased()) < ($1.isUsable ? 0 : 1, $1.entry.src.lowercased()) }
        let requests = await model.translator.contextUsage(for: key).requests
        keepsConversation = amount.isConversation && requests > 0
    }

    /// Pin: the learned row becomes a row of the profile (a user row from then on, in settings.json).
    func pin(_ record: ContextMemory.LearnedRecord) async {
        learnedNotice = nil
        guard let key = learnedKey else { return }
        var row = await model.learnedRows(for: key).first { $0.entry.id == record.entry.id }?.entry
        if var r = row { r.apply = defaultApply(for: r.src); row = r }
        var result = PinResult.gone
        if let row {
            if profile?.entries.contains(where: { $0.id == row.id }) == true {
                result = .alreadyYours
            } else {
                switch write({ p in
                    switch p.setEntry(row) { case .saved: .saved; case .full: .full; case .invalid: .invalid }
                }) {
                case .saved: result = .pinned
                case .full: result = .full
                case .invalid: result = .gone
                }
            }
        }
        if result == .pinned || result == .alreadyYours { await model.removeLearned(src: record.entry.src, for: key) }
        if result == .full { learnedNotice = String(localized: "This profile keeps \(Self.maxRows) names. Remove one to pin this.") }
        reconcile()
        await refreshLearned()
    }

    func removeLearned(_ record: ContextMemory.LearnedRecord) async {
        learnedNotice = nil
        guard let key = learnedKey else { return }
        await model.removeLearned(src: record.entry.src, for: key)
        await refreshLearned()
    }

    /// Forget all: every learned row of the profile. The names and note the person wrote stay.
    func forgetLearned() async {
        learnedNotice = nil
        guard let key = learnedKey else { return }
        await model.forgetLearned(for: key)
        await refreshLearned()
    }

    /// Start fresh, after the person said yes: the conversation kept for the profile goes. The note, the names and the learned rows stay.
    func startFresh() async {
        confirmingFresh = false
        guard let key = learnedKey else { return }
        await model.startFresh(for: key)
        await refreshLearned()
    }
}

extension ContextAmount {
    /// The amount keeps earlier lines.
    var isConversation: Bool {
        if case .conversation = self { return true }
        return false
    }
}

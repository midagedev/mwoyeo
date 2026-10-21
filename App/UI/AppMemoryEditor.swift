import Foundation
import MwoyeoCore
import Observation

/// What the Memory sheet does, apart from drawing it: one app's note, names and terms, context choice and learned rows, edited live
/// through `AppModel` (so through settings.json), and read back when the file changes. The sheet only shows this and calls it, and
/// `check-logic` drives the same calls.
///
/// The user's part is the profile's (`appProfiles[].note`, `.entries`, `.context`); a row on screen that is not complete yet (a name
/// without its translation, a name another row already has) stays on screen as a draft and is stored when it is. The learned rows are
/// the translator's, in RAM.
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
            addressing = entry.addressing.map { AddressDraft(to: $0.to, register: $0.register) }
            stored = entry
        }

        /// What the fields say, cut to the caps the model cuts to; nil while the name or its translation is empty.
        var entry: MemoryEntry? {
            let e = MemoryEntry(src: src, dst: dst, kind: kind, gender: gender, note: note, reading: reading.isEmpty ? nil : reading,
                                addressing: addressing.map { Addressing(to: $0.to, register: $0.register) }.filter { !$0.to.isEmpty })
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

    /// The context choice of the app, as the picker shows it.
    enum ContextChoice: Hashable, CaseIterable {
        case follow, off, nearby, conversation
    }

    let bundleID: String
    @ObservationIgnored private let model: AppModel

    /// The note as typed (cut at `maxNote`); the model keeps it trimmed.
    private(set) var note = ""
    private(set) var rows: [Row] = []
    /// The rows whose details are open.
    var expanded: Set<UUID> = []
    /// The app's learned rows, usable and waiting.
    private(set) var learned: [ContextMemory.LearnedRecord] = []
    /// A line under the learned rows: a pin that did not fit.
    private(set) var learnedNotice: String?
    /// "Start fresh" waits for the person's yes inside the sheet.
    var confirmingFresh = false
    /// The profile is gone (forgotten while the sheet was open): the sheet closes. An app that never had one is not gone: the sheet shows an
    /// empty memory, and the first edit makes the profile.
    private(set) var gone = false
    /// The app has had a profile while this sheet was open.
    private var hadProfile = false
    /// What the app is called: its profile's name, else the one the lens gave (the name a profile made by this sheet takes).
    private let givenName: String?

    init(bundleID: String, model: AppModel, appName: String? = nil) {
        self.bundleID = bundleID
        self.model = model
        self.givenName = appName
        reload()
    }

    var profile: AppProfile? { model.profile(for: bundleID) }

    var appName: String { profile?.appName ?? givenName ?? bundleID }

    /// The translator's count of this app's learned rows; it changes when a row is learned, forgotten, removed or pinned.
    var learnedCounts: LearnedCounts? { model.learnedCounts[bundleID] }

    // MARK: reading

    /// Everything from the profile, drafts kept: the first read, and after a change of the file.
    private func reload() {
        guard let p = profile else { gone = hadProfile; return }
        hadProfile = true
        if p.note != Self.cleaned(note) { note = p.note }
        let known = Dictionary(rows.compactMap { r in r.stored.map { ($0.id, r) } }, uniquingKeysWith: { a, _ in a })
        var next = p.entries.map { e in Row(e, id: known[e.id]?.id ?? UUID()) }
        next += rows.filter { $0.stored == nil && !$0.isBlank }
        rows = next
        expanded.formIntersection(rows.map(\.id))
    }

    /// The model changed under the sheet (the file was edited, a pin landed): follow it unless it is only what this editor wrote.
    func reconcile() {
        guard let p = profile else { gone = hadProfile; return }
        hadProfile = true
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
        _ = model.setMemoryNote(note, for: bundleID, named: appName)
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

    /// Changes one row as the person typed, cuts the text to the caps at the field, and stores the row when it is complete.
    func edit(_ id: UUID, _ change: (inout Row) -> Void) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        var r = rows[i]
        change(&r)
        r.src = String(r.src.prefix(Self.maxName))
        r.dst = String(r.dst.prefix(Self.maxName))
        r.note = String(r.note.prefix(Self.maxEntryNote))
        r.reading = String(r.reading.prefix(Self.maxName))
        r.addressing = Array(r.addressing.prefix(Self.maxAddressing)).map { var a = $0; a.to = String(a.to.prefix(Self.maxName)); return a }
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
        switch model.setMemoryEntry(entry, replacing: r.stored?.src, for: bundleID, named: appName) {
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
        if let s = r.stored { model.removeMemoryEntry(src: s.src, for: bundleID, named: appName) }
        r.stored = nil
    }

    func removeRow(_ id: UUID) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        if let s = rows[i].stored { model.removeMemoryEntry(src: s.src, for: bundleID, named: appName) }
        rows.remove(at: i)
        expanded.remove(id)
    }

    /// A draft nobody typed in is dropped when the sheet closes.
    func closing() { rows.removeAll { $0.stored == nil && $0.isBlank } }

    // MARK: context for this app

    var contextChoice: ContextChoice {
        switch profile?.context?.mode {
        case nil: .follow
        case .off?: .off
        case .memory?: .follow   // R4: a choice of its own; this sheet has none for "names and note only"
        case .nearby?: .nearby
        case .conversation?: .conversation
        }
    }

    /// How many earlier lines "Conversation" sends.
    var earlierLines: Int { profile?.context?.previousLines ?? AppContextOverride.defaultPreviousLines }

    func setContext(_ choice: ContextChoice) {
        let lines = earlierLines
        switch choice {
        case .follow: _ = model.setContextOverride(nil, for: bundleID, named: appName)
        case .off: _ = model.setContextOverride(AppContextOverride(mode: .off), for: bundleID, named: appName)
        case .nearby: _ = model.setContextOverride(AppContextOverride(mode: .nearby), for: bundleID, named: appName)
        case .conversation: _ = model.setContextOverride(AppContextOverride(mode: .conversation, previousLines: lines), for: bundleID, named: appName)
        }
    }

    func setEarlierLines(_ n: Int) {
        guard contextChoice == .conversation else { return }
        _ = model.setContextOverride(AppContextOverride(mode: .conversation, previousLines: n), for: bundleID, named: appName)
    }

    // MARK: what is sent

    var sent: SentSummary { model.sentPreview(for: bundleID, named: appName) }

    /// The other added engines that get this app's memory when another app is in front.
    var otherReceivers: [EngineConfig] { model.otherReceivers(of: bundleID) }

    // MARK: learned rows

    func refreshLearned() async {
        learned = await model.learnedRows(for: bundleID)
            .sorted { ($0.isUsable ? 0 : 1, $0.entry.src.lowercased()) < ($1.isUsable ? 0 : 1, $1.entry.src.lowercased()) }
    }

    /// Pin: the learned row becomes a row of the profile (a user row from then on, in settings.json).
    func pin(_ record: ContextMemory.LearnedRecord) async {
        learnedNotice = nil
        let result = await model.pinLearned(src: record.entry.src, for: bundleID, named: appName)
        if result == .full { learnedNotice = String(localized: "This app keeps \(Self.maxRows) names. Remove one to pin this.") }
        reconcile()
        await refreshLearned()
    }

    func removeLearned(_ record: ContextMemory.LearnedRecord) async {
        learnedNotice = nil
        await model.removeLearned(src: record.entry.src, for: bundleID)
        await refreshLearned()
    }

    /// Forget learned: every learned row of the app. The names and note the person wrote stay.
    func forgetLearned() async {
        learnedNotice = nil
        await model.forgetLearned(for: bundleID)
        await refreshLearned()
    }

    /// Start fresh, after the person said yes: the conversation kept for the app goes. The note, the names and the learned rows stay.
    func startFresh() async {
        confirmingFresh = false
        await model.startFresh(for: bundleID)
    }
}

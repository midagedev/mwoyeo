import Foundation

/// How much surrounding text one app's translations carry (design §3, §9). Written in `settings.json` as
/// `{"mode": …, "previousLines": 0-8}`; `ContextOptions.resolved(base:override:)` lays it over the global choice.
public struct AppContextOverride: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// No context: today's request, byte for byte.
        case off
        /// The lines around the text on screen, and no earlier lines.
        case nearby
        /// The nearby lines and the last `previousLines` lines read before.
        case conversation
    }

    public static let maxPreviousLines = 8
    /// What a `context` object without `previousLines` means. Provisional until the bench table (design §5) sets it.
    public static let defaultPreviousLines = 3

    public var mode: Mode
    /// How many earlier lines go along in `conversation` mode, 0 to `maxPreviousLines`. Code that sets a value out of range
    /// gets the nearest end; a file that holds one gets `defaultPreviousLines` (see `init(from:)`).
    public var previousLines: Int { didSet { previousLines = Self.clamped(previousLines) } }

    public init(mode: Mode, previousLines: Int = AppContextOverride.defaultPreviousLines) {
        self.mode = mode
        self.previousLines = Self.clamped(previousLines)
    }

    static func clamped(_ n: Int) -> Int { min(Self.maxPreviousLines, max(0, n)) }

    // Read from a file, one rule shared with the settings-file check (a `previousLines` it reports as "ignored" is the
    // default): a `mode` that is missing or unknown (saved by a newer version) throws, and `AppProfile` reads that as no
    // override; a `previousLines` that is missing, not a whole number or outside 0...maxPreviousLines is the default. The
    // clamp is only for values set in code (`init`, a later set).
    enum CodingKeys: String, CodingKey, CaseIterable { case mode, previousLines }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lines = ((try? c.decodeIfPresent(Int.self, forKey: .previousLines)) ?? nil).flatMap { (0...Self.maxPreviousLines).contains($0) ? $0 : nil }
        self.init(mode: try c.decode(Mode.self, forKey: .mode), previousLines: lines ?? Self.defaultPreviousLines)
    }
}

/// Languages (and the added engine) remembered for one app. While that app is in front they replace the base choice.
public struct AppProfile: Codable, Equatable, Identifiable, Sendable {
    /// The caps of what an app profile keeps (design §10): `settings.json` and its validator use the same numbers.
    public static let maxEntries = 40
    public static let maxNoteLength = 500

    public var bundleID: String
    public var appName: String
    public var source: String
    public var target: String
    /// The added engine to use; nil keeps the base choice.
    public var customEngineID: UUID?
    /// How this app's text is cut into paragraphs; nil inherits the global default.
    public var paragraphReader: ParagraphReader?
    /// The note for the translator (register, setting, audience), at most `maxNoteLength` characters. Empty for none.
    public var note: String { didSet { note = ContextMemory.cleanNote(note) } }
    /// The names and terms the user wrote or pinned, at most `maxEntries`, all `origin == .user`. Learned entries stay in RAM.
    public var entries: [MemoryEntry] { didSet { entries = Self.cleanEntries(entries) } }
    /// How much context this app's translations carry; nil inherits the global choice, which is Off.
    public var context: AppContextOverride?

    public var id: String { bundleID }

    /// The part of the profile that "Remember Languages" is about: the pair and the added engine.
    public var languages: LanguageChoice { LanguageChoice(source: source, target: target, customEngineID: customEngineID) }

    public init(bundleID: String, appName: String, source: String, target: String, customEngineID: UUID? = nil,
                paragraphReader: ParagraphReader? = nil, note: String = "", entries: [MemoryEntry] = [],
                context: AppContextOverride? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.source = source
        self.target = target
        self.customEngineID = customEngineID
        self.paragraphReader = paragraphReader
        self.note = ContextMemory.cleanNote(note)
        self.entries = Self.cleanEntries(entries)
        self.context = context
    }

    /// User entries only, one per `src` (the first wins), at most `maxEntries`.
    static func cleanEntries(_ list: [MemoryEntry]) -> [MemoryEntry] {
        var seen = Set<String>()
        var out: [MemoryEntry] = []
        for var e in list where e.origin == .user && !e.src.isEmpty && !e.dst.isEmpty && seen.insert(e.id).inserted {
            e.origin = .user
            out.append(e)
            if out.count == maxEntries { break }
        }
        return out
    }

    /// The canonical text of the note and the entries, for the translation-memory namespace (`ContextMemory.memoryFingerprint`).
    public var memoryFingerprint: String { ContextMemory(profile: self).memoryFingerprint }

    /// The user wrote a note or at least one name for this app. That is the opt-in of "memory only" (`ContextOptions.memoryOnly`).
    public var hasMemory: Bool { !note.isEmpty || !entries.isEmpty }

    public enum EntryResult: Equatable, Sendable { case saved, full, invalid }

    /// Adds `entry` as a user row, or replaces the row whose `src` is `replacing` (so a row can change its `src`), or the row with
    /// the same `src`. Any other row with the entry's `src` goes: the latest edit wins. `.full` at `maxEntries` rows (nothing
    /// changes), `.invalid` when `src` or `dst` is empty after cleaning (nothing changes).
    @discardableResult
    public mutating func setEntry(_ entry: MemoryEntry, replacing src: String? = nil) -> EntryResult {
        var e = entry
        e.origin = .user
        guard !e.src.isEmpty, !e.dst.isEmpty else { return .invalid }
        let target = src.map(ContextText.foldedKey) ?? e.id
        var list = entries
        if let i = list.firstIndex(where: { $0.id == target }) {
            list[i] = e
            list = list.enumerated().filter { $0.offset == i || $0.element.id != e.id }.map(\.element)
        } else if let i = list.firstIndex(where: { $0.id == e.id }) {
            list[i] = e
        } else {
            guard list.count < Self.maxEntries else { return .full }
            list.append(e)
        }
        entries = list
        return .saved
    }

    public mutating func removeEntry(src: String) {
        let key = ContextText.foldedKey(src)
        entries.removeAll { $0.id == key }
    }

    // Decode leniently so a profile saved by another version never takes the others with it.
    enum CodingKeys: String, CodingKey, CaseIterable { case bundleID, appName, source, target, customEngineID, paragraphReader, note, entries, context }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try c.decode(String.self, forKey: .bundleID)
        appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? bundleID
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "auto"
        target = try c.decodeIfPresent(String.self, forKey: .target) ?? "en"
        customEngineID = try? c.decodeIfPresent(UUID.self, forKey: .customEngineID)
        // A reader this build does not know (saved by a newer version) inherits, like a profile without one.
        paragraphReader = (try? c.decodeIfPresent(ParagraphReader.self, forKey: .paragraphReader)) ?? nil
        // A profile without them (every profile saved before the memory) decodes with an empty note and no entries;
        // one bad entry is skipped, not the profile; an entry that says it is learned is not ours to keep.
        note = ContextMemory.cleanNote((try? c.decodeIfPresent(String.self, forKey: .note)) ?? "")
        entries = Self.cleanEntries(((try? c.decodeIfPresent(LossyArray<MemoryEntry>.self, forKey: .entries)) ?? nil)?.elements ?? [])
        // A context this build cannot read (no mode, a mode it does not know) inherits, like a profile without one.
        context = (try? c.decodeIfPresent(AppContextOverride.self, forKey: .context)) ?? nil
    }

    // Written only when set, so a profile without a memory is saved exactly as before.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bundleID, forKey: .bundleID)
        try c.encode(appName, forKey: .appName)
        try c.encode(source, forKey: .source)
        try c.encode(target, forKey: .target)
        try c.encodeIfPresent(customEngineID, forKey: .customEngineID)
        try c.encodeIfPresent(paragraphReader, forKey: .paragraphReader)
        if !note.isEmpty { try c.encode(note, forKey: .note) }
        if !entries.isEmpty { try c.encode(entries, forKey: .entries) }
        try c.encodeIfPresent(context, forKey: .context)
    }
}

/// The part of the settings an app profile can override.
public struct LanguageChoice: Equatable, Sendable {
    public var source: String
    public var target: String
    public var customEngineID: UUID?

    public init(source: String, target: String, customEngineID: UUID?) {
        self.source = source
        self.target = target
        self.customEngineID = customEngineID
    }
}

/// What pinning a learned row did (`pin`).
public enum PinResult: Equatable, Sendable {
    /// The row is a user row of the app's profile now (written to settings.json when the caller saves them).
    case pinned
    /// The app already had a user row for this source: the user's word stays, nothing changed.
    case alreadyYours
    /// The profile has `AppProfile.maxEntries` rows.
    case full
    /// The learned row is not there any more (forgotten, removed or already pinned).
    case gone
}

public enum AppProfiles {
    public static func profile(for bundleID: String?, in profiles: [AppProfile]) -> AppProfile? {
        guard let bundleID else { return nil }
        return profiles.first { $0.bundleID == bundleID }
    }

    /// What translates while `frontmost` is in front: the app's profile laid over `base`, or `base` itself when the app has
    /// none. A profile engine that is no longer among `engines` keeps the base choice.
    public static func effective(base: LanguageChoice, profiles: [AppProfile], frontmost: String?, engines: Set<UUID>) -> LanguageChoice {
        guard let p = profile(for: frontmost, in: profiles) else { return base }
        var out = LanguageChoice(source: p.source, target: p.target, customEngineID: base.customEngineID)
        if let id = p.customEngineID, engines.contains(id) { out.customEngineID = id }
        return out
    }

    /// The paragraph reader for the app `bundleID`: its profile's choice, else `base`.
    public static func paragraphReader(base: ParagraphReader, profiles: [AppProfile], app bundleID: String?) -> ParagraphReader {
        profile(for: bundleID, in: profiles)?.paragraphReader ?? base
    }

    /// Makes `learned` a user row of the profile of `bundleID`: it is added to `entries` with `origin == .user`, so it is saved with
    /// the profile and the translator's memory follows it. The caller then drops the learned row (`ContextMemory.removeLearned`).
    /// An app without a profile gets one first (`ensuring`, with `pair`), but only for a row that is still there.
    public static func pin(_ learned: MemoryEntry?, bundleID: String, appName: String, creatingWith pair: LanguageChoice,
                           in profiles: inout [AppProfile]) -> PinResult {
        guard let learned else { return .gone }
        let i = ensuring(bundleID, appName: appName, in: &profiles, creatingWith: pair)
        if profiles[i].entries.contains(where: { $0.id == learned.id }) { return .alreadyYours }
        switch profiles[i].setEntry(learned) {
        case .saved: return .pinned
        case .full: return .full
        case .invalid: return .gone
        }
    }

    /// `profiles` with `profile` in the place of the one for the same app (added when there is none). It replaces the whole profile: to
    /// remember a pair and keep the rest, use `remembering(_:for:appName:in:)`.
    public static func remembering(_ profile: AppProfile, in profiles: [AppProfile]) -> [AppProfile] {
        var out = profiles
        let i = ensuring(profile.bundleID, appName: profile.appName, in: &out, creatingWith: profile.languages)
        out[i] = profile
        return out
    }

    /// The index of the profile of `bundleID` in `profiles`, added first when the app has none. The one place a profile is made: the
    /// first edit of an app's memory, MCP `set_memory`, Pin and "Remember Languages" all come here. A new profile takes `pair`: for an
    /// edit that is what `AppSettings.effective(frontmost:)` gives while the app is in front (the base choice, as the app has no profile
    /// yet), so nothing translates differently at that moment; for "Remember Languages" it is the pair being remembered.
    @discardableResult
    public static func ensuring(_ bundleID: String, appName: String, in profiles: inout [AppProfile], creatingWith pair: LanguageChoice) -> Int {
        if let i = profiles.firstIndex(where: { $0.bundleID == bundleID }) { return i }
        profiles.append(AppProfile(bundleID: bundleID, appName: appName, source: pair.source, target: pair.target, customEngineID: pair.customEngineID))
        return profiles.count - 1
    }

    /// `profiles` with the pair and the engine of `choice` remembered for the app. A profile the app has keeps everything else it holds
    /// (name, note, names, context choice, reader); an app without one gets a new profile.
    public static func remembering(_ choice: LanguageChoice, for bundleID: String, appName: String, in profiles: [AppProfile]) -> [AppProfile] {
        var out = profiles
        let i = ensuring(bundleID, appName: appName, in: &out, creatingWith: choice)
        out[i].source = choice.source
        out[i].target = choice.target
        out[i].customEngineID = choice.customEngineID
        return out
    }
}

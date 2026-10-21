import Foundation

/// One condition of a profile's "Used when" (design §1.1, §1.2, §5.1, §5.3): the app (a bundle ID), the window title (a
/// phrase the confirmed title must contain), or both. A condition with neither is invalid (§5.3) and matches nothing.
public struct ProfileCondition: Codable, Equatable, Sendable {
    /// The cap on the title phrase (§5.3).
    public static let maxTitleLength = 60

    /// The bundle ID of the app whose window the profile is for.
    public var app: String?
    /// The phrase the confirmed window title must contain (`ContextText.occurs`, folded: case, accents and width ignored).
    public var titleContains: String?

    public init(app: String? = nil, titleContains: String? = nil) {
        self.app = app
        self.titleContains = titleContains
    }

    /// A condition with neither an app nor a phrase: invalid (§5.3), and it matches nothing.
    public var isEmpty: Bool { (app ?? "").isEmpty && (titleContains ?? "").isEmpty }

    /// How narrow the condition is (design §1.3): app and title 3, title 2, app 1, none 0.
    public var narrowness: Int {
        let hasApp = !(app ?? "").isEmpty
        let hasTitle = !(titleContains ?? "").isEmpty
        if hasApp && hasTitle { return 3 }
        if hasTitle { return 2 }
        if hasApp { return 1 }
        return 0
    }

    /// The length of the title phrase: the tie-break between two conditions of the same narrowness (design §1.3, "a tie
    /// goes to the longer phrase").
    public var phraseLength: Int { titleContains?.count ?? 0 }

    /// Whether the condition matches the window under the lens.
    ///
    /// The app matches when the window's owner has this bundle ID. The title matches when the *confirmed* title contains
    /// the phrase; until a new window's title is confirmed (≈ 1 s) only app conditions match (design §1.2).
    public func matches(app bundleID: String?, title: String?) -> Bool {
        if isEmpty { return false }
        if let app, !app.isEmpty, app != bundleID { return false }
        if let phrase = titleContains, !phrase.isEmpty {
            guard let title, !title.isEmpty, ContextText.occurs(phrase, in: title) else { return false }
        }
        return true
    }

    // One flat object, `app` and `titleContains` left out when they are not there (§5.1's `when`).
    enum CodingKeys: String, CodingKey, CaseIterable { case app, titleContains }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(app: (try? c.decodeIfPresent(String.self, forKey: .app)) ?? nil,
                  titleContains: (try? c.decodeIfPresent(String.self, forKey: .titleContains)) ?? nil)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(app, forKey: .app)
        try c.encodeIfPresent(titleContains, forKey: .titleContains)
    }
}

/// The engine a profile uses (design §5.1): an added engine's id, or `"apple"` (Apple's own translation, a new value of
/// this field). Absent keeps All apps' choice.
public enum ProfileEngine: Equatable, Sendable {
    /// An added engine (one of the user's own).
    case added(UUID)
    /// Apple's translation ("apple" in the file).
    case apple

    /// The added engine's id; nil for Apple.
    public var id: UUID? {
        if case .added(let uuid) = self { return uuid }
        return nil
    }

    /// What the file holds: the engine's id, or "apple".
    public var fileValue: String {
        switch self {
        case .added(let id): return id.uuidString
        case .apple: return "apple"
        }
    }

    /// The engine a file value names, or nil when it names none (a value this build does not know).
    public static func named(_ s: String) -> ProfileEngine? {
        if s == "apple" { return .apple }
        return UUID(uuidString: s).map { .added($0) }
    }
}

extension ProfileEngine: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let engine = ProfileEngine.named(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an engine id or \"apple\"")
        }
        self = engine
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(fileValue)
    }
}

/// How much surrounding text one app's translations carry (design §3, §9). Written in `settings.json` as
/// `{"mode": …, "previousLines": 0-8}`; `ContextOptions.resolved(base:override:)` lays it over the global choice.
public struct AppContextOverride: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// No context: today's request, byte for byte.
        case off
        /// The card, the note and the names, and nothing from the screen (design §1.4's default amount, §4.2's `memory`). A build
        /// before 1.1.5 reads this mode as no override (the lenient decode of `AppProfile`).
        case memory
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

/// A profile: a name, a language pair, and what else it sets (design §1.1). Today's app profile is one app condition
/// (`when` = [{app: bundleID}]); a profile without conditions is a preset, used only when it is picked.
public struct AppProfile: Codable, Equatable, Identifiable, Sendable {
    /// The caps of what a profile keeps (design §10, §5.3): `settings.json` and its validator use the same numbers.
    public static let maxEntries = 40
    public static let maxNoteLength = 500
    /// The cap on a profile's name (§5.3).
    public static let maxNameLength = 40
    /// The cap on a profile's conditions (§1.1, §5.3).
    public static let maxConditions = 8
    /// The cap on the profiles of a file (§5.3).
    public static let maxProfiles = 50
    /// The id All apps has (§5.1): a profile may not take it.
    public static let allAppsID = "all"

    /// Whether an id is one a profile may take (design §5.1): 1 to 255 of letters, digits, `.`, `-` and `_`, and
    /// never `all` (the base's id). An app's profile uses the bundle ID; the others a slug of the name.
    public static func isValidID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 255, id != allAppsID else { return false }
        return id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// The profile's id (design §5.1): unique, and an app's profile uses the bundle ID, so the learned rows and
    /// `Memory/<id>.json` keep their names.
    public var id: String
    /// The profile's name, for display.
    public var name: String { didSet { name = ContextText.truncated(name, toCharacters: Self.maxNameLength) } }
    /// The profile's "Used when" (design §1.1): up to `maxConditions` conditions. Empty = a preset.
    public var when: [ProfileCondition] { didSet { when = Array(when.prefix(Self.maxConditions)) } }
    public var source: String
    public var target: String
    /// The engine this profile uses; nil keeps All apps' choice (§5.1: an engine id or `"apple"`).
    public var engine: ProfileEngine?
    /// How this app's text is cut into paragraphs; nil inherits the global default.
    public var paragraphReader: ParagraphReader?
    /// The note for the translator (register, setting, audience), at most `maxNoteLength` characters. Empty for none.
    public var note: String { didSet { note = ContextMemory.cleanNote(note) } }
    /// The names and terms the user wrote or pinned, at most `maxEntries`, all `origin == .user`. Learned entries stay in RAM.
    public var entries: [MemoryEntry] { didSet { entries = Self.cleanEntries(entries) } }
    /// How much context this profile's translations carry; nil inherits All apps' amount (§2.1: the narrowest that sets it).
    public var context: AppContextOverride?
    /// Whether the names this profile sees are learned and kept (design §1.4, §2.1: the narrowest that sets it); nil
    /// inherits All apps' switch.
    public var useLearned: Bool?

    /// The app the profile is keyed by (design §1.1): the first app condition's bundle ID, or the id when it has no app
    /// condition. Today's app profile keeps its bundle ID here, so the App's call sites read the same.
    public var bundleID: String { when.compactMap(\.app).first ?? id }
    /// The profile's name (design §1.1): today's app profile keeps its app name here. Setting it sets the name.
    public var appName: String {
        get { name }
        set { name = newValue }
    }
    /// The added engine's id; nil for Apple and for "All apps' choice" (today's field, kept for the App's call sites).
    public var customEngineID: UUID? {
        get { engine?.id }
        set { engine = newValue.map { ProfileEngine.added($0) } }
    }

    /// The part of the profile that "Remember Languages" is about: the pair and the added engine.
    public var languages: LanguageChoice { LanguageChoice(source: source, target: target, customEngineID: customEngineID) }

    public init(bundleID: String, appName: String, source: String, target: String, customEngineID: UUID? = nil,
                paragraphReader: ParagraphReader? = nil, note: String = "", entries: [MemoryEntry] = [],
                context: AppContextOverride? = nil, id: String? = nil, name: String? = nil,
                when conditions: [ProfileCondition]? = nil, engine: ProfileEngine? = nil, useLearned: Bool? = nil) {
        self.id = id ?? bundleID
        self.name = ContextText.truncated(name ?? appName, toCharacters: Self.maxNameLength)
        // `didSet` does not run in an initializer, so the cap is applied here too.
        self.when = Array((conditions ?? [ProfileCondition(app: bundleID)]).prefix(Self.maxConditions))
        self.source = source
        self.target = target
        self.engine = engine ?? customEngineID.map { ProfileEngine.added($0) }
        self.paragraphReader = paragraphReader
        self.note = ContextMemory.cleanNote(note)
        self.entries = Self.cleanEntries(entries)
        self.context = context
        self.useLearned = useLearned
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

    // Decode leniently so a profile saved by another version never takes the others with it. The keys of today's
    // `appProfiles` items and the new ones (design §5.1: `id`, `name`, `when`, `useLearned`) are both read.
    enum CodingKeys: String, CodingKey, CaseIterable { case bundleID, appName, source, target, customEngineID, paragraphReader, note, entries, context }
    /// The new keys (design §5.1). They are read from every profile and written only when the old keys cannot say it, so
    /// today's `appProfiles` items are written byte for byte as before.
    enum NewKeys: String, CodingKey, CaseIterable { case id, name, when, useLearned }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let n = try decoder.container(keyedBy: NewKeys.self)
        // A profile is keyed by its id (the new shape) or its bundle ID (today's shape); one without either is not a profile.
        let newID = (try? n.decodeIfPresent(String.self, forKey: .id)) ?? nil
        let bundle = (try? c.decodeIfPresent(String.self, forKey: .bundleID)) ?? nil
        guard let key = newID ?? bundle, !key.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "a profile needs an id or a bundle ID"))
        }
        id = key
        let legacyName = (try? c.decodeIfPresent(String.self, forKey: .appName)) ?? nil
        name = ContextText.truncated((try? n.decodeIfPresent(String.self, forKey: .name)) ?? nil ?? legacyName ?? key,
                                     toCharacters: Self.maxNameLength)
        // The new shape's `when` wins; today's profile without one is the app profile it always was.
        if let conditions = (try? n.decodeIfPresent([ProfileCondition].self, forKey: .when)) ?? nil {
            when = Array(conditions.prefix(Self.maxConditions))
        } else if let bundle, !bundle.isEmpty {
            when = [ProfileCondition(app: bundle)]
        } else {
            when = []
        }
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? "auto"
        target = (try? c.decodeIfPresent(String.self, forKey: .target)) ?? "en"
        // The engine this profile uses: an id, or "apple" (design §5.1). A value this build does not know keeps the base choice.
        let raw = (try? c.decodeIfPresent(String.self, forKey: .customEngineID)) ?? nil
        engine = raw.flatMap { ProfileEngine.named($0) }
        // A reader this build does not know (saved by a newer version) inherits, like a profile without one.
        paragraphReader = (try? c.decodeIfPresent(ParagraphReader.self, forKey: .paragraphReader)) ?? nil
        // A profile without them (every profile saved before the memory) decodes with an empty note and no entries;
        // one bad entry is skipped, not the profile; an entry that says it is learned is not ours to keep.
        note = ContextMemory.cleanNote((try? c.decodeIfPresent(String.self, forKey: .note)) ?? "")
        entries = Self.cleanEntries(((try? c.decodeIfPresent(LossyArray<MemoryEntry>.self, forKey: .entries)) ?? nil)?.elements ?? [])
        // A context this build cannot read (no mode, a mode it does not know) inherits, like a profile without one.
        context = (try? c.decodeIfPresent(AppContextOverride.self, forKey: .context)) ?? nil
        useLearned = (try? n.decodeIfPresent(Bool.self, forKey: .useLearned)) ?? nil
    }

    // Written only when set, so a profile without a memory is saved exactly as before. The new keys are written only when
    // the old ones cannot say it: today's app profile (id = bundle ID, one app condition) is written as it always was.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bundleID, forKey: .bundleID)
        try c.encode(appName, forKey: .appName)
        try c.encode(source, forKey: .source)
        try c.encode(target, forKey: .target)
        try c.encodeIfPresent(engine, forKey: .customEngineID)
        try c.encodeIfPresent(paragraphReader, forKey: .paragraphReader)
        if !note.isEmpty { try c.encode(note, forKey: .note) }
        if !entries.isEmpty { try c.encode(entries, forKey: .entries) }
        try c.encodeIfPresent(context, forKey: .context)
        var n = encoder.container(keyedBy: NewKeys.self)
        if id != bundleID { try n.encode(id, forKey: .id) }
        if when != [ProfileCondition(app: bundleID)] { try n.encode(when, forKey: .when) }
        if useLearned == true { try n.encode(true, forKey: .useLearned) }
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
        effective(base: base, profile: profile(for: frontmost, in: profiles), engines: engines)
    }

    /// `profile` laid over `base`, or `base` itself with none: the pair of the profile and its engine while that engine exists. The head of a
    /// pinned chain decides the same way (design §1.3: the first profile decides the languages).
    public static func effective(base: LanguageChoice, profile: AppProfile?, engines: Set<UUID>) -> LanguageChoice {
        guard let p = profile else { return base }
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

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

    /// `profiles` with `profile` added, or replacing the one for the same app.
    public static func remembering(_ profile: AppProfile, in profiles: [AppProfile]) -> [AppProfile] {
        var out = profiles
        if let i = out.firstIndex(where: { $0.bundleID == profile.bundleID }) { out[i] = profile } else { out.append(profile) }
        return out
    }
}

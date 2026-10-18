import Foundation

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

    public var id: String { bundleID }

    public init(bundleID: String, appName: String, source: String, target: String, customEngineID: UUID? = nil,
                paragraphReader: ParagraphReader? = nil, note: String = "", entries: [MemoryEntry] = []) {
        self.bundleID = bundleID
        self.appName = appName
        self.source = source
        self.target = target
        self.customEngineID = customEngineID
        self.paragraphReader = paragraphReader
        self.note = ContextMemory.cleanNote(note)
        self.entries = Self.cleanEntries(entries)
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
    enum CodingKeys: String, CodingKey { case bundleID, appName, source, target, customEngineID, paragraphReader, note, entries }
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

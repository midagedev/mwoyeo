import Foundation

/// One row of a profile in the new file shape (design §5.1, §5.3): the row of the sheet plus the mode it is used in.
public struct ProfileFileEntry: Codable, Equatable, Sendable {
    /// The row itself (the model's `MemoryEntry`).
    public var entry: MemoryEntry
    /// How the row is used (design §10). nil = hint: what a file without the key means.
    public var apply: EntryApply?

    public init(_ entry: MemoryEntry, apply: EntryApply? = nil) {
        self.entry = entry
        self.apply = apply
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case src, dst, kind, gender, note, reading, addressing, apply }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entry = MemoryEntry(src: try c.decode(String.self, forKey: .src),
                            dst: try c.decode(String.self, forKey: .dst),
                            kind: (try? c.decodeIfPresent(EntryKind.self, forKey: .kind)) ?? .term,
                            gender: (try? c.decodeIfPresent(Gender.self, forKey: .gender)) ?? nil,
                            note: (try? c.decodeIfPresent(String.self, forKey: .note)) ?? "",
                            reading: (try? c.decodeIfPresent(String.self, forKey: .reading)) ?? nil,
                            addressing: ((try? c.decodeIfPresent(LossyArray<Addressing>.self, forKey: .addressing)) ?? nil)?.elements ?? [])
        apply = (try? c.decodeIfPresent(EntryApply.self, forKey: .apply)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(entry.src, forKey: .src)
        try c.encode(entry.dst, forKey: .dst)
        try c.encode(entry.kind, forKey: .kind)
        try c.encodeIfPresent(entry.gender, forKey: .gender)
        if !entry.note.isEmpty { try c.encode(entry.note, forKey: .note) }
        try c.encodeIfPresent(entry.reading, forKey: .reading)
        if !entry.addressing.isEmpty { try c.encode(entry.addressing, forKey: .addressing) }
        try c.encodeIfPresent(apply, forKey: .apply)
    }
}

/// One profile in the new file shape (design §5.1): `id`, `name`, `when`, and what it sets.
public struct ProfileFile: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var when: [ProfileCondition]
    public var source: String
    public var target: String
    public var customEngineID: ProfileEngine?
    public var paragraphReader: ParagraphReader?
    public var note: String
    public var entries: [ProfileFileEntry]
    public var context: AppContextOverride?
    public var useLearned: Bool?

    public init(id: String, name: String, when: [ProfileCondition] = [], source: String, target: String,
                customEngineID: ProfileEngine? = nil, paragraphReader: ParagraphReader? = nil, note: String = "",
                entries: [ProfileFileEntry] = [], context: AppContextOverride? = nil, useLearned: Bool? = nil) {
        self.id = id
        self.name = name
        self.when = when
        self.source = source
        self.target = target
        self.customEngineID = customEngineID
        self.paragraphReader = paragraphReader
        self.note = note
        self.entries = entries
        self.context = context
        self.useLearned = useLearned
    }

    /// The new shape of a profile of today's model (design §5.1).
    public init(_ profile: AppProfile) {
        self.init(id: profile.id, name: profile.name, when: profile.when, source: profile.source, target: profile.target,
                  customEngineID: profile.engine, paragraphReader: profile.paragraphReader, note: profile.note,
                  entries: profile.entries.map { ProfileFileEntry($0) }, context: profile.context,
                  useLearned: profile.useLearned)
    }

    /// The profile of today's model this file shape is (the App's own screens read the model).
    public var profile: AppProfile {
        AppProfile(bundleID: when.compactMap(\.app).first ?? id, appName: name, source: source, target: target,
                   paragraphReader: paragraphReader, note: note, entries: entries.map(\.entry), context: context,
                   id: id, name: name, when: when, engine: customEngineID, useLearned: useLearned)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, when, source, target, customEngineID, paragraphReader, note, entries, context, useLearned
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? ""
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? id
        when = (try? c.decodeIfPresent([ProfileCondition].self, forKey: .when)) ?? []
        source = (try? c.decodeIfPresent(String.self, forKey: .source)) ?? "auto"
        target = (try? c.decodeIfPresent(String.self, forKey: .target)) ?? "en"
        let raw = (try? c.decodeIfPresent(String.self, forKey: .customEngineID)) ?? nil
        customEngineID = raw.flatMap { ProfileEngine.named($0) }
        paragraphReader = (try? c.decodeIfPresent(ParagraphReader.self, forKey: .paragraphReader)) ?? nil
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? ""
        entries = ((try? c.decodeIfPresent([ProfileFileEntry].self, forKey: .entries)) ?? nil) ?? []
        context = (try? c.decodeIfPresent(AppContextOverride.self, forKey: .context)) ?? nil
        useLearned = (try? c.decodeIfPresent(Bool.self, forKey: .useLearned)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        if !when.isEmpty { try c.encode(when, forKey: .when) }
        try c.encode(source, forKey: .source)
        try c.encode(target, forKey: .target)
        try c.encodeIfPresent(customEngineID, forKey: .customEngineID)
        try c.encodeIfPresent(paragraphReader, forKey: .paragraphReader)
        if !note.isEmpty { try c.encode(note, forKey: .note) }
        if !entries.isEmpty { try c.encode(entries, forKey: .entries) }
        try c.encodeIfPresent(context, forKey: .context)
        if useLearned == true { try c.encode(true, forKey: .useLearned) }
    }
}

/// The file of 1.1.4, as far as the conversion reads it (design §5.2).
///
/// The keys the conversion does not own (the lens style, the shortcuts, …) are not read and not in the value: the
/// caller merges the converted keys into the file it read.
public struct LegacySettings: Codable, Equatable, Sendable {
    // All apps' fields, unchanged (design §5.2's last row).
    public var sourceLanguage: String?
    public var targetLanguage: String?
    public var engine: String?
    public var customEngineID: UUID?
    public var glossary: String?
    public var paragraphReader: ParagraphReader?
    /// The switch of 1.1.4: Apple's pre-insertion of the names (§5.2's Apple row).
    public var appleUsesPinnedTerms: Bool?
    /// Today's profiles (read, never written).
    public var appProfiles: [AppProfile]?
    /// Today's engines with their own context (read, never written).
    public var engines: [EngineConfig]?
    // The new keys, when the file already has them.
    public var profiles: [ProfileFile]?
    public var context: AppContextOverride?
    public var useLearned: Bool?
    public var profilePin: String?
    public var glossaryApply: EntryApply?

    public init(sourceLanguage: String? = nil, targetLanguage: String? = nil, engine: String? = nil,
                customEngineID: UUID? = nil, glossary: String? = nil, paragraphReader: ParagraphReader? = nil,
                appleUsesPinnedTerms: Bool? = nil, appProfiles: [AppProfile]? = nil, engines: [EngineConfig]? = nil,
                profiles: [ProfileFile]? = nil, context: AppContextOverride? = nil, useLearned: Bool? = nil,
                profilePin: String? = nil, glossaryApply: EntryApply? = nil) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.engine = engine
        self.customEngineID = customEngineID
        self.glossary = glossary
        self.paragraphReader = paragraphReader
        self.appleUsesPinnedTerms = appleUsesPinnedTerms
        self.appProfiles = appProfiles
        self.engines = engines
        self.profiles = profiles
        self.context = context
        self.useLearned = useLearned
        self.profilePin = profilePin
        self.glossaryApply = glossaryApply
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case sourceLanguage, targetLanguage, engine, customEngineID, glossary, paragraphReader
        case appleUsesPinnedTerms, appProfiles, engines, profiles, context, useLearned, profilePin, glossaryApply
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceLanguage = (try? c.decodeIfPresent(String.self, forKey: .sourceLanguage)) ?? nil
        targetLanguage = (try? c.decodeIfPresent(String.self, forKey: .targetLanguage)) ?? nil
        engine = (try? c.decodeIfPresent(String.self, forKey: .engine)) ?? nil
        customEngineID = (try? c.decodeIfPresent(UUID.self, forKey: .customEngineID)) ?? nil
        glossary = (try? c.decodeIfPresent(String.self, forKey: .glossary)) ?? nil
        paragraphReader = (try? c.decodeIfPresent(ParagraphReader.self, forKey: .paragraphReader)) ?? nil
        appleUsesPinnedTerms = (try? c.decodeIfPresent(Bool.self, forKey: .appleUsesPinnedTerms)) ?? nil
        appProfiles = (try? c.decodeIfPresent([AppProfile].self, forKey: .appProfiles)) ?? nil
        // An engine this build does not know (a kind it does not have) is left out, as the settings-file read leaves it
        // out today; the other engines are converted.
        engines = ((try? c.decodeIfPresent(LossyArray<EngineConfig>.self, forKey: .engines)) ?? nil)?.elements
        profiles = (try? c.decodeIfPresent([ProfileFile].self, forKey: .profiles)) ?? nil
        context = (try? c.decodeIfPresent(AppContextOverride.self, forKey: .context)) ?? nil
        useLearned = (try? c.decodeIfPresent(Bool.self, forKey: .useLearned)) ?? nil
        profilePin = (try? c.decodeIfPresent(String.self, forKey: .profilePin)) ?? nil
        glossaryApply = (try? c.decodeIfPresent(EntryApply.self, forKey: .glossaryApply)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(sourceLanguage, forKey: .sourceLanguage)
        try c.encodeIfPresent(targetLanguage, forKey: .targetLanguage)
        try c.encodeIfPresent(engine, forKey: .engine)
        try c.encodeIfPresent(customEngineID, forKey: .customEngineID)
        try c.encodeIfPresent(glossary, forKey: .glossary)
        try c.encodeIfPresent(paragraphReader, forKey: .paragraphReader)
        try c.encodeIfPresent(appleUsesPinnedTerms, forKey: .appleUsesPinnedTerms)
        try c.encodeIfPresent(appProfiles, forKey: .appProfiles)
        try c.encodeIfPresent(engines, forKey: .engines)
        try c.encodeIfPresent(profiles, forKey: .profiles)
        try c.encodeIfPresent(context, forKey: .context)
        if useLearned == true { try c.encode(true, forKey: .useLearned) }
        try c.encodeIfPresent(profilePin, forKey: .profilePin)
        if let glossaryApply, glossaryApply != .hint { try c.encode(glossaryApply, forKey: .glossaryApply) }
    }
}

/// The file in the new shape, as far as the conversion writes it (design §5.1, §5.2).
public struct MigratedSettings: Codable, Equatable, Sendable {
    // All apps' fields, unchanged.
    public var sourceLanguage: String?
    public var targetLanguage: String?
    public var engine: String?
    public var customEngineID: UUID?
    public var glossary: String?
    public var paragraphReader: ParagraphReader?
    // The new keys.
    /// All apps' amount (design §1.4); absent means `memory`.
    public var context: AppContextOverride?
    /// All apps' "learn names and terms" (written only when true).
    public var useLearned: Bool?
    /// The pin of every lens (absent = Auto).
    public var profilePin: String?
    /// How the glossary's rows are used (written only when not hint).
    public var glossaryApply: EntryApply?
    /// The profiles.
    public var profiles: [ProfileFile]
    /// The engines, with their permissions and without the old `context` (read, never written).
    public var engines: [EngineConfig]?

    public init(sourceLanguage: String? = nil, targetLanguage: String? = nil, engine: String? = nil,
                customEngineID: UUID? = nil, glossary: String? = nil, paragraphReader: ParagraphReader? = nil,
                context: AppContextOverride? = nil, useLearned: Bool? = nil, profilePin: String? = nil,
                glossaryApply: EntryApply? = nil, profiles: [ProfileFile] = [], engines: [EngineConfig]? = nil) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.engine = engine
        self.customEngineID = customEngineID
        self.glossary = glossary
        self.paragraphReader = paragraphReader
        self.context = context
        self.useLearned = useLearned
        self.profilePin = profilePin
        self.glossaryApply = glossaryApply
        self.profiles = profiles
        self.engines = engines
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case sourceLanguage, targetLanguage, engine, customEngineID, glossary, paragraphReader
        case context, useLearned, profilePin, glossaryApply, profiles, engines
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceLanguage = (try? c.decodeIfPresent(String.self, forKey: .sourceLanguage)) ?? nil
        targetLanguage = (try? c.decodeIfPresent(String.self, forKey: .targetLanguage)) ?? nil
        engine = (try? c.decodeIfPresent(String.self, forKey: .engine)) ?? nil
        customEngineID = (try? c.decodeIfPresent(UUID.self, forKey: .customEngineID)) ?? nil
        glossary = (try? c.decodeIfPresent(String.self, forKey: .glossary)) ?? nil
        paragraphReader = (try? c.decodeIfPresent(ParagraphReader.self, forKey: .paragraphReader)) ?? nil
        context = (try? c.decodeIfPresent(AppContextOverride.self, forKey: .context)) ?? nil
        useLearned = (try? c.decodeIfPresent(Bool.self, forKey: .useLearned)) ?? nil
        profilePin = (try? c.decodeIfPresent(String.self, forKey: .profilePin)) ?? nil
        glossaryApply = (try? c.decodeIfPresent(EntryApply.self, forKey: .glossaryApply)) ?? nil
        profiles = (try? c.decodeIfPresent([ProfileFile].self, forKey: .profiles)) ?? []
        engines = (try? c.decodeIfPresent([EngineConfig].self, forKey: .engines)) ?? nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(sourceLanguage, forKey: .sourceLanguage)
        try c.encodeIfPresent(targetLanguage, forKey: .targetLanguage)
        try c.encodeIfPresent(engine, forKey: .engine)
        try c.encodeIfPresent(customEngineID, forKey: .customEngineID)
        try c.encodeIfPresent(glossary, forKey: .glossary)
        try c.encodeIfPresent(paragraphReader, forKey: .paragraphReader)
        try c.encodeIfPresent(context, forKey: .context)
        if useLearned == true { try c.encode(true, forKey: .useLearned) }
        try c.encodeIfPresent(profilePin, forKey: .profilePin)
        if let glossaryApply, glossaryApply != .hint { try c.encode(glossaryApply, forKey: .glossaryApply) }
        if !profiles.isEmpty { try c.encode(profiles, forKey: .profiles) }
        try c.encodeIfPresent(engines, forKey: .engines)
    }
}

/// The four cases in which a request of a 1.1.4 file is not made again (design §5.2).
public enum MigrationException: String, Equatable, Sendable, CaseIterable {
    /// (a) A lens over app B while A is in front uses B's pair and engine (Q1).
    case lensUsesItsOwnProfile
    /// (b) A spare engine's own `previousLines` follows the profile amount (the only value with no new home).
    case spareEnginePreviousLines
    /// (c) An engine with context off × an app whose override sent lines × another engine with context on: the new rules apply.
    case engineOffWithAppOverride
    /// (d) With the Apple switch on, engines other than Apple Translation also get those names put into the source.
    case applePinsBecomeBoth
}

/// What the conversion gives: the new value and the exceptions that apply to the file it read.
public struct ProfileMigrationResult: Equatable, Sendable {
    public var value: MigratedSettings
    public var exceptions: [MigrationException]

    public init(value: MigratedSettings, exceptions: [MigrationException]) {
        self.value = value
        self.exceptions = exceptions
    }
}

/// The converter of the 1.1.4 file (design §5.2): one pure function, the table row by row.
public enum ProfileMigration {
    /// The new value of a file of 1.1.4, and the exceptions that apply to it.
    ///
    /// The table (design §5.2):
    ///
    /// | Old key | New key | Rule |
    /// |---|---|---|
    /// | `appProfiles[i]` | `profiles[i]` | `id` = `bundleID`; `name` = `appName`; `when` = [{`app`: `bundleID`}]; `source`, `target`, `customEngineID`, `paragraphReader`, `note`, `entries`, `context` copied |
    /// | `engines[j].context.enabled`, `.previousLines` | top-level `context` | from the engine in use, else the first with `enabled`; off or absent → no key (`memory`); on + 0 → `nearby`; on + n → `conversation` n |
    /// | same, of a profile's own engine | `profiles[i].context` | set when the profile has none and its engine's old amount differs from the top-level one |
    /// | `engines[j].context.enabled == false` | `engines[j].allow.lines = false` | only when the top-level amount sends lines and no profile does |
    /// | `engines[j].context.useLearned` | `useLearned` (top-level, profile) | from the same engine as the amount; a profile whose own engine differs gets its own |
    /// | `.includeTitle`, `.deepLInstructions` | `allow.title`, `allow.deepLInstructions` | copied when `enabled` was on, else false (they did nothing) |
    /// | `appleUsesPinnedTerms: true` | `entries[].apply = "both"` on every user row; `glossaryApply: "both"` | false or absent → nothing written (`hint`) |
    /// | `glossary`, `sourceLanguage`, `targetLanguage`, `customEngineID`, `engine`, `paragraphReader` | unchanged | All apps' fields |
    ///
    /// With both `profiles` and `appProfiles`, the latter is ignored: the file is already in the new shape.
    public static func convert(_ old: LegacySettings) -> ProfileMigrationResult {
        let engines = old.engines ?? []
        // The profiles: the file's own, or today's (read, never written).
        var profiles: [ProfileFile]
        if let new = old.profiles {
            profiles = new
        } else {
            profiles = (old.appProfiles ?? []).map { ProfileFile($0) }
        }

        // The engine the amount comes from: the one in use, else the first that was on.
        let inUse = old.customEngineID.flatMap { id in engines.first { $0.id == id } }
        let amountEngine = inUse ?? engines.first { $0.context?.enabled == true }
        let topAmount = amountEngine.flatMap { oldAmount($0.context) } ?? .memory

        // The top-level amount (design §5.2's second row): off or absent writes no key, the amount is `memory`.
        let topContext: AppContextOverride? = switch topAmount {
        case .nearby: AppContextOverride(mode: .nearby, previousLines: 0)
        case .conversation(let n): AppContextOverride(mode: .conversation, previousLines: n)
        case .off, .memory: nil
        }
        // The chain's learn switch: from the same engine as the amount.
        let topUseLearned = amountEngine?.context?.useLearned == true

        // A profile's own engine (design §5.2's third and fifth rows).
        for i in profiles.indices {
            guard let id = profiles[i].customEngineID?.id, let engine = engines.first(where: { $0.id == id }) else { continue }
            let amount = oldAmount(engine.context)
            if profiles[i].context == nil, amount != topAmount {
                switch amount {
                case .nearby: profiles[i].context = AppContextOverride(mode: .nearby, previousLines: 0)
                case .conversation(let n): profiles[i].context = AppContextOverride(mode: .conversation, previousLines: n)
                case .off, .memory: break   // `memory` has no mode of its own yet; the engine's `allow.lines` carries it
                }
            }
            if profiles[i].useLearned == nil, engine.id != amountEngine?.id, engine.context?.useLearned == true {
                profiles[i].useLearned = true
            }
        }

        // The engines' permissions (design §5.2's fourth and sixth rows). A file that is already in the new shape keeps
        // the permissions it has; only the old shape's `context` is read and turned into them.
        let alreadyNew = old.profiles != nil
        let aProfileSendsLines = profiles.contains { p in
            guard let c = p.context else { return false }
            return ContextAmount(c).sendsLines
        }
        var migratedEngines: [EngineConfig] = []
        for e in engines {
            var out = e
            if !alreadyNew {
                let wasOn = e.context?.enabled == true
                var allow = EngineAllow.default
                allow.title = wasOn ? (e.context?.includeTitle ?? false) : false
                allow.deepLInstructions = wasOn ? (e.context?.deepLInstructions ?? false) : false
                if !wasOn, topAmount.sendsLines, !aProfileSendsLines { allow.lines = false }
                out.allow = allow
            }
            out.context = nil        // `engines[].context` is read, never written
            migratedEngines.append(out)
        }

        // The Apple switch (design §5.2's seventh row): every user row is used in both ways, and so is the glossary.
        let appleBoth = old.appleUsesPinnedTerms == true
        if appleBoth {
            for i in profiles.indices {
                profiles[i].entries = profiles[i].entries.map { ProfileFileEntry($0.entry, apply: .both) }
            }
        }

        var value = MigratedSettings(sourceLanguage: old.sourceLanguage, targetLanguage: old.targetLanguage,
                                     engine: old.engine, customEngineID: old.customEngineID, glossary: old.glossary,
                                     paragraphReader: old.paragraphReader, context: topContext,
                                     useLearned: topUseLearned ? true : nil, profilePin: old.profilePin,
                                     glossaryApply: appleBoth ? .both : old.glossaryApply,
                                     profiles: profiles, engines: migratedEngines.isEmpty ? nil : migratedEngines)

        // The file is already in the new shape: its own keys are kept.
        if old.profiles != nil {
            value.context = old.context ?? value.context
            value.useLearned = old.useLearned ?? value.useLearned
            value.profilePin = old.profilePin ?? value.profilePin
            value.glossaryApply = old.glossaryApply ?? value.glossaryApply
        }

        return ProfileMigrationResult(value: value, exceptions: exceptions(for: old, profiles: profiles, engines: engines))
    }

    /// The amount an engine's old context meant (design §5.2's second row): off or absent is `memory` (no key), on
    /// with no earlier lines is `nearby`, on with `n` earlier lines is `conversation n`.
    static func oldAmount(_ context: EngineContext?) -> ContextAmount {
        guard let context, context.enabled else { return .memory }
        return context.previousLines == 0 ? .nearby : .conversation(context.previousLines)
    }

    /// The exceptions that apply to the file (design §5.2's list of four).
    ///
    /// - (a) the file has a profile with an app condition: a lens over another app than the one in front now uses that
    ///   app's pair and engine.
    /// - (b) an engine other than the one the amount comes from was on with an amount of its own: its `previousLines`
    ///   has no new home and follows the profile amount.
    /// - (c) an engine was off, an app's override sent lines, and another engine was on: the new rules apply.
    /// - (d) the Apple switch was on: the names go into the source for the other engines too.
    static func exceptions(for old: LegacySettings, profiles: [ProfileFile], engines: [EngineConfig]) -> [MigrationException] {
        var out: [MigrationException] = []
        if profiles.contains(where: { p in p.when.contains { !($0.app ?? "").isEmpty } }) {
            out.append(.lensUsesItsOwnProfile)
        }
        let amountEngine = old.customEngineID.flatMap { id in engines.first { $0.id == id } }
            ?? engines.first { $0.context?.enabled == true }
        let topAmount = amountEngine.flatMap { oldAmount($0.context) } ?? .memory
        if engines.contains(where: { e in e.id != amountEngine?.id && e.context?.enabled == true && oldAmount(e.context) != topAmount }) {
            out.append(.spareEnginePreviousLines)
        }
        let anEngineIsOff = engines.contains { $0.context?.enabled != true }
        let anotherIsOn = engines.contains { $0.context?.enabled == true }
        let anAppSendsLines = profiles.contains { p in
            guard let c = p.context else { return false }
            return ContextAmount(c).sendsLines
        }
        if anEngineIsOff && anotherIsOn && anAppSendsLines { out.append(.engineOffWithAppOverride) }
        if old.appleUsesPinnedTerms == true { out.append(.applePinsBecomeBoth) }
        return out
    }
}

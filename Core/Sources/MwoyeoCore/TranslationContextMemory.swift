import Foundation

// The memory model (design §2, §8): entries, the sheet with its learning rule, and referents.
// Pure value types. Nothing here touches the disk or the network; the app owns where each part is kept
// (user and pinned entries in `AppProfile`, learned entries in RAM).

public enum EntryKind: String, Codable, CaseIterable, Sendable {
    case person, place, term, org
}

public enum Gender: String, Codable, CaseIterable, Sendable {
    case f, m, n
}

public enum Register: String, Codable, CaseIterable, Sendable {
    case casual, polite, formal, honorific
}

public enum EntryOrigin: String, Codable, Sendable {
    case user, learned
}

/// "To `to`, this person speaks in `register`."
public struct Addressing: Codable, Equatable, Hashable, Sendable {
    public var to: String
    public var register: Register

    public init(to: String, register: Register) {
        self.to = ContextText.truncated(ContextText.collapse(to), toCharacters: MemoryEntry.maxName)
        self.register = register
    }

    // Read through the capping init; a row without a valid `to` or `register` throws and `LossyArray` drops just that row.
    enum CodingKeys: String, CodingKey { case to, register }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(to: try c.decode(String.self, forKey: .to), register: try c.decode(Register.self, forKey: .register))
    }
}

/// One row of the sheet: `src -> dst`, with what a translator needs to know about it.
/// Free text is single-line and capped when the entry is made, so a row renders the same everywhere.
public struct MemoryEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let maxName = 80
    /// The cap on an entry's `note` (age, role, manner of speaking).
    public static let maxEntryNote = 40
    public static let maxAddressing = 4

    public var src: String
    public var dst: String
    public var kind: EntryKind
    public var gender: Gender?
    /// At most `maxEntryNote` characters: age, role, manner of speaking.
    public var note: String
    /// Japanese reading of `src`, when it helps the model.
    public var reading: String?
    public var origin: EntryOrigin
    public var uses: Int
    public var lastSeen: Date?
    public var addressing: [Addressing]

    public var id: String { ContextText.foldedKey(src) }

    public init(src: String, dst: String, kind: EntryKind = .term, gender: Gender? = nil, note: String = "",
                reading: String? = nil, origin: EntryOrigin = .user, uses: Int = 0, lastSeen: Date? = nil,
                addressing: [Addressing] = []) {
        self.src = ContextText.truncated(ContextText.collapse(src), toCharacters: Self.maxName)
        self.dst = ContextText.truncated(ContextText.collapse(dst), toCharacters: Self.maxName)
        self.kind = kind
        self.gender = gender
        self.note = ContextText.truncated(ContextText.collapse(note), toCharacters: Self.maxEntryNote)
        let r = reading.map { ContextText.truncated(ContextText.collapse($0), toCharacters: Self.maxName) }
        self.reading = (r?.isEmpty ?? true) ? nil : r
        self.origin = origin
        self.uses = max(0, uses)
        self.lastSeen = lastSeen
        self.addressing = Array(addressing.prefix(Self.maxAddressing))
    }

    // The Codable shape is the settings-file shape (design §10): src, dst, kind, gender, note, reading, addressing
    // (to, register). Nothing else is written or read; `origin`, `uses` and `lastSeen` live in RAM only, and an entry read
    // from a file is a user entry. Lenient: a bad enum value, a missing field or a bad addressing row never loses the
    // entry; an entry without `src` or `dst` throws, and `LossyArray` drops just that one.
    enum CodingKeys: String, CodingKey { case src, dst, kind, gender, note, reading, addressing }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let src = try c.decode(String.self, forKey: .src)
        let dst = try c.decode(String.self, forKey: .dst)
        self.init(
            src: src, dst: dst,
            kind: (try? c.decodeIfPresent(EntryKind.self, forKey: .kind)) ?? .term,
            gender: (try? c.decodeIfPresent(Gender.self, forKey: .gender)) ?? nil,
            note: (try? c.decodeIfPresent(String.self, forKey: .note)) ?? "",
            reading: (try? c.decodeIfPresent(String.self, forKey: .reading)) ?? nil,
            addressing: ((try? c.decodeIfPresent(LossyArray<Addressing>.self, forKey: .addressing)) ?? nil)?.elements ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(src, forKey: .src)
        try c.encode(dst, forKey: .dst)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(gender, forKey: .gender)
        if !note.isEmpty { try c.encode(note, forKey: .note) }
        try c.encodeIfPresent(reading, forKey: .reading)
        if !addressing.isEmpty { try c.encode(addressing, forKey: .addressing) }
    }
}

/// An array whose bad elements are skipped instead of failing the whole decode.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [Element] = []
        while !c.isAtEnd {
            if let e = try? c.decode(Element.self) { out.append(e) } else { _ = try? c.decode(Skip.self) }
        }
        elements = out
    }

    private struct Skip: Decodable {}
}

/// "`pronoun` means `refersTo`" for the current document, e.g. `he/그 = 田中`. Typed by the user; never learned.
public struct Referent: Codable, Equatable, Hashable, Sendable {
    public static let maxCount = 8
    public static let maxText = 30

    public var pronoun: String
    public var refersTo: String

    public init(pronoun: String, refersTo: String) {
        self.pronoun = ContextText.truncated(ContextText.collapse(pronoun), toCharacters: Self.maxText)
        self.refersTo = ContextText.truncated(ContextText.collapse(refersTo), toCharacters: Self.maxText)
    }

    public var rendered: String { "\(pronoun) = \(refersTo)" }
    var isEmpty: Bool { pronoun.isEmpty || refersTo.isEmpty }
}

/// What the model said it translated: `{"src","dst","kind"?,"gender"?}` from the reply's `terms`.
public struct TermHint: Equatable, Sendable {
    public var src: String
    public var dst: String
    public var kind: EntryKind?
    public var gender: Gender?

    public init(src: String, dst: String, kind: EntryKind? = nil, gender: Gender? = nil) {
        self.src = src
        self.dst = dst
        self.kind = kind
        self.gender = gender
    }
}

/// Why a learned term did or did not change the sheet (for the debug trace and the tests; never shown with text).
public enum LearnVerdict: Equatable, Sendable {
    public enum Rejection: String, Equatable, Sendable {
        /// Empty, a newline or markup character, too short, or longer than 40 characters.
        case malformed
        /// Reads like an instruction ("ignore previous instructions").
        case instructionLike
        /// `src` and `dst` are the same word.
        case identity
        /// `src` is already an app user entry or a global glossary term (design §8.2).
        case shadowed
        /// `src` does not occur in this request's items.
        case srcNotInItems
        /// `dst` does not occur in the reply.
        case dstNotInReply
        /// 30 learned entries and none of them is still waiting for its second sighting.
        case full
    }

    case rejected(Rejection)
    /// A new or repeated sighting with the same `dst`; the associated value is the sighting count.
    case sighted(Int)
    /// The same `src` with another `dst`; the entry stays (value = contradictions so far).
    case contradicted(Int)
    /// The second contradiction removed the entry.
    case dropped
}

/// The sheet of one app: the user's note and entries (saved in `AppProfile`) and the learned entries (RAM only).
///
/// - A **user** entry is authoritative. Pinning a learned entry makes it a user entry.
/// - A **learned** entry is a hint. It is accepted only when `src` occurs in the request's items and `dst` in the reply,
///   it is used after `confirmAfter` sightings with the same `dst`, and two contradictions drop it (design §8.7).
/// - Precedence (§8.2): an app user entry outranks the global glossary, which outranks a learned hint.
public struct ContextMemory: Equatable, Sendable {
    public static let maxLearned = 30
    public static let maxLearnedText = 40
    public static let confirmAfter = 2
    public static let dropAfterContradictions = 2
    /// Terms read from one reply (the rest are ignored).
    public static let maxHintsPerReply = 12

    public struct LearnedRecord: Equatable, Sendable {
        public var entry: MemoryEntry
        public var sightings: Int
        public var contradictions: Int
        public var isUsable: Bool { sightings >= ContextMemory.confirmAfter }
    }

    /// The app note for the translator, at most 500 characters. Newlines are kept (it is the user's prose).
    public private(set) var note: String
    /// User and pinned entries, in the order the user keeps them.
    public private(set) var user: [MemoryEntry]
    public private(set) var learned: [LearnedRecord]

    public init(note: String = "", entries: [MemoryEntry] = []) {
        self.note = Self.cleanNote(note)
        self.user = []
        self.learned = []
        for e in entries { _ = addUser(e) }
    }

    public init(profile: AppProfile) {
        self.init(note: profile.note, entries: profile.entries)
    }

    static func cleanNote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= AppProfile.maxNoteLength ? t : String(t.prefix(AppProfile.maxNoteLength))
    }

    public mutating func setNote(_ s: String) { note = Self.cleanNote(s) }

    // MARK: user entries

    /// Adds `entry` as a user entry, or replaces the one with the same `src`. False when the sheet is full (40).
    /// A learned entry with the same `src` goes away: the user's word wins.
    @discardableResult
    public mutating func addUser(_ entry: MemoryEntry) -> Bool {
        var e = entry
        e.origin = .user
        guard !e.src.isEmpty, !e.dst.isEmpty else { return false }
        if let i = user.firstIndex(where: { $0.id == e.id }) {
            user[i] = e
        } else {
            guard user.count < AppProfile.maxEntries else { return false }
            user.append(e)
        }
        learned.removeAll { $0.entry.id == e.id }
        return true
    }

    public mutating func removeUser(src: String) {
        let key = ContextText.foldedKey(src)
        user.removeAll { $0.id == key }
    }

    // MARK: learned entries

    /// Learned entries that are used in requests (two sightings or more).
    public var usableLearned: [MemoryEntry] { learned.filter(\.isUsable).map(\.entry) }

    /// The rows a request may use: user entries and usable learned entries.
    public var rows: [MemoryEntry] { user + usableLearned }

    /// The learning rule. Returns one verdict per distinct `src` in `hints`, in order.
    ///
    /// `items` are this request's source lines and `reply` its translations. `glossary` is the global glossary, whose
    /// terms a learned hint may not shadow. Hints beyond `maxHintsPerReply` are ignored.
    @discardableResult
    public mutating func learn(_ hints: [TermHint], items: [String], reply: [String], glossary: [(String, String)] = [],
                               now: Date = Date()) -> [LearnVerdict] {
        var verdicts: [LearnVerdict] = []
        var seen = Set<String>()
        let userKeys = Set(user.map(\.id))
        let glossaryKeys = Set(glossary.map { ContextText.foldedKey($0.0) })
        let joinedReply = reply.joined(separator: "\n")
        for hint in hints.prefix(Self.maxHintsPerReply) {
            let src = ContextText.collapse(hint.src), dst = ContextText.collapse(hint.dst)
            let key = ContextText.foldedKey(src)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            if let why = Self.rejection(src: src, dst: dst, hint: hint) { verdicts.append(.rejected(why)); continue }
            if userKeys.contains(key) || glossaryKeys.contains(key) { verdicts.append(.rejected(.shadowed)); continue }
            if !items.contains(where: { ContextText.occurs(src, in: $0) }) { verdicts.append(.rejected(.srcNotInItems)); continue }
            if !ContextText.occurs(dst, in: joinedReply) { verdicts.append(.rejected(.dstNotInReply)); continue }

            if let i = learned.firstIndex(where: { $0.entry.id == key }) {
                if ContextText.foldedKey(learned[i].entry.dst) == ContextText.foldedKey(dst) {
                    learned[i].sightings += 1
                    learned[i].entry.uses += 1
                    learned[i].entry.lastSeen = now
                    if learned[i].entry.gender == nil { learned[i].entry.gender = hint.gender }
                    if let k = hint.kind, learned[i].entry.kind == .term { learned[i].entry.kind = k }
                    verdicts.append(.sighted(learned[i].sightings))
                } else {
                    learned[i].contradictions += 1
                    if learned[i].contradictions >= Self.dropAfterContradictions {
                        learned.remove(at: i)
                        verdicts.append(.dropped)
                    } else {
                        verdicts.append(.contradicted(learned[i].contradictions))
                    }
                }
                continue
            }
            if learned.count >= Self.maxLearned {
                // Make room only from entries that never reached their second sighting, least recently seen first.
                let victim = learned.indices.filter { !learned[$0].isUsable }
                    .min { (learned[$0].entry.lastSeen ?? .distantPast) < (learned[$1].entry.lastSeen ?? .distantPast) }
                guard let victim else { verdicts.append(.rejected(.full)); continue }
                learned.remove(at: victim)
            }
            let entry = MemoryEntry(src: src, dst: dst, kind: hint.kind ?? .term, gender: hint.gender, origin: .learned,
                                    uses: 1, lastSeen: now)
            learned.append(LearnedRecord(entry: entry, sightings: 1, contradictions: 0))
            verdicts.append(.sighted(1))
        }
        return verdicts
    }

    static func rejection(src: String, dst: String, hint: TermHint) -> LearnVerdict.Rejection? {
        if src.count < 2 || dst.isEmpty || src.count > maxLearnedText || dst.count > maxLearnedText { return .malformed }
        for text in [hint.src, hint.dst] where text.contains(where: { $0.isNewline || forbidden.contains($0) }) { return .malformed }
        if isInstructionLike(src) || isInstructionLike(dst) { return .instructionLike }
        if ContextText.foldedKey(src) == ContextText.foldedKey(dst) { return .identity }
        return nil
    }

    private static let forbidden: Set<Character> = ["{", "}", "[", "]", "<", ">", "`", "|", "\\"]

    /// Text that tries to steer the model rather than name something. A name does not contain these.
    static func isInstructionLike(_ s: String) -> Bool {
        let t = s.lowercased()
        let markers = [
            "ignore ", "disregard", "instruction", "system prompt", "you must", "you are", "do not", "never ",
            "always ", "from now on", "reply with", "respond with", "output ", "translate ", "assistant", "the above",
            "previous", "forget ", "pretend", "override", "jailbreak",
            "以前の指示", "指示を無視", "指示に従", "忽略之前", "忽略以上", "无视之前", "이전 지시", "지시를 무시", "지시 무시", "무시하고",
        ]
        return markers.contains { t.contains($0) }
    }

    /// Makes the learned entry for `src` a user entry. False when there is none, or the user sheet is full.
    @discardableResult
    public mutating func pin(src: String) -> Bool {
        let key = ContextText.foldedKey(src)
        guard let i = learned.firstIndex(where: { $0.entry.id == key }) else { return false }
        guard user.count < AppProfile.maxEntries || user.contains(where: { $0.id == key }) else { return false }
        let entry = learned[i].entry
        return addUser(entry)
    }

    public mutating func removeLearned(src: String) {
        let key = ContextText.foldedKey(src)
        learned.removeAll { $0.entry.id == key }
    }

    /// "Forget learned".
    public mutating func forgetLearned() { learned.removeAll() }

    /// Counts a use of these rows (their `src`), for the "by uses" order. Persisting `uses` is the app's call.
    public mutating func recordUse(of srcs: [String], now: Date = Date()) {
        let keys = Set(srcs.map(ContextText.foldedKey))
        for i in user.indices where keys.contains(user[i].id) { user[i].uses += 1; user[i].lastSeen = now }
        for i in learned.indices where keys.contains(learned[i].entry.id) { learned[i].entry.uses += 1; learned[i].entry.lastSeen = now }
    }

    // MARK: fingerprint

    /// A canonical string of the app note and the user entries, for the translation-memory namespace (§8.1).
    /// Learned entries, `uses` and `lastSeen` are left out on purpose: they change without changing what the user wrote.
    /// Stable across runs; the caller may hash it (`Hasher` is process-local, which is fine for RAM-only use).
    public var memoryFingerprint: String {
        let rows = user.map { e in
            [e.src, e.dst, e.kind.rawValue, e.gender?.rawValue ?? "", e.note, e.reading ?? "",
             e.addressing.map { "\($0.to)>\($0.register.rawValue)" }.joined(separator: ",")].joined(separator: "\u{1F}")
        }.sorted()
        return (["note=\(note)"] + rows).joined(separator: "\u{1E}")
    }
}

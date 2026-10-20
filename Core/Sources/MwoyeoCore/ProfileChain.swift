import Foundation

/// How much context the chain sends (design §1.4, §4.2).
///
/// The amount is one value for the whole chain: the narrowest profile that sets it, else All apps (design §2.1).
/// `off` is today's request, byte for byte; `memory` is the card, the note and the names; `nearby` is the lines
/// around; `conversation` is those and `n` earlier lines.
public enum ContextAmount: Equatable, Sendable {
    case off
    case memory
    case nearby
    case conversation(Int)

    /// The amount an app's context override means (design §4.2's table reads the chain's amount).
    ///
    /// A `memory` override is a case of the mode of a future build (the App's own screens and the settings-file
    /// schema follow it); until then the three modes of today map one to one.
    public init(_ override: AppContextOverride) {
        switch override.mode {
        case .off: self = .off
        case .nearby: self = .nearby
        case .conversation: self = .conversation(override.previousLines)
        }
    }

    /// Whether this amount sends the lines around the text (design §4.2's table: `nearby` and `conversation` do).
    public var sendsLines: Bool {
        switch self {
        case .off, .memory: return false
        case .nearby, .conversation: return true
        }
    }
}

/// The window a lens is over (design §1.2, §1.3): the app in front of it, and the title once it is confirmed.
public struct WindowFacts: Equatable, Sendable {
    /// The bundle ID of the app whose window the lens is over.
    public var bundleID: String?
    /// The confirmed window title. nil until it is confirmed (≈ 1 s): until then only app conditions match.
    public var title: String?

    public init(bundleID: String? = nil, title: String? = nil) {
        self.bundleID = bundleID
        self.title = title
    }
}

/// What a lens is pinned to (design §1.3): on Auto, to a profile, or to All apps only.
public enum ProfilePin: Equatable, Sendable {
    /// Every lens picks the narrowest match (the default).
    case auto
    /// A profile's id: the chain is that profile and All apps, and no condition is asked.
    case profile(String)
    /// All apps only: the chain is All apps and nothing else.
    case allAppsOnly
}

/// One link of a chain (design §1.3): a profile, or the base (All apps).
public enum ChainLink: Equatable, Sendable {
    /// A profile of the chain, narrowest first.
    case profile(AppProfile)
    /// All apps: the base under every chain.
    case allApps

    /// The id of the profile, or `all` for All apps (design §2.2's `from`).
    public var id: String {
        switch self {
        case .profile(let p): return p.id
        case .allApps: return AppProfile.allAppsID
        }
    }

    /// The name of the profile, or "All apps".
    public var name: String {
        switch self {
        case .profile(let p): return p.name
        case .allApps: return "All apps"
        }
    }

    /// The profile, or nil for All apps.
    public var profile: AppProfile? {
        if case .profile(let p) = self { return p }
        return nil
    }
}

/// One row of the global glossary (All apps' terms, design §2.1's last rule).
public struct GlossaryPair: Equatable, Sendable {
    public var src: String
    public var dst: String

    public init(src: String, dst: String) {
        self.src = src
        self.dst = dst
    }
}

/// All apps: what the chain falls back to (design §1.1, §2.1). It is not a profile and cannot be removed.
public struct ChainBase: Equatable, Sendable {
    /// All apps' language pair. Its `customEngineID` is not read: the engine of the chain is `engine` (the chain's
    /// engine may also be "apple", which a `UUID?` cannot say).
    public var pair: LanguageChoice
    /// All apps' engine; nil keeps Apple's translation.
    public var engine: ProfileEngine?
    /// All apps' paragraph reader.
    public var reader: ParagraphReader?
    /// All apps' amount (design §1.4's default is `memory`).
    public var amount: ContextAmount
    /// All apps' "learn names and terms" switch.
    public var learn: Bool
    /// All apps' glossary: the terms every profile's request may use.
    public var glossary: [GlossaryPair]
    /// The engines that exist. An engine that is not among them is gone, and a profile's choice of it is skipped.
    public var knownEngines: Set<UUID>
    /// The app in front (the lens's app): the key the learned rows keep when All apps is the head (design §2.1).
    public var bundleID: String?

    public init(pair: LanguageChoice = LanguageChoice(source: "auto", target: "en", customEngineID: nil),
                engine: ProfileEngine? = nil, reader: ParagraphReader? = nil, amount: ContextAmount = .memory,
                learn: Bool = false, glossary: [GlossaryPair] = [], knownEngines: Set<UUID> = [], bundleID: String? = nil) {
        self.pair = pair
        self.engine = engine
        self.reader = reader
        self.amount = amount
        self.learn = learn
        self.glossary = glossary
        self.knownEngines = knownEngines
        self.bundleID = bundleID
    }
}

/// A row of the chain's names and terms, with where it came from (design §2.2).
public struct MergedRow: Equatable, Sendable {
    /// The row that goes.
    public var entry: MemoryEntry
    /// A profile's id, `all`, or `learned:<id>` (design §2.2).
    public var from: String
    /// The broader rows this one hides: they are not sent and not put in, only remembered here.
    public var shadows: [ShadowedRow]
}

/// A row a narrower one hid (design §2.2).
public struct ShadowedRow: Equatable, Sendable {
    /// Where the hidden row came from.
    public var from: String
    /// The hidden row.
    public var entry: MemoryEntry
}

/// The chain of a lens, merged (design §1.3, §2.1).
public struct MergedChain: Equatable, Sendable {
    /// The chain, narrowest first, All apps last.
    public var links: [ChainLink]
    /// The chain's first profile: the one that decides the pair and the learned rows' key.
    public var head: ChainLink
    /// The pair of the head (a profile always has one), or All apps' pair.
    public var pair: LanguageChoice
    /// The engine the chain uses: the narrowest profile that sets one, else All apps'; a gone engine is skipped.
    public var engine: ProfileEngine?
    /// The paragraph reader the chain uses.
    public var reader: ParagraphReader?
    /// The amount the chain sends.
    public var amount: ContextAmount
    /// Whether the names this request sees are learned and kept.
    public var learn: Bool
    /// The notes of the chain, broad to narrow, at most `AppProfile.maxNoteLength` characters together.
    public var note: String
    /// The names and terms the chain sends, narrowest first, with their provenance.
    public var rows: [MergedRow]
    /// All apps' glossary: the terms every request may use.
    public var glossary: [GlossaryPair]
    /// The key the learned rows are kept under: the head's id, or the bundle ID when All apps is the head.
    public var learnedKey: String?

    /// The chain has something to send as memory: a note, or a row of the user's.
    public var hasMemory: Bool {
        !note.isEmpty || rows.contains { $0.entry.origin == .user }
    }
}

/// The chain of a lens and what it sends (design §1.3, §2.1, §2.2).
public enum ProfileChain {
    /// The chain of the lens over `window` (design §1.3).
    ///
    /// - **Auto**: every profile with a condition that matches the window, narrowest first (app and title 3, title 2,
    ///   app 1; a tie goes to the longer phrase, then to the earlier profile in the list), then All apps.
    /// - **Pinned**: the pinned profile and All apps; no condition is asked. A pin to a profile that is gone falls back
    ///   to Auto.
    /// - **All apps only**: All apps and nothing else.
    public static func chain(for window: WindowFacts, profiles: [AppProfile], pin: ProfilePin) -> [ChainLink] {
        switch pin {
        case .allAppsOnly:
            return [.allApps]
        case .profile(let id):
            guard let p = profiles.first(where: { $0.id == id }) else { return auto(window, profiles) }
            return [.profile(p), .allApps]
        case .auto:
            return auto(window, profiles)
        }
    }

    /// The matching profiles, narrowest first, then All apps (design §1.3).
    private static func auto(_ window: WindowFacts, _ profiles: [AppProfile]) -> [ChainLink] {
        var matches: [(profile: AppProfile, narrowness: Int, phrase: Int, order: Int)] = []
        for (order, p) in profiles.enumerated() {
            // The narrowest condition of the profile that matches the window decides where the profile stands.
            var best: (narrowness: Int, phrase: Int)?
            for c in p.when where c.matches(app: window.bundleID, title: window.title) {
                let here = (c.narrowness, c.phraseLength)
                if best == nil || here.0 > best!.narrowness || (here.0 == best!.narrowness && here.1 > best!.phrase) {
                    best = here
                }
            }
            guard let b = best else { continue }
            matches.append((p, b.narrowness, b.phrase, order))
        }
        matches.sort { a, b in
            if a.narrowness != b.narrowness { return a.narrowness > b.narrowness }
            if a.phrase != b.phrase { return a.phrase > b.phrase }
            return a.order < b.order
        }
        return matches.map { .profile($0.profile) } + [.allApps]
    }

    /// The chain merged into what one request is built with (design §2.1, §2.2).
    ///
    /// - The single-valued fields (pair, engine, reader, amount, learn): the narrowest profile of the chain that sets
    ///   it, else All apps. A gone engine is skipped.
    /// - The names and terms: per folded `src` the narrowest user row wins; the broader row is neither sent nor put in,
    ///   only remembered as a shadow. A learned row whose `src` is a user row anywhere in the chain is not sent.
    /// - The notes: broad to narrow, a blank line between, at most `AppProfile.maxNoteLength` characters together; over
    ///   that, whole notes are dropped, broadest first. The head's note is never cut.
    /// - The glossary: All apps' terms, unchanged.
    public static func merge(_ chain: [ChainLink], base: ChainBase, learned: [MemoryEntry] = []) -> MergedChain {
        let links = chain.isEmpty ? [ChainLink.allApps] : chain
        let head = links[0]
        let profiles = links.compactMap(\.profile)

        // The single-valued fields: the narrowest that sets them, else All apps.
        let engine = resolveEngine(profiles, base)
        let pairSource: String
        let pairTarget: String
        switch head {
        case .profile(let p):
            pairSource = p.source
            pairTarget = p.target
        case .allApps:
            pairSource = base.pair.source
            pairTarget = base.pair.target
        }
        let pair = LanguageChoice(source: pairSource, target: pairTarget, customEngineID: engine?.id)
        let reader = profiles.compactMap(\.paragraphReader).first ?? base.reader
        let amount = profiles.compactMap { $0.context.map { ContextAmount($0) } }.first ?? base.amount
        let learn = profiles.compactMap(\.useLearned).first ?? base.learn

        // The names and terms (design §2.1's second rule).
        var order: [String] = []
        var rows: [String: MergedRow] = [:]
        for p in profiles {
            for e in p.entries where e.origin == .user {
                let key = e.id
                if var row = rows[key] {
                    row.shadows.append(ShadowedRow(from: p.id, entry: e))
                    rows[key] = row
                } else {
                    rows[key] = MergedRow(entry: e, from: p.id, shadows: [])
                    order.append(key)
                }
            }
        }
        // The learned rows are kept under the head (design §2.1's third rule).
        let learnedKey: String? = {
            switch head {
            case .profile(let p): return p.id
            case .allApps: return base.bundleID
            }
        }()
        for e in learned where e.origin == .learned {
            let key = e.id
            guard rows[key] == nil else { continue }   // a user row anywhere in the chain wins
            rows[key] = MergedRow(entry: e, from: "learned:\(learnedKey ?? AppProfile.allAppsID)", shadows: [])
            order.append(key)
        }

        // The notes: broad to narrow, a blank line between, and the head's note is never cut.
        let note = mergeNote(profiles)

        let out = MergedChain(links: links, head: head, pair: pair, engine: engine, reader: reader, amount: amount,
                              learn: learn, note: note, rows: order.compactMap { rows[$0] }, glossary: base.glossary,
                              learnedKey: learnedKey)
        return out
    }

    /// The engine of the chain: the narrowest profile that sets one and whose engine is still there, else All apps'.
    /// A gone engine is skipped (design §2.1).
    private static func resolveEngine(_ profiles: [AppProfile], _ base: ChainBase) -> ProfileEngine? {
        for p in profiles {
            guard let e = p.engine else { continue }
            if case .added(let id) = e, !base.knownEngines.contains(id) { continue }
            return e
        }
        if let e = base.engine, case .added(let id) = e, !base.knownEngines.contains(id) { return nil }
        return base.engine
    }

    /// The notes of the chain (design §2.1's fourth rule): broad to narrow, a blank line between, at most
    /// `AppProfile.maxNoteLength` characters together; over that, whole notes are dropped, broadest first.
    private static func mergeNote(_ profiles: [AppProfile]) -> String {
        // The chain is narrowest first; the notes go broad to narrow, and the head's note is last (never cut).
        let notes = profiles.reversed().compactMap { $0.note.isEmpty ? nil : $0.note }
        var kept = notes
        var text = kept.joined(separator: "\n\n")
        while text.count > AppProfile.maxNoteLength && kept.count > 1 {
            kept.removeFirst()
            text = kept.joined(separator: "\n\n")
        }
        return text
    }
}

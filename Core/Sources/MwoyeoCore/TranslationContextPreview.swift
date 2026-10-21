import Foundation

// What a request will carry, before any request exists (design §3 "Sent: …"): the engine sheet shows it for a sample, the
// Memory sheet for one app. Pure data; nothing here reads a note's or a line's text beyond "is there one".

/// The fields behind the one-line "Sent: …" preview. The sheets build their own localized line from the fields; `text` is the
/// English line (check-logic and the tests use it).
public struct SentSummary: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        /// Only the lines to translate: context is off for this engine and app, or the engine takes none (Apple Translation, a
        /// template, a command).
        case linesOnly
        /// The card, the note and the matching rows, and nothing else (`ContextOptions.memoryOnly`).
        case memoryOnly
        /// The card, the note and rows, and the lines around the text on screen.
        case context
    }

    public var mode: Mode
    /// The engine's name; nil is Apple Translation.
    public var engineName: String?
    /// The card goes: the app's name and its category word.
    public var appName: String?
    public var domain: String?
    /// The window title may go (the engine runs on this Mac, or the user opted in) and the mode sends the window at all.
    public var windowTitle: Bool
    public var hasNote: Bool
    /// At most this many name rows of the app go; only those whose source stands in the text do.
    public var names: Int
    /// The pairs of the global glossary that go along with every request (the app's own rows replace theirs). With `names` they are the
    /// names of the line, and the line says which scope each count is of (design names-and-context §3.3).
    public var allApps: Int
    /// At most this many lines before / after the text go.
    public var linesBefore: Int
    public var linesAfter: Int
    /// Rows the engine learned join the names.
    public var learned: Bool

    public init(mode: Mode, engineName: String? = nil, appName: String? = nil, domain: String? = nil, windowTitle: Bool = false,
                hasNote: Bool = false, names: Int = 0, allApps: Int = 0, linesBefore: Int = 0, linesAfter: Int = 0, learned: Bool = false) {
        self.mode = mode
        self.engineName = engineName
        self.appName = appName
        self.domain = domain
        self.windowTitle = windowTitle
        self.hasNote = hasNote
        self.names = names
        self.allApps = allApps
        self.linesBefore = linesBefore
        self.linesAfter = linesAfter
        self.learned = learned
    }

    /// `Sent: Example Chat · social · window title · note · up to 3 names (2 this app, 1 all apps) · 2 lines before · 2 lines after`, or
    /// `Sent: lines only`. A scope with no names is left out; the rows the engine learned count with the app's (`learned too`).
    public var namesText: String? {
        let total = names + allApps
        guard total > 0 else { return nil }
        var scopes: [String] = []
        if names > 0 { scopes.append("\(names) this app" + (learned ? ", learned too" : "")) }
        if allApps > 0 { scopes.append("\(allApps) all apps") }
        return "up to \(total) \(total == 1 ? "name" : "names") (\(scopes.joined(separator: ", ")))"
    }

    /// The English line (see `namesText`).
    public var text: String {
        var parts: [String] = []
        if let appName {
            parts.append(domain.map { "\(appName) · \($0)" } ?? appName)
        }
        if windowTitle { parts.append("window title") }
        if hasNote { parts.append("note") }
        if let namesText { parts.append(namesText) }
        if linesBefore > 0 { parts.append("\(linesBefore) \(linesBefore == 1 ? "line" : "lines") before") }
        if linesAfter > 0 { parts.append("\(linesAfter) \(linesAfter == 1 ? "line" : "lines") after") }
        return "Sent: " + (parts.isEmpty ? "lines only" : parts.joined(separator: " · "))
    }
}

extension RequestLayout {
    /// What `body(kind:request:options:)` would carry for an app with this card, note and rows, as fields (design §3).
    ///
    /// - `rows`: the sheet's rows (the user's, and the usable learned ones when `options.includeLearned`); the count is how many
    ///   of them fit the engine's row budget if every one of them occurred in the text.
    /// - `glossary`: the global glossary's pairs. Only the pairs that occur go (design §3), as hint rows of the same cap as the app's
    ///   own, minus those an included user row replaces (`hintRows`); they count as the names "of all apps". The preview has no text, so
    ///   like the app's rows they count as if every one occurred, within the one row cap and token budget they share.
    /// - `glossaryApply`: how the glossary is used (design §10). `replace` writes the pairs into the text and tells the engine nothing,
    ///   so none count.
    /// - An engine that takes no context (`kind.tier == nil`), or options that are Off, are `linesOnly`: the card, the note and
    ///   the rows do not go either.
    public static func sentSummary(options: ContextOptions, kind: LayoutKind, engineName: String? = nil, appName: String?,
                                   domain: String? = nil, note: String = "", rows: [MemoryEntry] = [],
                                   glossary: [(String, String)] = [], glossaryApply: EntryApply = .hint) -> SentSummary {
        guard options.enabled, let tier = kind.tier else { return SentSummary(mode: .linesOnly, engineName: engineName) }
        let budget = ContextBudget.for(tier)
        let memoryOnly = options.memoryOnly
        var s = SentSummary(mode: memoryOnly ? .memoryOnly : .context, engineName: engineName)
        if options.includeCard, let appName, !appName.isEmpty {
            s.appName = ContextText.collapse(appName)
            s.domain = domain
            s.windowTitle = !memoryOnly && ContextPrivacy.includesTitle(onDevice: kind.isOnDevice, optedIn: options.includeTitle)
        }
        if kind.sendsMemory(options) {
            s.hasNote = !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let candidates = rows.filter { e in
                switch e.origin {
                case .user: options.includeUser
                case .learned: options.includeLearned && !memoryOnly
                }
            }.filter { !$0.src.isEmpty && !$0.dst.isEmpty }
            let replaced = options.includeUser ? Set(rows.filter { $0.origin == .user }.map(\.id)) : []
            let pairs = glossaryApply == .replace ? [] : glossary.filter { !replaced.contains(ContextText.foldedKey($0.0)) }
                .map { MemoryEntry(src: $0.0, dst: $0.1, kind: .term, origin: .user) }
            let own = Set(candidates.map(\.id))
            let picked = selectRows(candidates + pairs, items: (candidates + pairs).map(\.src), surrounding: [], budget: budget, format: options.format)
            s.names = picked.filter { own.contains($0.id) }.count
            s.allApps = picked.count - s.names
            s.learned = options.includeLearned && !memoryOnly && candidates.contains { $0.origin == .learned }
        }
        if !memoryOnly {
            let cap = options.longTranscript ? budget.maxTranscript : min(ContextOptions.shortTranscript, budget.maxTranscript)
            let count = min(options.transcriptCount ?? budget.defaultTranscript, cap)
            // No earlier lines is "nearby": the lines right above the text on screen go instead.
            s.linesBefore = count == 0 ? budget.afterLines : count
            s.linesAfter = budget.afterLines
        }
        return s
    }
}

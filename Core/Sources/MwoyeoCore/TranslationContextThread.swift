import Foundation

// Threads and resets (design §2, §8.3, §8.4). A thread is one lens on one document of one app, in one language pair
// on one engine. It holds a short transcript and the referents; it holds no learned entries (those are per app).

public struct LanguagePair: Hashable, Sendable {
    public var source: String
    public var target: String

    public init(_ source: String, _ target: String) {
        self.source = source
        self.target = target
    }
}

/// The key of a thread: app, confirmed normalised title, lens, pair, engine.
public struct ThreadKey: Hashable, Sendable {
    public var bundleID: String
    /// The confirmed, normalised window title; "" for none.
    public var title: String
    /// The lens (region) this thread reads for; "" when the app has one reading place.
    public var lens: String
    public var pair: LanguagePair
    public var engineID: String

    public init(bundleID: String, title: String, lens: String = "", pair: LanguagePair, engineID: String) {
        self.bundleID = bundleID
        self.title = title
        self.lens = lens
        self.pair = pair
        self.engineID = engineID
    }

    /// The id sent as `prompt_cache_key`: a hash, so the bundle id and the window title never leave the Mac through it.
    /// Stable across runs.
    public var cacheKey: String {
        let canonical = [bundleID, title, lens, pair.source, pair.target, engineID].joined(separator: "\u{1F}")
        return "mwoyeo-" + ContextText.stableHash(canonical)
    }
}

/// Why a thread starts over (design §2 and §8.4).
public enum ResetReason: String, Equatable, Sendable, CaseIterable {
    case userReset, appSwitch, titleChange, lensChange, pairChange, engineChange, idle, wholesaleChange

    /// A change of the key: the store resumes or starts the thread of the new key. The old thread is kept (§8.4).
    public var isKeyChange: Bool {
        switch self {
        case .appSwitch, .titleChange, .lensChange, .pairChange, .engineChange: true
        case .userReset, .idle, .wholesaleChange: false
        }
    }

    /// Referents die with a title or app change and with "Start fresh", never with idle (§8.3).
    public var clearsReferents: Bool {
        switch self {
        case .userReset, .appSwitch, .titleChange: true
        default: false
        }
    }
}

/// What `ThreadStore` reads on each reading pass. Pure data, so the rules can be tested without a clock or a window.
public struct ThreadSignals: Equatable, Sendable {
    /// Idle time at which a thread's transcript is cleared (5 min).
    public static let idleLimit: TimeInterval = 300
    /// A screen that shares fewer than this share of its lines with the last one is a different text.
    public static let wholesaleRatio = 0.2

    public var bundleID: String
    /// The confirmed normalised title (`TitleConfirmer.confirmed`); nil is the same as "".
    public var confirmedTitle: String?
    public var lensID: String
    public var pair: LanguagePair
    public var engineID: String
    public var idleSeconds: TimeInterval
    /// Share of this screen's lines that were on the previous screen; nil when unknown (`sharedLineRatio`).
    public var sharedLineRatio: Double?
    public var userReset: Bool

    public init(bundleID: String, confirmedTitle: String?, lensID: String = "", pair: LanguagePair, engineID: String,
                idleSeconds: TimeInterval = 0, sharedLineRatio: Double? = nil, userReset: Bool = false) {
        self.bundleID = bundleID
        self.confirmedTitle = confirmedTitle
        self.lensID = lensID
        self.pair = pair
        self.engineID = engineID
        self.idleSeconds = idleSeconds
        self.sharedLineRatio = sharedLineRatio
        self.userReset = userReset
    }

    public var key: ThreadKey {
        ThreadKey(bundleID: bundleID, title: confirmedTitle ?? "", lens: lensID, pair: pair, engineID: engineID)
    }

    /// The reset these signals ask for against the thread `previous`, or nil. One reason, by priority:
    /// user reset, app switch, title change, lens change, pair change, engine change, idle ≥ 5 min,
    /// a wholesale text change (< 20 % shared lines).
    public func resetReason(against previous: ThreadKey?) -> ResetReason? {
        guard let previous else { return nil }
        let now = key
        if userReset { return .userReset }
        if now.bundleID != previous.bundleID { return .appSwitch }
        if now.title != previous.title { return .titleChange }
        if now.lens != previous.lens { return .lensChange }
        if now.pair != previous.pair { return .pairChange }
        if now.engineID != previous.engineID { return .engineChange }
        if idleSeconds >= Self.idleLimit { return .idle }
        if let r = sharedLineRatio, r < Self.wholesaleRatio { return .wholesaleChange }
        return nil
    }

    /// The share of `current` lines that also stood in `previous`; nil when either is empty.
    public static func sharedLineRatio(previous: [String], current: [String]) -> Double? {
        let cur = current.map(ContextText.collapse).filter { !$0.isEmpty }
        guard !previous.isEmpty, !cur.isEmpty else { return nil }
        let prev = Set(previous.map(ContextText.collapse))
        return Double(cur.filter { prev.contains($0) }.count) / Double(cur.count)
    }
}

public struct TranscriptLine: Equatable, Sendable {
    public var source: String
    public var translation: String?
    /// The caller trusts this translation (it passed its checks). Whether a translation goes in the prompt is
    /// `ContextOptions.trusted`.
    public var trusted: Bool

    public init(source: String, translation: String? = nil, trusted: Bool = false) {
        self.source = source
        self.translation = translation
        self.trusted = trusted
    }
}

public struct ContextThread: Equatable, Sendable {
    /// Lines kept per thread; the prompt takes the last `ContextOptions.transcriptCount` of them.
    public static let maxLines = 8

    public let key: ThreadKey
    public private(set) var transcript: [TranscriptLine] = []
    public var referents: [Referent] = []
    /// Counts "Start fresh". Part of the translation-memory namespace (§8.1).
    public private(set) var generation = 0
    public var lastActive: TimeInterval

    public init(key: ThreadKey, now: TimeInterval = 0) {
        self.key = key
        self.lastActive = now
    }

    /// Adds an observed line (not only lines that went to the engine: memory hits count too, §8.1).
    /// A line already in the transcript is not added again; it only gains its translation.
    public mutating func append(source: String, translation: String? = nil, trusted: Bool = false) {
        let s = ContextText.collapse(source)
        guard !s.isEmpty else { return }
        if let i = transcript.firstIndex(where: { $0.source == s }) {
            if let translation, transcript[i].translation == nil {
                transcript[i].translation = translation
                transcript[i].trusted = trusted
            }
            return
        }
        transcript.append(TranscriptLine(source: s, translation: translation, trusted: trusted))
        if transcript.count > Self.maxLines { transcript.removeFirst(transcript.count - Self.maxLines) }
    }

    public mutating func clearTranscript() { transcript.removeAll() }

    public mutating func setReferents(_ list: [Referent]) {
        referents = Array(list.filter { !$0.isEmpty }.prefix(Referent.maxCount))
    }

    /// Applies a reset that does not change the key: the transcript always goes; referents only by
    /// `ResetReason.clearsReferents`; "Start fresh" also bumps the generation.
    public mutating func apply(_ reason: ResetReason) {
        transcript.removeAll()
        if reason.clearsReferents { referents.removeAll() }
        if reason == .userReset { generation += 1 }
    }

    /// The previous lines for a request: the last `count` of the transcript without any line that is itself being translated.
    public func contextLines(count: Int, excluding items: [String] = []) -> [ContextLine] {
        guard count > 0 else { return [] }
        let skip = Set(items.map(ContextText.collapse))
        return transcript.filter { !skip.contains($0.source) }.suffix(count)
            .map { ContextLine(source: $0.source, translation: $0.translation, trusted: $0.trusted) }
    }

    /// What the translation-memory namespace adds besides the thread key (§8.1): the app note, the user entries,
    /// the referents and the "Start fresh" generation. The transcript and learned hints stay out on purpose:
    /// they are non-binding, and including them would end all reuse.
    public func namespaceFingerprint(memory: ContextMemory) -> String {
        ["gen=\(generation)", memory.memoryFingerprint, referents.map(\.rendered).joined(separator: "\u{1F}")]
            .joined(separator: "\u{1E}")
    }
}

/// The threads of the running app (RAM only), at most 8 per app (§8.4).
public struct ThreadStore: Equatable, Sendable {
    public static let maxPerApp = 8
    /// A kept thread idle this long loses its transcript; one with nothing left to lose is dropped.
    public static let expiry: TimeInterval = ThreadSignals.idleLimit

    public struct Step: Equatable, Sendable {
        public var key: ThreadKey
        /// The reset the signals asked for, or nil.
        public var reason: ResetReason?
        /// The thread already existed (tabs A → B → A resume).
        public var resumed: Bool
    }

    public private(set) var threads: [ThreadKey: ContextThread] = [:]
    public private(set) var currentKey: ThreadKey?

    public init() {}

    public func thread(_ key: ThreadKey) -> ContextThread? { threads[key] }
    public var current: ContextThread? { currentKey.flatMap { threads[$0] } }

    /// Edits one thread (append lines, set referents). A key that is not in the store is ignored.
    public mutating func update(_ key: ThreadKey, now: TimeInterval? = nil, _ body: (inout ContextThread) -> Void) {
        guard var t = threads[key] else { return }
        body(&t)
        if let now { t.lastActive = now }
        threads[key] = t
    }

    /// One reading pass: finds, resumes or starts the thread of these signals and applies the reset they ask for.
    @discardableResult
    public mutating func step(_ signals: ThreadSignals, now: TimeInterval) -> Step {
        let key = signals.key
        let reason = signals.resetReason(against: currentKey)
        let previous = current
        var thread: ContextThread
        let resumed = threads[key] != nil
        if let kept = threads[key] {
            thread = kept
            // A kept thread that sat idle for 5 min lost its transcript while it was away.
            if reason?.isKeyChange == true, now - thread.lastActive >= Self.expiry { thread.clearTranscript() }
        } else {
            thread = ContextThread(key: key, now: now)
            // A pair, engine or lens change is a key change but not a change of document: the referents go along (§8.3).
            if let previous, previous.key.bundleID == key.bundleID, previous.key.title == key.title, reason != .userReset {
                thread.referents = previous.referents
            }
        }
        if let reason, !reason.isKeyChange { thread.apply(reason) }
        thread.lastActive = now
        threads[key] = thread
        currentKey = key
        prune(keeping: key, now: now)
        return Step(key: key, reason: reason, resumed: resumed)
    }

    private mutating func prune(keeping current: ThreadKey, now: TimeInterval) {
        // Empty husks that sat idle: nothing to lose.
        for (k, t) in threads where k != current && t.transcript.isEmpty && t.referents.isEmpty && now - t.lastActive >= Self.expiry {
            threads[k] = nil
        }
        // At most 8 per app: the least recently active one goes.
        let mine = threads.values.filter { $0.key.bundleID == current.bundleID }
        if mine.count > Self.maxPerApp {
            let victims = mine.filter { $0.key != current }.sorted { $0.lastActive < $1.lastActive }.prefix(mine.count - Self.maxPerApp)
            for v in victims { threads[v.key] = nil }
        }
    }

    /// "Start fresh" for the current thread without waiting for the next pass.
    public mutating func startFresh() {
        guard let key = currentKey else { return }
        update(key) { $0.apply(.userReset) }
    }
}

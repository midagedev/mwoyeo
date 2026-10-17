import Foundation

/// Whether the Swift Vision text models (`RecognizeTextRequest`, `RecognizeDocumentsRequest`) may be asked in the app
/// process. A pending Swift request that is still loading its model blocks every accurate `VNRecognizeTextRequest` in the
/// same process (measured on macOS 27: more than 60 s, while the same request in another process answers in 0.3 s), so
/// the app asks them only once a child process has loaded them: the compile is cached, and afterwards the in-process load
/// is quick. The models are loaded per language (measured in a fresh binary: Japanese 34 s, French 32 s,
/// Arabic 40 s, Korean 8 s, and Spanish after French 0.1 s), so readiness is per *key*: the requested languages ("ja",
/// "zh-Hans", "ja,en"), or `anyLanguage` when the language is detected. This is the bookkeeping: which key to load next,
/// when, and which are loaded. One child runs at a time (the compiler service takes one compile at a time, and a child is
/// never killed). Pure: callers pass `now` (any monotonic clock, in seconds), start the process and report how it ended.
public struct SwiftVisionGate: Sendable, Equatable {
    /// A key whose child did not succeed is started again no sooner than this after its last start.
    public static let retryEvery: TimeInterval = 120
    /// The key of a read that detects the language.
    public static let anyLanguage = "auto"

    private var loaded: Set<String> = []
    private var everyKey = false
    private var wanted: [String] = []
    private var lastStart: [String: TimeInterval] = [:]
    private var firstStart: [String: TimeInterval] = [:]
    /// The key the running child loads, nil if none runs.
    public private(set) var running: String?

    public init() {}

    /// Every key is ready (gates that want the Swift path at once); nothing is started.
    public mutating func assumeReady() { everyKey = true }

    public func isReady(_ key: String) -> Bool { everyKey || loaded.contains(key) }

    /// The keys loaded so far ("*" when every key is assumed ready).
    public var readyKeys: [String] { everyKey ? ["*"] : loaded.sorted() }

    /// Every key asked for so far is ready.
    public var allReady: Bool { wanted.allSatisfy(isReady) }

    /// The key is wanted: it is loaded when its turn comes (keys go in the order they were first asked for).
    public mutating func want(_ key: String) {
        if !wanted.contains(key) { wanted.append(key) }
    }

    /// The key a child should load now, if any: nothing runs (a running child is never stacked on, however long it takes),
    /// and the first wanted key that is not ready and was last started at least `retryEvery` ago (or never).
    public func nextDue(now: TimeInterval) -> String? {
        guard running == nil else { return nil }
        return wanted.first { key in
            !isReady(key) && (lastStart[key].map { now - $0 >= Self.retryEvery } ?? true)
        }
    }

    /// A child is being started for `key`. Call before the process runs: it can end before the caller has seen it return.
    public mutating func started(_ key: String, now: TimeInterval) {
        running = key
        lastStart[key] = now
        if firstStart[key] == nil { firstStart[key] = now }
    }

    /// The child ended (or could not start). Returns the key if this made it ready.
    @discardableResult
    public mutating func ended(success: Bool) -> String? {
        defer { running = nil }
        guard success, let key = running, loaded.insert(key).inserted else { return nil }
        return key
    }

    /// How long `key` has been waited for, since its first start; nil once ready, or before any start.
    public func waiting(_ key: String, now: TimeInterval) -> TimeInterval? {
        isReady(key) ? nil : firstStart[key].map { now - $0 }
    }
}

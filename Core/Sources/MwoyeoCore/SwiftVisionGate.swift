import Foundation

/// The initialization of the text models, and whether the Swift Vision models (`RecognizeDocumentsRequest`,
/// `RecognizeTextRequest`) may be asked for a language key. Measured on macOS 27 (vision-revive, 2026-10-18): the block that was
/// once blamed on "a pending Swift request" is a cold ANE compile. Warm, in one process, 30 looped document requests beside 10
/// concurrent `VNRecognizeTextRequest` reads left those reads at 0.16-0.27 s, and a warm document read takes 0.3-0.5 s. Cold (the
/// first run of a binary, or of a language) VN revision 3 takes 65-119 s, the document model 80-90 s, and the compiles queue in
/// the system service; while a Swift model is compiling, a VN revision 3 read in the same process waits for it (37 s with VN warm
/// and a cold Arabic text model), and revision 2 and `.fast` still answer in under 0.25 s. The models are loaded per
/// language (ja 34 s, fr 32 s, ar 40 s, ko 8 s, es after fr 0.1 s), so readiness is per *key*: the requested languages ("ja",
/// "zh-Hans", "ja,en"), or `anyLanguage` when the language is detected.
///
/// The app loads them itself, in the background, at every launch: per key, the steps in `Step` order, one at a time (the compiler
/// service takes one compile at a time, and a load is never cancelled). This is the bookkeeping: which step is due, how each
/// ended, which keys the Swift models may be asked for, and whether a progress screen should be up. Nothing is persisted: a key is
/// ready when its step ran in this process, and the timing of that step is what shows whether the compile was cold.
/// Pure: callers pass `now` (any monotonic clock, in seconds), run the step and report how it ended.
public struct SwiftVisionGate: Sendable, Equatable {
    public enum Step: String, CaseIterable, Sendable {
        /// `VNRecognizeTextRequest`, revision 3, on one drawn wide line.
        case textModel
        /// `RecognizeDocumentsRequest`: the paragraph blocks of a read come from it.
        case documentModel
        /// `RecognizeTextRequest`.
        case swiftTextModel
    }

    public enum StepState: Sendable, Equatable {
        case pending
        case running(since: TimeInterval)
        case done(seconds: TimeInterval)
        case failed(String)
    }

    /// A step of a key that is due, running, or reported.
    public struct Due: Sendable, Equatable {
        public var key: String
        public var step: Step
    }

    /// The key of a read that detects the language.
    public static let anyLanguage = "auto"
    /// The progress screen shows once a step has run this long (or failed), and stays this long after the last step is done.
    public static let showAfter: TimeInterval = 2

    private var everyKey = false
    private var wanted: [String] = []
    private var states: [String: [Step: StepState]] = [:]
    private var lastDone: TimeInterval?
    /// The step that runs, nil if none.
    public private(set) var running: Due?

    public init() {}

    /// Every key is ready (gates that want the Swift path at once); nothing is started.
    public mutating func assumeReady() { everyKey = true }

    /// The Swift document model may be asked for this key.
    public func isReady(_ key: String) -> Bool {
        everyKey || states[key]?[.documentModel].map { if case .done = $0 { true } else { false } } ?? false
    }

    /// The keys whose document model is loaded ("*" when every key is assumed ready).
    public var readyKeys: [String] { everyKey ? ["*"] : wanted.filter(isReady).sorted() }

    /// Every key asked for so far is ready.
    public var allReady: Bool { wanted.allSatisfy(isReady) }

    /// The key is wanted: its steps run when their turn comes (keys go in the order they were first asked for). True if it was
    /// not wanted before.
    @discardableResult
    public mutating func want(_ key: String) -> Bool {
        guard !wanted.contains(key) else { return false }
        wanted.append(key)
        states[key] = Dictionary(uniqueKeysWithValues: Step.allCases.map { ($0, StepState.pending) })
        return true
    }

    /// A Swift step (a model that may be compiling) runs now. VN revision 3 reads in the same process wait for it, so a read
    /// that has an older recognizer for its language goes there meanwhile.
    public var isSwiftCompiling: Bool { running.map { $0.step != .textModel } ?? false }

    /// The step to run now, if any: nothing runs (a running step is never stacked on, however long it takes), and the first
    /// pending step of the first key whose earlier steps are done. A key with a failed step waits for `retry()`.
    public func nextDue() -> Due? {
        guard running == nil else { return nil }
        for key in wanted {
            for step in Step.allCases {
                switch states[key]?[step] ?? .pending {
                case .done: continue
                case .pending: return Due(key: key, step: step)
                case .running, .failed: break
                }
                break
            }
        }
        return nil
    }

    /// The step is being started. Call before the work runs: it can end before the caller has seen it return.
    public mutating func started(_ due: Due, now: TimeInterval) {
        running = due
        states[due.key]?[due.step] = .running(since: now)
    }

    /// The running step ended; `failure` is why it did not succeed. A report with nothing running changes nothing.
    public mutating func finished(failure: String?, now: TimeInterval) {
        guard let due = running else { return }
        running = nil
        if let failure {
            states[due.key]?[due.step] = .failed(failure)
        } else if case let .running(since) = states[due.key]?[due.step] {
            states[due.key]?[due.step] = .done(seconds: max(0, now - since))
            if allDone { lastDone = now }
        }
    }

    /// A document read for a ready key missed its deadline: the key is not ready until a retry (the next launch or `retry()`
    /// loads it again). The abandoned request is not cancelled.
    public mutating func missed(_ key: String) {
        guard !everyKey, case .done = states[key]?[.documentModel] else { return }
        states[key]?[.documentModel] = .failed("no answer in time")
        lastDone = nil
    }

    /// Every failed step is due again (the user pressed retry). Never called by the procedure itself.
    public mutating func retry() {
        for key in wanted {
            for (step, state) in states[key] ?? [:] { if case .failed = state { states[key]?[step] = .pending } }
        }
    }

    /// Where each step stands across the keys asked for: running if one runs (the earliest start), else failed if one failed
    /// (its message), else done (the seconds added) when every key's is, else pending.
    public var steps: [Step: StepState] {
        Dictionary(uniqueKeysWithValues: Step.allCases.map { step in
            let all = wanted.compactMap { states[$0]?[step] }
            var since: TimeInterval?
            var failure: String?
            var seconds: TimeInterval = 0
            var done = 0
            for state in all {
                switch state {
                case let .running(s): since = min(since ?? s, s)
                case let .failed(m): failure = failure ?? m
                case let .done(d): seconds += d; done += 1
                case .pending: break
                }
            }
            if let since { return (step, .running(since: since)) }
            if let failure { return (step, .failed(failure)) }
            return (step, !all.isEmpty && done == all.count ? .done(seconds: seconds) : .pending)
        })
    }

    private var allDone: Bool {
        !wanted.isEmpty && wanted.allSatisfy { key in Step.allCases.allSatisfy { if case .done = states[key]?[$0] { true } else { false } } }
    }

    /// The progress screen is up: some step has run longer than `showAfter` or failed, and, once everything is done, for
    /// `showAfter` more (so that it does not blink away), but only if it was shown, that is some step took longer than that.
    public func shouldShowProgress(now: TimeInterval) -> Bool {
        var slow = false
        for key in wanted {
            for state in states[key]?.values.map({ $0 }) ?? [] {
                switch state {
                case .failed: return true
                case let .running(since): if now - since > Self.showAfter { return true }
                case let .done(seconds): if seconds > Self.showAfter { slow = true }
                case .pending: break
                }
            }
        }
        guard slow, allDone, let lastDone else { return false }
        return now - lastDone < Self.showAfter
    }
}

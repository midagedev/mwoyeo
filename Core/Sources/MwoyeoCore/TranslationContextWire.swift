import Foundation

// The pure helpers the app's request path (`TranslationService`, `RegionPipeline`) leans on to put context into a request
// (design §2, §8.1): who is around a batch on screen, the per-call cache namespace, the per-app usage counter, and the check of
// Apple Translation's answer. Nothing here keeps state, logs or touches the disk.

extension ContextOptions {
    /// Whether any request could carry context: the engine says On, or some app's profile writes a `nearby` or `conversation`
    /// override. The lens reads a window's title (a window-list call) only while this is true, so Off costs nothing.
    ///
    /// An answer of true says "possibly": the effective options of the app under a lens decide (`effective(engine:profile:)`).
    public static func couldBeOn(engine: EngineConfig?, profiles: [AppProfile]) -> Bool {
        if engine?.context?.enabled == true { return true }
        return profiles.contains { $0.context.map { $0.mode != .off } ?? false }
    }
}

/// The lines around a batch on screen, in reading order (design §2 "Neighbours").
public enum ContextNeighbours {
    /// One line the lens has on screen, with where it stands (image pixels or points: only the order matters).
    public struct Line: Equatable, Sendable {
        public var source: String
        public var rect: CGRect

        public init(source: String, rect: CGRect) {
            self.source = source
            self.rect = rect
        }
    }

    /// The lines the lens sees right above the first line of `batch` and right below its last one, nearest last/first, each at most
    /// `limit` long. Lines are put in reading order by their rects (`ReadingOrder`). A line of the batch itself, an empty one and a
    /// repeat of a line already taken are left out; lines standing between the batch's own lines belong to no side.
    /// A batch with no line on screen has no neighbours.
    public static func around(batch: [String], lines: [Line], above: Int = 2, below: Int = 2) -> (above: [String], below: [String]) {
        let inBatch = Set(batch.map(ContextText.collapse))
        let ordered = ReadingOrder.sorted(lines, frame: \.rect).map { ContextText.collapse($0.source) }.filter { !$0.isEmpty }
        guard let first = ordered.firstIndex(where: inBatch.contains), let last = ordered.lastIndex(where: inBatch.contains) else {
            return ([], [])
        }
        func distinct(_ list: [String]) -> [String] {
            var seen = Set<String>()
            return list.filter { !inBatch.contains($0) && seen.insert($0).inserted }
        }
        let before = Array(distinct(Array(ordered[..<first])).suffix(max(0, above)))
        let after = Array(distinct(Array(ordered[(last + 1)...])).prefix(max(0, below)))
        return (before, after)
    }
}

/// The translation-memory namespace of one call under context (design §8.1).
public enum ContextNamespace {
    /// `base` (today's namespace: pair, engine identity, glossary) plus the thread and what the user wrote: the thread key (app,
    /// confirmed title, lens, pair, engine), and `fingerprint` (`ContextThread.namespaceFingerprint`: the "Start fresh"
    /// generation, the note, the user entries and the referents). The transcript and the learned hints stay out on purpose:
    /// they are non-binding, and including them would end all reuse. The parts are hashed, so no title or note lies in a key.
    public static func make(base: String, key: ThreadKey, fingerprint: String) -> String {
        "\(base)|ctx:\(key.cacheKey).\(ContextText.stableHash(fingerprint))"
    }
}

/// What the context path has used for one app, since launch (RAM only; numbers, never text).
public struct ContextUsage: Equatable, Sendable {
    /// Calls to the engine that carried context.
    public private(set) var requests = 0
    /// Token counts from the provider's own `usage`, summed (`TokenUsage.prompt` is the whole input).
    public private(set) var prompt = 0
    public private(set) var completion = 0
    public private(set) var cached = 0
    public private(set) var cacheWrite = 0
    /// Resets applied to this app's threads, by reason (a key change is a switch and counts here too, as the reason it was).
    public private(set) var resets: [ResetReason: Int] = [:]
    /// Terms the learning rule accepted as a first or repeated sighting.
    public private(set) var sightings = 0

    public init() {}

    public mutating func add(_ usage: TokenUsage) {
        requests += 1
        prompt += usage.prompt
        completion += usage.completion
        cached += usage.cached
        cacheWrite += usage.cacheWrite
    }

    public mutating func noteReset(_ reason: ResetReason) { resets[reason, default: 0] += 1 }

    public mutating func noteSightings(_ n: Int) { sightings += n }

    /// The share of input tokens the provider served from its cache; nil before any input was counted.
    public var cachedShare: Double? { prompt > 0 ? Double(cached) / Double(prompt) : nil }
}

extension ApplePreinsertion {
    /// Whether `answer` holds every target that was put into the source: Apple wrote the sentence around the words, and none of
    /// them was dropped. A line whose answer lacks one is asked again as it stood (the caller decides).
    public func answerHoldsTargets(_ answer: String) -> Bool {
        spans.allSatisfy { ContextText.occurs($0.target, in: answer) }
    }
}

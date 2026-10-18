import Foundation
import FoundationModels
import MwoyeoCore
import MwoyeoEngines
import NaturalLanguage
import Translation

/// Something the user can act on (missing language pack, Apple Intelligence off, …).
enum TranslationIssue: Error, Equatable, Sendable {
    case languagePackMissing(source: String, target: String)
    case intelligenceUnavailable(String)
    case unsupportedPair(source: String, target: String)
    case failed(String)
    case timedOut
    /// An added engine failed or timed out and Apple translates meanwhile. `reason` is the engine error's user message.
    case engineUnavailable(name: String, reason: String)
    /// No text recognizer has answered yet for the source language (`language` is its identifier). macOS prepares them
    /// slowly the first time; the notice ends when one answers.
    case textRecognitionStarting(language: String)
    /// None answered for three minutes (some Macs get stuck until restarted).
    case textRecognitionStalled

    /// Raised and ended by `TextRecognizer`, not by a translation.
    var isTextRecognition: Bool {
        switch self {
        case .textRecognitionStarting, .textRecognitionStalled: true
        default: false
        }
    }

    var message: String {
        switch self {
        case let .languagePackMissing(s, t):
            String(localized: "The \(Languages.name(s)) → \(Languages.name(t)) language pack is not installed. Download it in Settings › Translation.")
        case let .intelligenceUnavailable(why): String(localized: "Apple Intelligence is unavailable: \(why)")
        case let .unsupportedPair(s, t): String(localized: "\(Languages.name(s)) → \(Languages.name(t)) translation is not supported.")
        case let .failed(why): String(localized: "Translation failed: \(why)")
        case .timedOut: String(localized: "Translation is taking too long. Trying again shortly.")
        case let .engineUnavailable(name, reason): String(localized: "\(name) unavailable · using Apple") + " — " + reason
        case let .textRecognitionStarting(language):
            String(localized: "macOS is still preparing text recognition for \(Languages.name(language)). This can take a minute.")
        case .textRecognitionStalled: String(localized: "macOS text recognition isn't responding. Restarting the Mac usually fixes it.")
        }
    }

    /// The banner's first line; `detail` is its quieter second line.
    var headline: String {
        if case let .engineUnavailable(name, _) = self { return String(localized: "\(name) unavailable · using Apple") }
        return message
    }

    var detail: String? {
        if case let .engineUnavailable(_, reason) = self { return reason }
        return nil
    }
}

/// What one `translate` call produced, for a pipeline that must decide what to retry.
struct TranslationOutcome: Sendable {
    /// Source → translation for everything that came back (including text that needs none).
    var translations: [String: String] = [:]
    /// Sources not returned while others of the same group were: a strike each, not a reason to pause.
    var failed: Set<String> = []
    /// An engine call hit its deadline.
    var timedOut = false
    /// A group threw, timed out or returned nothing: the engine is in trouble, so the queue should rest.
    var batchFailed = false
    /// The caller cancelled (the pipeline no longer wants the batch): not a failure, so no issue, strike or pause.
    var cancelled = false
}

/// Streamed results, kept even if the call is abandoned at its deadline.
private final class Streamed: @unchecked Sendable {
    private let lock = NSLock()
    private var out: [String: String] = [:]
    func put(_ s: String, _ t: String) { lock.withLock { out[s] = t } }
    var all: [String: String] { lock.withLock { out } }
}

/// Owns every translation engine and the translation cache. Shared by all regions.
///
/// Engines, all on-device:
/// - Apple Translation, low latency — needs the language pack; the fastest.
/// - Apple Translation, high fidelity — Apple Intelligence's translation model; no pack needed, ~1 s a line.
/// - Foundation Models — a prompted LLM, for when the glossary must be followed.
actor TranslationService {
    /// The language pack's fast model, or Apple Intelligence's high-fidelity one (macOS 26.4 and later).
    private enum Strategy { case lowLatency, highFidelity }

    private var settings: AppSettings
    private let cache = Memory()
    private var sessions: [String: TranslationSession] = [:]
    private var pairStatus: [String: LanguageAvailability.Status] = [:]
    private let intelligence = IntelligenceTranslator()
    private var issueHandler: (@Sendable (TranslationIssue?) -> Void)?
    /// The one client for every added engine: one connection pool, one place that remembers rejected request fields.
    private let client: EngineClient
    /// Told when an engine learns (or forgets) request fields its server rejects, so the app can save them with the engine.
    private var rejectionHandler: (@Sendable (UUID, [String]) -> Void)?
    /// Per engine: the fingerprint last seen (a change flushes what it learned) and the fields last reported.
    private var fingerprints: [UUID: String] = [:]
    private var rejectionsReported: [UUID: Set<String>] = [:]
    private var enginesSynced = false
    /// The one store of how fast each engine and language pair is (and how often a line was already in memory): the
    /// scheduler's `expectedSeconds`, the logs' `paceStats` and the engine list's speed line all read it.
    private nonisolated let pace = PaceStats()
    /// Engines that failed, and until when (`ProcessInfo.systemUptime`) groups go straight to Apple.
    private var cooldowns: [UUID: Cooldown] = [:]
    /// The added engine is failing and Apple is standing in: successful Apple groups must not clear its issue.
    private var engineIssue: TranslationIssue?

    private struct Cooldown {
        var backoff = HealthyBackoff()
        var until: TimeInterval = 0
    }

    init(settings: AppSettings, secrets: any SecretStore = KeychainSecrets()) {
        self.settings = settings
        client = EngineClient(secrets: secrets)
        cache.use(Self.namespace(settings))
        cache.capacity = settings.cacheSize
        pace.use(Self.paceSlot(settings, engine: Self.activeEngine(settings)))
    }

    func update(settings new: AppSettings) {
        settings = new
        enginesSynced = false
        cache.capacity = new.cacheSize
        let space = Self.namespace(new)
        pace.use(Self.paceSlot(new, engine: Self.activeEngine(new)))
        if space != cache.namespace {
            // Translations for the previous settings stay cached: switching back costs nothing.
            cache.use(space)
            sessions.removeAll()
            if engineIssue != nil { engineIssue = nil; issueHandler?(nil) }
        }
    }

    /// The engine the user chose among the added ones; nil is Apple (also when the id no longer names one).
    private var activeEngine: EngineConfig? { Self.activeEngine(settings) }

    private static func activeEngine(_ s: AppSettings) -> EngineConfig? {
        s.customEngineID.flatMap { id in s.engines.first { $0.id == id } }
    }

    /// What a cached translation depends on besides the text: pair | engine identity | glossary. The identity is the
    /// Apple choice, or the added engine's id with a fingerprint of its kind, so editing its model or URL makes the old
    /// entries unreachable while switching engines back and forth keeps each one's. The same string keys the pace stats.
    /// `engine: nil` is Apple's namespace whatever engine is chosen (where a fallback stores).
    private static func namespace(_ s: AppSettings, engine: EngineConfig?) -> String {
        "\(space(s, engine: engine))|\(s.glossary.hashValue)"
    }

    /// The namespace without the glossary: what an engine's speed depends on (pair and engine identity).
    private static func space(_ s: AppSettings, engine: EngineConfig?) -> String {
        let identity = engine.map { "ext:\($0.id.uuidString.prefix(8)):\(fingerprint($0))" } ?? "apple:\(s.engine.rawValue)"
        return "\(s.sourceLanguage)>\(s.targetLanguage)|\(identity)"
    }

    private static func paceSlot(_ s: AppSettings, engine: EngineConfig?) -> PaceStats.Slot {
        PaceStats.Slot(key: space(s, engine: engine), engine: engine?.id)
    }

    private static func namespace(_ s: AppSettings) -> String { namespace(s, engine: activeEngine(s)) }

    /// 64-bit FNV-1a of the engine's kind as sorted-key JSON (id and name left out: renaming keeps the cache).
    private static func fingerprint(_ e: EngineConfig) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(e), var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "0" }
        obj["id"] = nil
        obj["name"] = nil
        let canonical = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        var h: UInt64 = 0xcbf29ce484222325
        for b in canonical { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    func setIssueHandler(_ h: @escaping @Sendable (TranslationIssue?) -> Void) { issueHandler = h }
    func setRejectionHandler(_ h: @escaping @Sendable (UUID, [String]) -> Void) { rejectionHandler = h }

    /// Request fields the active added engine's server refused (for the harness and the engine list).
    func learnedFields() async -> [String] {
        guard let e = activeEngine else { return [] }
        return await client.learnedRejections(for: e.id).sorted()
    }

    /// The model ids an engine offers, for the add-engine sheet (the client keeps one list per engine).
    func engineModels(_ e: EngineConfig, refresh: Bool = false) async -> Result<[String], EngineError> {
        do { return .success(try await client.models(e, refresh: refresh)) } catch { return .failure(error) }
    }

    /// One sample translation through `e`, for the sheet's "it works, 840 ms" line. The time counts as a measurement.
    func engineProbe(_ e: EngineConfig) async -> (sample: String?, ms: Int, error: EngineError?) {
        let r = await client.probe(e, target: settings.targetLanguage)
        if r.error == nil { pace.recordBatch(Double(r.ms) / 1000, slot: Self.paceSlot(settings, engine: e)) }
        return r
    }

    /// Median seconds one batch took through the engine (over every language pair) since launch, probes included; nil
    /// before the first.
    nonisolated func measuredSeconds(for engine: UUID) -> Double? { pace.medianSeconds(for: engine) }

    /// "First result 0.3 s · 62% from memory" numbers for the engine, once at least `minBatches` batches ran.
    nonisolated func speedSummary(for engine: UUID, minBatches: Int = 5) -> SpeedSummary? {
        pace.summary(for: engine, minBatches: minBatches)
    }

    /// Seconds a call of `lines` lines is expected to take on the engine and pair in use now, from what it has been
    /// measured at (first line, then per further line); nil until its first line has come back, since nothing is
    /// assumed about an engine. Never waits.
    nonisolated func expectedSeconds(lines: Int) -> Double? { pace.expectedSeconds(lines: lines) }

    /// Seconds a running call of `lines` lines (`delivered` already back, `elapsed` s in) still needs; nil while unknown.
    nonisolated func remainingSeconds(lines: Int, delivered: Int, elapsed: Double) -> Double? {
        pace.remainingSeconds(lines: lines, delivered: delivered, elapsed: elapsed)
    }

    /// Speed of every engine and pair used so far, numbers only (no screen text), for the logs.
    nonisolated func paceStats() -> [PaceStat] { pace.stats() }

    /// Translations stored per namespace since launch (a debug view: where did a fallback's results go).
    nonisolated var storeCounts: [String: Int] { cache.storeCounts }

    /// Seeds the client with what the app saved for an engine seen for the first time, and lets go of what it learned for
    /// one whose kind changed. Idempotent; runs before the first engine call after each settings change.
    private func syncEngines() async {
        enginesSynced = true
        for e in settings.engines {
            let fp = Self.fingerprint(e)
            if let known = fingerprints[e.id], known != fp {
                await client.seedRejections([], for: e.id)
                rejectionsReported[e.id] = []
                cooldowns[e.id] = nil
                rejectionHandler?(e.id, [])
            } else if fingerprints[e.id] == nil {
                let saved = Set(settings.engineRejections[e.id] ?? [])
                await client.seedRejections(saved, for: e.id)
                rejectionsReported[e.id] = saved
            }
            fingerprints[e.id] = fp
        }
    }

    private func reportRejections(_ e: EngineConfig) async {
        let now = await client.learnedRejections(for: e.id)
        guard now != rejectionsReported[e.id] ?? [] else { return }
        rejectionsReported[e.id] = now
        rejectionHandler?(e.id, now.sorted())
    }

    /// Call after the user downloads a language pack.
    func invalidateAvailability() {
        pairStatus.removeAll()
        sessions.removeAll()
    }

    func prewarm() async {
        if let e = activeEngine {
            // Opens the connection (TLS) before the first batch; Apple warms up below as the safety net.
            if !enginesSynced { await syncEngines() }
            _ = await withDeadline(Self.deadline(items: 1)) { await self.client.prewarm(e) }
        }
        if settings.engine == .customModel { intelligence.prewarm(settings: settings); return }
        // Loading the translation model takes a moment the first time; do it before the first region.
        let source = settings.sourceLanguage == "auto" ? "ja" : settings.sourceLanguage
        let outcome = await withDeadline(Self.deadline(items: 1)) { await self.warm(source: source) }
        // A model that never answers is dropped, so the first real call starts fresh.
        if case .value = outcome {} else { dropSessions(source: source) }
    }

    private func warm(source: String) async {
        if let (session, _) = try? await session(source: source) { _ = try? await session.translate("。") }
    }

    /// 5 s + 2 s per item. Measured high-fidelity worst case: 4.2 s for 3 lines (2026-10-17), so 3 lines get 11 s,
    /// about 2.6× the worst seen; slack enough for a loaded machine, short enough that a stall is noticed.
    private static func deadline(items: Int) -> Duration { .seconds(5 + 2 * items) }

    /// An added engine answers over the network, and free tiers wander: Gemini's free 3.1-flash-lite took 1.3–4.3 s
    /// for one line and missed 11 s for three twice (2026-10-17). 10 s + 2 s per item (16 s for 3 lines) keeps a slow
    /// but working engine; one that stalls still falls back to Apple.
    private static func addedEngineDeadline(items: Int) -> Duration { .seconds(10 + 2 * items) }

    /// Forgets the cached sessions for a language pair so the next call builds fresh ones.
    /// (`IntelligenceTranslator` keeps no session between calls: each request makes its own.)
    private func dropSessions(source: String) {
        let prefix = "\(source)>\(settings.targetLanguage)|"
        for k in sessions.keys where k.hasPrefix(prefix) { sessions[k] = nil }
    }

    /// Cached translation, without doing any work.
    /// Never waits, even while a translation is in progress.
    nonisolated func cached(_ text: String) -> String? { cache[text] }

    /// Translations held, over every language pair and engine.
    nonisolated var cachedCount: Int { cache.count }
    nonisolated func clearCache() { cache.removeAll() }

    /// Translates `texts` (in the given order — callers pass reading order so results fill the screen top to
    /// bottom). `onResult` fires as each one lands. Every engine call runs under a deadline; what streamed in before
    /// it hit is kept.
    func translate(_ texts: [String], onResult: (@Sendable (String, String) -> Void)? = nil) async -> TranslationOutcome {
        var outcome = TranslationOutcome()
        var todo: [String] = []
        var seen = Set<String>()
        let cjkSource = ["ja", "zh-Hans", "zh-Hant", "ko"].contains(pageLanguage ?? "")
        for t in texts where seen.insert(t).inserted {
            if !TranslationFilter.needsTranslation(t, cjkSource: cjkSource) {
                // Not source-language text (a handle, a brand, a counter): kept as is, and the pipeline leaves it alone.
                outcome.translations[t] = t
                onResult?(t, t)
            } else if let hit = cache[t] {
                pace.recordLookup(hit: true)
                outcome.translations[t] = hit
                onResult?(t, hit)
            } else {
                pace.recordLookup(hit: false)
                todo.append(t)
            }
        }
        guard !todo.isEmpty else { return outcome }

        // Group by source language (keeping order) so each session handles one pair.
        var order: [String] = []
        var groups: [String: [String]] = [:]
        for t in todo {
            let lang = sourceLanguage(for: t)
            if groups[lang] == nil { order.append(lang) }
            groups[lang, default: []].append(t)
        }

        for source in order {
            if Task.isCancelled { outcome.cancelled = true; break }
            let items = groups[source]!
            let space = cache.namespace
            let appleSpace = Self.namespace(settings, engine: nil)
            var run = await attempt(items, source: source, via: route(), onResult: onResult)
            if case let .added(engine) = run.route {
                switch run.status {
                case .value:
                    engineRecovered(engine)
                case .cancelled:
                    break
                case let .failed(error):
                    engineFailed(engine, reason: (error as? EngineError)?.localizedMessage ?? error.localizedDescription,
                                 after: error, appleSpace: appleSpace)
                    run = await attempt(items, source: source, via: .apple, onResult: onResult)
                case .timedOut:
                    engineFailed(engine, reason: String(localized: "The engine did not answer in time."), after: nil, appleSpace: appleSpace)
                    run = await attempt(items, source: source, via: .apple, onResult: onResult)
                }
                await reportRejections(engine)
            }
            let translated = run.translated
            // Whatever Apple translated, in a fallback or while the engine rests, is Apple's: it must not outlive the engine's recovery.
            let storeSpace: String
            if case .apple = run.route { storeSpace = appleSpace } else { storeSpace = space }
            var groupFailed = false, groupCancelled = false
            switch run.status {
            case .value:
                // An added engine's issue stays up while Apple stands in for it.
                if engineIssue == nil { issueHandler?(nil) }
            case .cancelled:
                // Not a failure: what streamed in is kept; the session is dropped as after a timeout (its state is unknown).
                groupCancelled = true
                outcome.cancelled = true
                dropSessions(source: source)
            case let .failed(error):
                groupFailed = true
                dropSessions(source: source)
                issueHandler?((error as? TranslationIssue) ?? .failed(error.localizedDescription))
            case .timedOut:
                groupFailed = true
                dropSessions(source: source)
                outcome.timedOut = true
                issueHandler?(.timedOut)
            }
            // Settings changed while it ran: the engine may have used either, so it is not cached under any.
            let current = cache.namespace == space
            for (s, t) in translated {
                outcome.translations[s] = t
                if current { cache.store(t, for: s, in: storeSpace) }
            }
            if groupCancelled { break }
            let missing = items.filter { translated[$0] == nil }
            if missing.count == items.count || groupFailed && !missing.isEmpty {
                outcome.batchFailed = true
            }
            // Some of the group came back and these did not: the engine skipped them.
            // Also a group that came back all unchanged with no error (`StrikeRule`).
            let struck = StrikeRule.struck(items: items, translated: translated, groupFailed: groupFailed)
            if !struck.isEmpty { Trace.count("translate.struck", struck.count) }
            outcome.failed.formUnion(struck)
        }
        return outcome
    }

    // MARK: - Routing

    private enum Route { case apple, added(EngineConfig) }

    private enum Status {
        case value
        case failed(any Error)
        case timedOut
        case cancelled
    }

    private struct Attempt {
        var route: Route
        var translated: [String: String]
        var status: Status
        var isOK: Bool { if case .value = status { true } else { false } }
        var isCancelled: Bool { if case .cancelled = status { true } else { false } }
    }

    /// The added engine while it is not cooling down after a failure; Apple otherwise.
    private func route() -> Route {
        guard let e = activeEngine else { return .apple }
        if let c = cooldowns[e.id], ProcessInfo.processInfo.systemUptime < c.until { return .apple }
        return .added(e)
    }

    /// One group through one route, under one deadline. What streamed in before a deadline or a throw is kept.
    /// Every result takes its display form here, whatever engine made it.
    private func attempt(_ items: [String], source: String, via route: Route,
                         onResult: (@Sendable (String, String) -> Void)?) async -> Attempt {
        if !enginesSynced { await syncEngines() }
        let streamed = Streamed()
        // Pace is learned from engine output only (text from the cache or kept as is takes no engine time), line by line,
        // so a batch cut later still teaches what it delivered. An added engine answers a batch at once: its first
        // result is the whole batch's time and the rest follow at no cost.
        let slot: PaceStats.Slot
        if case let .added(e) = route { slot = Self.paceSlot(settings, engine: e) } else { slot = Self.paceSlot(settings, engine: nil) }
        let started = ProcessInfo.processInfo.systemUptime
        let arrivals = Arrivals(since: started)
        let book = pace
        let deliver: @Sendable (String, String) -> Void = { s, t in
            let shown = TranslationCheck.displayForm(t)
            streamed.put(s, shown)
            let (delta, isFirst) = arrivals.next(at: ProcessInfo.processInfo.systemUptime)
            book.record(delta, isFirst: isFirst, slot: slot)
            onResult?(s, shown)
        }
        let limit: Duration
        if case .added = route { limit = Self.addedEngineDeadline(items: items.count) } else { limit = Self.deadline(items: items.count) }
        let result = await withDeadline(limit) {
            try await self.translateGroup(items, source: source, via: route, onResult: deliver)
        }
        var a = Attempt(route: route, translated: streamed.all, status: .value)
        defer { pace.finish(slot: slot, total: ProcessInfo.processInfo.systemUptime - started, ok: a.isOK, cancelled: a.isCancelled) }
        switch result {
        case let .value(r):
            a.translated = r.mapValues(TranslationCheck.displayForm)
        case let .failed(error) where Task.isCancelled && error is CancellationError,
             let .failed(error) where (error as? EngineError) == .cancelled:
            a.status = .cancelled
        case let .failed(error):
            a.status = .failed(error)
        case .timedOut:
            a.status = .timedOut
        }
        return a
    }

    /// The engine answered: its cooldown and issue end, and Apple's stand-in entries stop being served.
    private func engineRecovered(_ e: EngineConfig) {
        // The cooldown has ended, but its steps stay until the engine has been healthy for a window.
        if var c = cooldowns[e.id] {
            c.backoff.success(now: ProcessInfo.processInfo.systemUptime)
            c.until = 0
            cooldowns[e.id] = c
        }
        cache.clearFallback()
        pace.clearFallback()
        if engineIssue != nil { engineIssue = nil; issueHandler?(nil) }
    }

    /// The engine failed: Apple takes this group at once, the engine rests (`Retry-After` capped at 120 s, else the
    /// `RetryBackoff` steps), and while it rests lines Apple translated are served from Apple's own namespace.
    private func engineFailed(_ e: EngineConfig, reason: String, after error: (any Error)?, appleSpace: String) {
        let now = ProcessInfo.processInfo.systemUptime
        var c = cooldowns[e.id] ?? Cooldown()
        var pause = c.backoff.failure(now: now)
        if case let .rateLimited(after?)? = error as? EngineError { pause = min(120, max(0, after)) }
        c.until = now + pause
        cooldowns[e.id] = c
        cache.useFallback(appleSpace, until: c.until)
        // Groups go to Apple while the engine rests: their expected time is Apple's.
        pace.useFallback(Self.paceSlot(settings, engine: nil), until: c.until)
        let issue = TranslationIssue.engineUnavailable(name: e.name, reason: reason)
        // The same words are not said again for every group.
        if engineIssue != issue { engineIssue = issue; issueHandler?(issue) }
    }

    // MARK: - Engines

    private func translateGroup(_ items: [String], source: String, via route: Route,
                                onResult: @escaping @Sendable (String, String) -> Void) async throws -> [String: String] {
        Trace.count("translate.requests")
        Trace.count("translate.texts", items.count)
        Trace.mark("engine ← \(items.map { $0.debugDescription }.joined(separator: " | "))", since: Trace.now)
        if case let .added(engine) = route {
            return try await translateViaEngine(engine, items, source: source, onResult: onResult)
        }
        if let fake = ProcessInfo.processInfo.environment["MWOYEO_FAKE_ENGINE"] {
            return try await fakeEngine(fake, items, onResult: onResult)
        }
        if settings.engine == .customModel {
            if intelligence.isAvailable {
                return try await intelligence.translate(items, source: source == "und" ? nil : source, target: settings.targetLanguage,
                                                        glossary: settings.glossaryPairs, onResult: onResult)
            }
            // Fall through to Apple Translation; say why the chosen engine is not used.
            issueHandler?(.intelligenceUnavailable(intelligence.unavailableReason ?? ""))
        }
        guard source != "und" else { throw TranslationIssue.failed(String(localized: "Could not tell which language this is")) }
        let (session, strategy) = try await session(source: source)
        return try await stream(items, through: session, space: sessionID(source: source, strategy: strategy), onResult: onResult)
    }

    /// One call to an added engine for the whole group (the engines translate a batch in one request, so results land
    /// together). A line the engine handed back untranslated is missing, not stored and not shown. Provider-side prompt
    /// caching is not used: the system prompt is far under the minimum size that providers cache.
    private func translateViaEngine(_ engine: EngineConfig, _ items: [String], source: String,
                                    onResult: @escaping @Sendable (String, String) -> Void) async throws -> [String: String] {
        let clock = ContinuousClock()
        let start = clock.now
        let lines = try await client.translate(items, source: source == "und" ? nil : source, target: settings.targetLanguage,
                                               glossary: settings.glossaryPairs, engine: engine)
        let elapsed = Int((clock.now - start) / .milliseconds(1))
        Trace.sample("translate.engine_ms", Double(elapsed))
        guard lines.count == items.count else { throw EngineError.countMismatch(expected: items.count, got: lines.count) }
        var out: [String: String] = [:]
        for (s, raw) in zip(items, lines) {
            let t = TranslationCheck.displayForm(raw)
            if TranslationCheck.isUntranslated(source: s, translation: t, target: settings.targetLanguage) {
                Trace.count("translate.untranslated")
                continue
            }
            out[s] = t
            onResult(s, t)
        }
        return out
    }

    private var fakeCalls = 0
    private var fakeParked: [CheckedContinuation<Void, Never>] = []

    /// Headless-harness engine, chosen by `MWOYEO_FAKE_ENGINE`: `hang` never returns and ignores cancellation, `fail`
    /// always throws, `fail-once` throws on the first call then behaves like `slow:100`, `slow:<ms>` waits, then returns
    /// "⟦<target>⟧ " + source for every item, streaming each one.
    private func fakeEngine(_ mode: String, _ items: [String],
                            onResult: @escaping @Sendable (String, String) -> Void) async throws -> [String: String] {
        fakeCalls += 1
        let target = settings.targetLanguage
        var delay = 100
        switch mode {
        case "hang":
            // Parked for good (kept alive so the runtime does not report a leaked continuation).
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in fakeParked.append(c) }
            return [:]
        case "fail":
            throw TranslationIssue.failed("fake engine")
        case "fail-once":
            if fakeCalls == 1 { throw TranslationIssue.failed("fake engine") }
        default:
            if mode.hasPrefix("slow:"), let ms = Int(mode.dropFirst(5)) { delay = ms }
        }
        // A cancelled batch must not look like a success: the sleep returns at once on cancel, so check after it.
        try? await Task.sleep(for: .milliseconds(delay))
        if Task.isCancelled { throw CancellationError() }
        var out: [String: String] = [:]
        for s in items {
            let t = "⟦\(target)⟧ " + s
            out[s] = t
            onResult(s, t)
        }
        return out
    }

    /// Picks the session for `source` → target: the low-latency pack when installed (auto), otherwise
    /// Apple Intelligence's high-fidelity model.
    private func session(source: String) async throws -> (TranslationSession, Strategy) {
        // Before macOS 26.4 a session cannot pick its model: the language pack is the only one.
        let wanted: [Strategy] = !TranslationEngineChoice.hasHighFidelity ? [.lowLatency]
            : settings.engine == .highFidelity ? [.highFidelity] : [.lowLatency, .highFidelity]
        var downloadable = false
        for strategy in wanted {
            let id = sessionID(source: source, strategy: strategy)
            if let s = sessions[id] { return (s, strategy) }
            let status: LanguageAvailability.Status
            if let cached = pairStatus[id] { status = cached } else {
                status = await availability(strategy)
                    .status(from: Locale.Language(identifier: source), to: Locale.Language(identifier: settings.targetLanguage))
                pairStatus[id] = status
            }
            if status == .supported { downloadable = true }
            guard status == .installed else { continue }
            let s = makeSession(source: Locale.Language(identifier: source), target: Locale.Language(identifier: settings.targetLanguage),
                                strategy: strategy)
            sessions[id] = s
            return (s, strategy)
        }
        if downloadable {
            throw TranslationIssue.languagePackMissing(source: source, target: settings.targetLanguage)
        }
        throw TranslationIssue.unsupportedPair(source: source, target: settings.targetLanguage)
    }

    /// One language pair and strategy: the key of a session and of what the engine's wording of a term was learned for.
    private func sessionID(source: String, strategy: Strategy) -> String {
        "\(source)>\(settings.targetLanguage)|\(strategy == .highFidelity ? "hf" : "ll")"
    }

    private func availability(_ strategy: Strategy) -> LanguageAvailability {
        guard #available(macOS 26.4, *) else { return LanguageAvailability() }
        return LanguageAvailability(preferredStrategy: strategy == .highFidelity ? .highFidelity : .lowLatency)
    }

    private func makeSession(source: Locale.Language, target: Locale.Language, strategy: Strategy) -> TranslationSession {
        guard #available(macOS 26.4, *) else { return TranslationSession(installedSource: source, target: target) }
        return TranslationSession(installedSource: source, target: target,
                                  preferredStrategy: strategy == .highFidelity ? .highFidelity : .lowLatency)
    }

    /// Batch request whose responses arrive one by one, in order. A source with protected spans goes as a request of its own,
    /// all at once with the batch: a batch response carries no attributed text (measured 2026-10-18), so it could not say where
    /// the spans came back.
    private func stream(_ items: [String], through session: TranslationSession, space: String,
                        onResult: @escaping @Sendable (String, String) -> Void) async throws -> [String: String] {
        let pairs = settings.glossaryPairs
        let marked = protectedSpans(for: items, pairs: pairs)
        let plain = items.filter { marked[$0] == nil }
        let requests = plain.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
        func batch() async throws -> [String: String] {
            var out: [String: String] = [:]
            for try await r in session.translate(batch: requests) {
                guard let id = r.clientIdentifier, let i = Int(id), i < plain.count else { continue }
                let t = Self.applyGlossary(TranslationCleanup.restoreSourceTokens(r.targetText, source: plain[i]), source: plain[i], pairs: pairs)
                out[plain[i]] = t
                onResult(plain[i], t)
            }
            return out
        }
        // No span in the group (the usual case): the batch alone, as before spans existed.
        guard !marked.isEmpty else { return try await batch() }
        Trace.count("translate.marked", marked.count)
        var out: [String: String] = [:]
        try await withThrowingTaskGroup(of: [String: String].self) { group in
            if #available(macOS 26.4, *) {
                for (source, plan) in marked {
                    group.addTask {
                        let t: String
                        do {
                            t = try await self.translateMarked(source, plan, pairs: pairs, through: session, space: space)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // An attributed request that fails costs the line its glossary terms, never its translation.
                            Trace.count("translate.marked_failed")
                            let r = try await session.translate(source)
                            t = Self.applyGlossary(TranslationCleanup.restoreSourceTokens(r.targetText, source: source), source: source, pairs: pairs)
                        }
                        onResult(source, t)
                        return [source: t]
                    }
                }
            }
            if !requests.isEmpty { group.addTask { try await batch() } }
            for try await part in group { out.merge(part) { $1 } }
        }
        return out
    }

    /// What is carried through Apple Translation untouched or replaced afterwards, per source: the glossary terms found in it,
    /// and the formulas behind `MWOYEO_INLINE_MATH=1` (until the drawing of them lands). Needs macOS 26.4, where a request can
    /// carry attributes; before it every source goes as plain text, as it always did, and so does one with no span.
    private func protectedSpans(for items: [String], pairs: [(String, String)]) -> [String: ProtectedSpans] {
        guard #available(macOS 26.4, *), !pairs.isEmpty || Self.inlineMath else { return [:] }
        var plans: [String: ProtectedSpans] = [:]
        for s in items {
            var found = ProtectedSpans.glossarySpans(in: s, pairs: pairs)
            if Self.inlineMath { found += InlineMath.spans(in: s) }
            let plan = ProtectedSpans(source: s, spans: found)
            if !plan.isEmpty { plans[s] = plan }
        }
        return plans
    }

    /// `MWOYEO_INLINE_MATH=1` marks formulas as well as glossary terms.
    private static let inlineMath = ProcessInfo.processInfo.environment["MWOYEO_INLINE_MATH"] == "1"

    /// One source with its spans marked. Glossary terms carry a marker only: `skipsTranslation` is ignored for words by the
    /// language pack, and high fidelity honours it but writes pieces of its own rendering beside the forced word ("손실실은").
    /// So the run of a term is the engine's rendering and its particle, and the glossary target takes the rendering's place.
    /// A span that did not come back once stays as the engine wrote it, and its term is left to `applyGlossary`.
    /// Where the term's word ends in a run is told by the engine's own rendering of the term, asked alone once per pair and strategy
    /// (`TermRenderings`) while this request runs: "평가" and "카메라" end in a syllable that is also a particle, and the run alone
    /// cannot say it is not one.
    @available(macOS 26.4, *)
    private nonisolated func translateMarked(_ source: String, _ plan: ProtectedSpans, pairs: [(String, String)],
                                             through session: TranslationSession, space: String) async throws -> String {
        let terms = plan.glossaryTerms
        async let learned = renderings.learn(terms, in: space, through: session)
        let response = try await session.translate(plan.attributedSource())
        let known = await learned
        guard let attributed = response.attributedTargetText else {
            Trace.count("translate.marked_plain")
            return Self.applyGlossary(TranslationCleanup.restoreSourceTokens(response.targetText, source: source), source: source, pairs: pairs)
        }
        let (text, runs) = ProtectedSpans.answer(attributed)
        let resolution = plan.resolve(target: text, runs: runs, renderings: known)
        for r in resolution.resolved where r.span.isGlossary { Trace.count("translate.cut_\(r.cut)") }
        let pending = Set(resolution.unresolved.compactMap { span -> String? in if case let .glossary(t, _) = span.kind { t } else { nil } })
        let handled = Set(plan.spans.compactMap { span -> String? in if case let .glossary(t, _) = span.kind, !pending.contains(t) { t } else { nil } })
        if !resolution.unresolved.isEmpty { Trace.count("translate.span_unresolved", resolution.unresolved.count) }
        // Same length as what it replaces (`restoreSourceTokens` only changes case), so the formulas' ranges hold.
        let t = Self.applyGlossary(TranslationCleanup.restoreSourceTokens(resolution.text, source: source), source: source, pairs: pairs, skipping: handled)
        if TranslationCheck.displayForm(t) == t, t.count == resolution.text.count { placements.put(source, t, resolution.math) }
        return t
    }

    /// Where the formulas of `translated` (the translation `translate` returned for `source`) stand in it, in the order of the
    /// source; empty when it had none, or `translated` is not what was recorded. For the pipeline that draws them.
    nonisolated func inlineMath(source: String, translated: String) -> [ProtectedSpans.Resolved] {
        placements.math(source, translated)
    }

    private nonisolated let placements = MathPlacements()

    /// What Apple Translation writes for each glossary term alone, per language pair and strategy, for this launch.
    private nonisolated let renderings = TermRenderings()

    /// Apple Translation has no glossary; enforce entries whose source term survived untranslated. `skipping`: targets of terms
    /// whose spans were all resolved.
    private nonisolated static func applyGlossary(_ translated: String, source: String, pairs: [(String, String)],
                                                  skipping handled: Set<String> = []) -> String {
        var t = translated
        for (s, d) in pairs where source.contains(s) && !handled.contains(d) {
            t = t.replacingOccurrences(of: s, with: d)
        }
        return t
    }

    // MARK: - Helpers


    /// Languages seen in confidently detected text, so short or ambiguous snippets ("# fan-art", a user name)
    /// follow the page instead of being guessed as Catalan.
    private var seenLanguages: [String: Int] = [:]

    /// The configured source language, or the language most of the page's longer lines were detected in.
    private var pageLanguage: String? {
        settings.sourceLanguage != "auto" ? settings.sourceLanguage : seenLanguages.max { $0.value < $1.value }?.key
    }

    /// The configured source language, or the language of `text` when set to auto ("und" if unsure).
    func sourceLanguage(for text: String) -> String {
        if settings.sourceLanguage != "auto" { return settings.sourceLanguage }
        let r = NLLanguageRecognizer()
        r.languageConstraints = Languages.sources.filter { $0 != "auto" }.map { NLLanguage($0) }
        r.processString(text)
        let page = seenLanguages.max { $0.value < $1.value }?.key
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first else { return page ?? "und" }
        let code: String = switch lang {
        case .simplifiedChinese: "zh-Hans"
        case .traditionalChinese: "zh-Hant"
        default: lang.rawValue
        }
        if p > 0.9, text.count >= 20 { seenLanguages[code, default: 0] += 1 }
        return p < 0.75 || text.count < 12 ? page ?? code : code
    }
}

/// Arrival times of one call's results.
private final class Arrivals: @unchecked Sendable {
    private let lock = NSLock()
    private var last: TimeInterval
    private var count = 0
    init(since t: TimeInterval) { last = t }
    /// Seconds since the call began (first) or the previous result, and whether this is the first.
    func next(at t: TimeInterval) -> (Double, Bool) {
        lock.withLock {
            defer { last = t; count += 1 }
            return (t - last, count == 0)
        }
    }
}

/// What an Apple Translation session writes for a glossary term alone (the answer to `translate("assessment")`: "평가"), asked
/// once per language pair, strategy and term and kept for the launch. Memory only: nothing of it is written out. A run of a marked
/// term that starts with it is cut where it ends (`ProtectedSpans.resolve(renderings:)`). Short: a term is a word or two, and the
/// glossary is a few dozen entries at most. A failed or cancelled ask is forgotten, so the next line asks again.
private final class TermRenderings: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String: Task<String?, Never>] = [:]

    /// The renderings of `terms` (the ones that have a usable one), asked concurrently; a term already asked, by this call or
    /// another running now, is not asked again.
    func learn(_ terms: [String], in space: String, through session: TranslationSession) async -> [String: String] {
        guard !terms.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, String?).self) { group in
            for term in terms {
                group.addTask { (term, await self.rendering(of: term, in: space) { try await session.translate(term).targetText }) }
            }
            var out: [String: String] = [:]
            for await (term, r) in group { if let r { out[term] = r } }
            return out
        }
    }

    /// The caller that starts an ask owns it: its cancellation cancels the ask (the others get nil and ask again next time).
    private func rendering(of term: String, in space: String, answer: @escaping @Sendable () async throws -> String) async -> String? {
        let key = space + "\u{1F}" + term
        let (task, owner) = lock.withLock { () -> (Task<String?, Never>, Bool) in
            if let t = asked[key] { return (t, false) }
            let t = Task<String?, Never> {
                do {
                    Trace.count("translate.rendering_asked")
                    let r = ProtectedSpans.usableRendering(try await answer(), ofTerm: term)
                    if r == nil { Trace.count("translate.rendering_unusable") }
                    return r
                } catch {
                    self.forget(key)
                    return nil
                }
            }
            asked[key] = t
            return (t, true)
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { if owner { task.cancel() } }
    }

    private func forget(_ key: String) { lock.withLock { asked[key] = nil } }
}

/// Where the formulas stand in the translation last made for a source (see `TranslationService.inlineMath`). Few: only the lines
/// on screen are asked for.
private final class MathPlacements: @unchecked Sendable {
    private let lock = NSLock()
    private let lru = LRUCache<String, (translated: String, math: [ProtectedSpans.Resolved])>(capacity: 300)
    func put(_ source: String, _ translated: String, _ math: [ProtectedSpans.Resolved]) {
        lock.withLock { lru[source] = math.isEmpty ? nil : (translated, math) }
    }
    func math(_ source: String, _ translated: String) -> [ProtectedSpans.Resolved] {
        lock.withLock { lru[source].flatMap { $0.translated == translated ? $0.math : nil } ?? [] }
    }
}

/// Source → translation, per language pair, engine and glossary (so switching settings and back reuses them),
/// lock-guarded so regions can read it from outside the actor. Memory only: screen text never goes to disk.
private final class Memory: @unchecked Sendable {
    private let lock = NSLock()
    private let lru = LRUCache<String, String>(capacity: 5000)
    private var space = ""
    /// While an added engine rests after a failure: Apple's namespace, read as a second place to look until `until`.
    private var stand: (space: String, until: TimeInterval)?
    private var stores: [String: Int] = [:]
    var namespace: String { lock.withLock { space } }
    func use(_ namespace: String) { lock.withLock { space = namespace; stand = nil } }
    func useFallback(_ namespace: String, until: TimeInterval) { lock.withLock { stand = (namespace, until) } }
    func clearFallback() { lock.withLock { stand = nil } }
    /// How many translations each namespace has been given since launch (debug view; evictions are not subtracted).
    var storeCounts: [String: Int] { lock.withLock { stores } }
    var capacity: Int {
        get { lock.withLock { lru.capacity } }
        set { lock.withLock { lru.capacity = max(1, newValue) } }
    }
    var count: Int { lock.withLock { lru.count } }
    func removeAll() { lock.withLock { lru.removeAll() } }
    /// For the current settings.
    subscript(text: String) -> String? {
        lock.withLock {
            if let hit = lru[Self.key(text, space)] { return hit }
            guard let stand, ProcessInfo.processInfo.systemUptime < stand.until else { return nil }
            return lru[Self.key(text, stand.space)]
        }
    }
    func store(_ translation: String, for text: String, in namespace: String) {
        lock.withLock {
            lru[Self.key(text, namespace)] = translation
            stores[namespace, default: 0] += 1
        }
    }
    /// OCR spacing varies between reads of the same text: runs of whitespace count as one space, ends trimmed.
    private static func key(_ text: String, _ namespace: String) -> String {
        namespace + "\u{0}" + text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// On-device Apple Intelligence (Foundation Models) translator: natural phrasing, glossary-aware.
final class IntelligenceTranslator: @unchecked Sendable {
    private let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
    private let maxConcurrent = 3

    var isAvailable: Bool {
        if case .available = model.availability { return true }
        return false
    }

    var unavailableReason: String? {
        guard case let .unavailable(reason) = model.availability else { return nil }
        return switch reason {
        case .appleIntelligenceNotEnabled: String(localized: "Turn on Apple Intelligence in System Settings")
        case .deviceNotEligible: String(localized: "This Mac does not support Apple Intelligence")
        case .modelNotReady: String(localized: "The model is still downloading")
        @unknown default: String(localized: "Unknown reason")
        }
    }

    func supports(_ language: String) -> Bool {
        model.supportedLanguages.contains { $0.languageCode == Locale.Language(identifier: language).languageCode }
    }

    func prewarm(settings: AppSettings) {
        guard isAvailable else { return }
        session(source: nil, target: settings.targetLanguage, glossary: settings.glossaryPairs).prewarm()
    }

    /// One request per line, a few at a time: decode speed is the bottleneck, so a batch costs about as
    /// much as its lines run separately, while separate requests let short lines land first.
    func translate(_ items: [String], source: String?, target: String, glossary: [(String, String)],
                   onResult: (@Sendable (String, String) -> Void)? = nil) async throws -> [String: String] {
        var out: [String: String] = [:]
        var firstError: Error?
        var queue = items[...] // reading order
        // Sent bare, a line of English chat reads as a message to answer, and the model echoes it back untranslated.
        let ask = "Translate into \(Locale(identifier: "en").localizedString(forIdentifier: target) ?? target):\n"

        try await withThrowingTaskGroup(of: (String, String?, Error?).self) { group in
            func launch() {
                guard let src = queue.popFirst() else { return }
                group.addTask {
                    do {
                        let r = try await self.session(source: source, target: target, glossary: glossary)
                            .respond(to: ask + src, options: GenerationOptions(samplingMode: .greedy))
                        return (src, Self.clean(r.content, source: src), nil)
                    } catch {
                        return (src, nil, error)
                    }
                }
            }
            for _ in 0..<maxConcurrent { launch() }
            while let (src, translated, error) = try await group.next() {
                if let translated {
                    out[src] = translated
                    onResult?(src, translated)
                } else if firstError == nil {
                    firstError = error
                }
                launch()
            }
        }
        if out.isEmpty, let firstError { throw firstError }
        return out
    }

    /// Strips wrapping quotes or a leading label the model sometimes adds.
    static func clean(_ s: String, source: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("「", "」"), ("“", "”")] where t.hasPrefix(open) && t.hasSuffix(close) && t.count > 2
            && !(source.hasPrefix(open) && source.hasSuffix(close)) {
            t = String(t.dropFirst().dropLast())
        }
        if !source.contains("\n") { t = t.components(separatedBy: .newlines).first ?? t }
        return t
    }

    private func session(source: String?, target: String, glossary: [(String, String)]) -> LanguageModelSession {
        let en = Locale(identifier: "en")
        let targetName = en.localizedString(forIdentifier: target) ?? target
        let sourceName = source.flatMap { en.localizedString(forIdentifier: $0) } ?? "the source language"
        var instructions = """
        You translate text captured from a computer screen — apps, games, web pages, comics, video subtitles — \
        from \(sourceName) into natural, fluent \(targetName).
        Rules:
        - Reply with the translation only: no quotes, labels, explanations, romanization or notes.
        - Keep it about as short as the original; it replaces UI labels and captions in place. Match the original's register.
        - Keep numbers, units, names, product names, keyboard shortcuts and placeholders like %@ or {0} unchanged.
        """
        if !glossary.isEmpty {
            instructions += "\nGlossary — always use these translations:\n"
            instructions += glossary.map { "- \($0.0) → \($0.1)" }.joined(separator: "\n")
        }
        return LanguageModelSession(model: model, instructions: instructions)
    }


}

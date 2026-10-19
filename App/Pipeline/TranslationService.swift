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
    /// The threads, memory and usage of every app served under context (RAM only; `ContextBook`). Off never touches it.
    private var contexts = ContextBook()
    /// The one store of how fast each engine and language pair is (and how often a line was already in memory): the
    /// scheduler's `expectedSeconds`, the logs' `paceStats` and the engine list's speed line all read it.
    private nonisolated let pace = PaceStats()
    /// Engines that failed, and until when (`ProcessInfo.systemUptime`) groups go straight to Apple.
    private var cooldowns: [UUID: Cooldown] = [:]
    /// The added engine is failing and Apple is standing in: successful Apple groups must not clear its issue.
    private var engineIssue: TranslationIssue?
    /// Who hears what became of each group (`TranslationEvent`): every lens's hint and the render harness. The issue stream does not
    /// say it: it keeps only the newest issue, so a second timeout looks like the first.
    private var observers: [UUID: @Sendable (TranslationEvent) -> Void] = [:]

    private struct Cooldown {
        var backoff = HealthyBackoff()
        var until: TimeInterval = 0
    }

    init(settings: AppSettings, secrets: any SecretStore = KeychainSecrets()) {
        self.settings = settings
        client = EngineClient(secrets: secrets, allowsCommands: !Distribution.isAppStore)
        cache.use(Self.namespace(settings))
        cache.capacity = settings.cacheSize
        pace.use(Self.paceSlot(settings, engine: Self.activeEngine(settings)))
    }

    func update(settings new: AppSettings) {
        // Allowing an engine ends the rest its missing permission put it on, and the notice that said so.
        for e in new.engines where new.enginePermissions.allows(e) && !settings.enginePermissions.allows(e) {
            cooldowns[e.id] = nil
            if case let .engineUnavailable(name, _)? = engineIssue, name == e.name { engineIssue = nil; issueHandler?(nil) }
        }
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
        // What an engine may be sent besides the lines is not its identity: the Off path's namespace, and what the client learned about its
        // server, must not move when the user turns context on or off.
        obj["context"] = nil
        let canonical = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        var h: UInt64 = 0xcbf29ce484222325
        for b in canonical { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    func setIssueHandler(_ h: @escaping @Sendable (TranslationIssue?) -> Void) { issueHandler = h }

    /// Calls `h` for every group's end from now on, until `stopObserving`.
    func observe(_ h: @escaping @Sendable (TranslationEvent) -> Void) -> UUID {
        let id = UUID()
        observers[id] = h
        return id
    }

    func stopObserving(_ id: UUID) { observers[id] = nil }

    private func tell(_ event: TranslationEvent) { for h in observers.values { h(event) } }

    /// A group that threw counts as the engine not answering, unless it threw for the pack or the pair (their own hints say so).
    private static func isEngineTrouble(_ error: any Error) -> Bool {
        switch error as? TranslationIssue {
        case .languagePackMissing?, .unsupportedPair?: false
        default: true
        }
    }

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
        if let e = activeEngine, isPermitted(e) {
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
    ///
    /// `context` is the document the lens covers. With none, or when the settings leave context Off for its app and engine, or when
    /// the engine is Apple Translation or Foundation Models, the code below runs as it always did. Where context is On the call takes
    /// `translateWithContext`; Apple Translation with the user's pinned terms takes `translateWithPins` (see `ContextPlan`).
    func translate(_ texts: [String], context: LensContext? = nil,
                   onResult: (@Sendable (String, String) -> Void)? = nil) async -> TranslationOutcome {
        if let context, let plan = contextPlan(for: context) {
            switch plan {
            case let .engine(engine, options, profile):
                return await translateWithContext(texts, engine: engine, options: options, profile: profile, lens: context, onResult: onResult)
            case let .applePins(entries):
                return await translateWithPins(texts, entries: entries, onResult: onResult)
            }
        }
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

        // What the lenses' hints hear is one event for the whole call, a result per language group: a batch of three lines that splits in
        // two groups (7 s + 9 s of deadlines) is one slow batch, and two timeouts of it must not read as two. Each result carries the pair
        // and the engine that really took the group (Apple while the chosen engine rests), so a lens reads only the ones that are its own.
        // Any line translated is an answer, even from a group that then threw or hit its deadline.
        var results: [TranslationEvent.Group] = []
        defer { if !results.isEmpty { tell(TranslationEvent(groups: results)) } }
        for source in order {
            if Task.isCancelled { outcome.cancelled = true; break }
            let items = groups[source]!
            let space = cache.namespace
            let target = settings.targetLanguage
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
            var groupTrouble: TranslationEvent.Kind?
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
                if Self.isEngineTrouble(error) { groupTrouble = .failed }
            case .timedOut:
                groupFailed = true
                dropSessions(source: source)
                outcome.timedOut = true
                issueHandler?(.timedOut)
                groupTrouble = .timedOut
            }
            if let kind = translated.isEmpty ? groupTrouble : .answered {
                let engine: EngineConfig?
                if case let .added(e) = run.route { engine = e } else { engine = nil }
                let route = TranslationRoute(source: source, target: target, engineID: engine?.id, engineName: engine?.name ?? String(localized: "Apple"))
                results.append(TranslationEvent.Group(route: route, kind: kind))
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

    /// The gate in front of every call to an added engine's server (`translateViaEngine`, `contextGroup`, `prewarm`): an engine off this
    /// Mac is called only while the person's permission for its host stands (`EnginePermissions`; the sheet's box writes it). Without
    /// one the call fails as `needsPermission`, which a group handles as any engine failure: the notice names the host, Apple takes the
    /// group, and no other engine stands in. The sheet's own model list and sample (`engineModels`, `engineProbe`) are the person
    /// testing the engine before they allow it and send no lens text.
    private func isPermitted(_ engine: EngineConfig) -> Bool { settings.enginePermissions.allows(engine) }

    private func requirePermission(_ engine: EngineConfig) throws(EngineError) {
        guard isPermitted(engine) else { throw .needsPermission(host: engine.endpointName) }
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
        #if !MAS
        if let fake = ProcessInfo.processInfo.environment["MWOYEO_FAKE_ENGINE"] {
            return try await fakeEngine(fake, items, onResult: onResult)
        }
        #endif
        if settings.engine == .customModel {
            if intelligence.isAvailable {
                return try await intelligence.translate(items, source: source == "und" ? nil : source, target: settings.targetLanguage,
                                                        glossary: settings.glossaryPairs, onResult: onResult)
            }
            // Fall through to Apple Translation; say why the chosen engine is not used.
            issueHandler?(.intelligenceUnavailable(intelligence.unavailableReason ?? ""))
        }
        guard source != "und" else { throw TranslationIssue.failed(String(localized: "Could not tell which language this is")) }
        let (session, _) = try await session(source: source)
        return try await stream(items, through: session, onResult: onResult)
    }

    /// One call to an added engine for the whole group (the engines translate a batch in one request, so results land
    /// together). A line the engine handed back untranslated is missing, not stored and not shown. Provider-side prompt
    /// caching is not used: the system prompt is far under the minimum size that providers cache.
    private func translateViaEngine(_ engine: EngineConfig, _ items: [String], source: String,
                                    onResult: @escaping @Sendable (String, String) -> Void) async throws -> [String: String] {
        try requirePermission(engine)
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
    /// "⟦<target>⟧ " + source for every item, streaming each one. `drop:<text>` is like `slow:100`, but the answer lacks <text>
    /// (an Apple that dropped a pinned term).
    private func fakeEngine(_ mode: String, _ items: [String],
                            onResult: @escaping @Sendable (String, String) -> Void) async throws -> [String: String] {
        fakeCalls += 1
        let target = settings.targetLanguage
        var delay = 100
        var dropped: String?
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
            if mode.hasPrefix("drop:") { dropped = String(mode.dropFirst(5)) }
        }
        // A cancelled batch must not look like a success: the sleep returns at once on cancel, so check after it.
        try? await Task.sleep(for: .milliseconds(delay))
        if Task.isCancelled { throw CancellationError() }
        var out: [String: String] = [:]
        for s in items {
            let t = "⟦\(target)⟧ " + (dropped.map { s.replacingOccurrences(of: $0, with: "") } ?? s)
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
            let id = "\(source)>\(settings.targetLanguage)|\(strategy == .highFidelity ? "hf" : "ll")"
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

    private func availability(_ strategy: Strategy) -> LanguageAvailability {
        guard #available(macOS 26.4, *) else { return LanguageAvailability() }
        return LanguageAvailability(preferredStrategy: strategy == .highFidelity ? .highFidelity : .lowLatency)
    }

    private func makeSession(source: Locale.Language, target: Locale.Language, strategy: Strategy) -> TranslationSession {
        guard #available(macOS 26.4, *) else { return TranslationSession(installedSource: source, target: target) }
        return TranslationSession(installedSource: source, target: target,
                                  preferredStrategy: strategy == .highFidelity ? .highFidelity : .lowLatency)
    }

    /// Batch request whose responses arrive one by one, in order. A source with protected spans (formulas, behind
    /// `MWOYEO_INLINE_MATH=1`) goes as a request of its own, all at once with the batch: a batch response carries no attributed
    /// text (measured 2026-10-18), so it could not say where the spans came back.
    private func stream(_ items: [String], through session: TranslationSession,
                        onResult: @escaping @Sendable (String, String) -> Void) async throws -> [String: String] {
        let pairs = settings.glossaryPairs
        let marked = protectedSpans(for: items)
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
                            t = try await self.translateMarked(source, plan, pairs: pairs, through: session)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            // An attributed request that fails costs the line its formulas' places, never its translation.
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

    /// The formulas of each source that are carried through Apple Translation as written, behind `MWOYEO_INLINE_MATH=1` (until
    /// the drawing of them lands). Needs macOS 26.4, where a request can carry attributes; before it, or with the variable
    /// unset, every source goes as plain text, as it always did, and so does one with no span.
    private func protectedSpans(for items: [String]) -> [String: ProtectedSpans] {
        guard #available(macOS 26.4, *), Self.inlineMath else { return [:] }
        var plans: [String: ProtectedSpans] = [:]
        for s in items {
            let plan = ProtectedSpans(source: s, spans: InlineMath.spans(in: s))
            if !plan.isEmpty { plans[s] = plan }
        }
        return plans
    }

    /// The App Store build has no such switch: it is off there, as with the variable unset.
    #if MAS
    private static let inlineMath = false
    #else
    private static let inlineMath = ProcessInfo.processInfo.environment["MWOYEO_INLINE_MATH"] == "1"
    #endif

    /// One source with its formulas marked: each comes back where the engine put it (`skipsTranslation`), found again by its
    /// marker. A span that did not come back once stays as the engine wrote it, and `placements` has no place for that line.
    @available(macOS 26.4, *)
    private nonisolated func translateMarked(_ source: String, _ plan: ProtectedSpans, pairs: [(String, String)],
                                             through session: TranslationSession) async throws -> String {
        let response = try await session.translate(plan.attributedSource())
        guard let attributed = response.attributedTargetText else {
            Trace.count("translate.marked_plain")
            return Self.applyGlossary(TranslationCleanup.restoreSourceTokens(response.targetText, source: source), source: source, pairs: pairs)
        }
        let (text, runs) = ProtectedSpans.answer(attributed)
        let resolution = plan.resolve(target: text, runs: runs)
        if !resolution.unresolved.isEmpty { Trace.count("translate.span_unresolved", resolution.unresolved.count) }
        // Same length as `text` (`restoreSourceTokens` only changes case) unless a glossary term was put in: then the formulas'
        // ranges would not hold, and the line has no places.
        let t = Self.applyGlossary(TranslationCleanup.restoreSourceTokens(text, source: source), source: source, pairs: pairs)
        if TranslationCheck.displayForm(t) == t, t.count == text.count { placements.put(source, t, resolution.resolved) }
        return t
    }

    /// Where the formulas of `translated` (the translation `translate` returned for `source`) stand in it, in the order of the
    /// source; empty when it had none, or `translated` is not what was recorded. For the pipeline that draws them.
    nonisolated func inlineMath(source: String, translated: String) -> [ProtectedSpans.Resolved] {
        placements.math(source, translated)
    }

    private nonisolated let placements = MathPlacements()

    /// Apple Translation has no glossary; enforce entries whose source term survived untranslated.
    private nonisolated static func applyGlossary(_ translated: String, source: String, pairs: [(String, String)]) -> String {
        var t = translated
        for (s, d) in pairs where source.contains(s) {
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

// MARK: - Context

/// Sources whose answer from Apple lacked a pinned term, noted from the streaming callbacks (which run on any task).
private final class HeldSources: @unchecked Sendable {
    private let lock = NSLock()
    private var set = Set<String>()
    func put(_ s: String) { lock.withLock { _ = set.insert(s) } }
}

/// The translation paths that carry a document's context (design §2, §8, §9). Each runs only for a call that came with a
/// `LensContext` and a `ContextPlan`; a call without one never gets here. No screen text, transcript or memory row is logged,
/// counted or saved by anything below: they live in `contexts` (RAM) and in the request body, and nowhere else.
extension TranslationService {
    /// What this call does with its context, or nil for today's path. `ContextPlan.decide` holds the rules.
    private func contextPlan(for lens: LensContext) -> ContextPlan? {
        let engine = activeEngine
        var rests = false
        if engine != nil, case .apple = route() { rests = true }
        return ContextPlan.decide(settings: settings, engine: engine, engineRests: rests,
                                  profile: AppProfiles.profile(for: lens.bundleID, in: settings.appProfiles))
    }

    // MARK: the added engine, with the document's context

    /// The added engine's call under context: the thread of this lens is found, resumed or started (and reset as the signals ask),
    /// lookups and stores use the namespace of this thread and this memory (design §8.1), and each group's request carries the card,
    /// the note and names, and the lines before and after. A group the engine fails or misses its deadline goes the old way (Apple takes
    /// it while the engine rests). The same health bookkeeping as the old path: the engine's cooldown, the lens's events, the issue.
    private func translateWithContext(_ texts: [String], engine: EngineConfig, options: MwoyeoCore.ContextOptions, profile: AppProfile?,
                                      lens document: LensContext, onResult: (@Sendable (String, String) -> Void)?) async -> TranslationOutcome {
        var outcome = TranslationOutcome()
        // Memory only takes the app and nothing of the document: no title, no screen, no lines. The thread is then the app's, the
        // pair's and the engine's alone, and no line of the screen is kept for this call at all.
        let lens = options.memoryOnly ? document.appOnly : document
        let space = cache.namespace
        let target = settings.targetLanguage
        let pass = contexts.begin(lens, profile: profile, pair: LanguagePair(settings.sourceLanguage, target), engineID: engine.id.uuidString,
                                  now: ProcessInfo.processInfo.systemUptime)
        let scoped = ContextNamespace.make(base: space, key: pass.key, fingerprint: pass.fingerprint)

        var todo: [String] = [], needing: [String] = []
        var seen = Set<String>()
        let cjkSource = ["ja", "zh-Hans", "zh-Hant", "ko"].contains(pageLanguage ?? "")
        for t in texts where seen.insert(t).inserted {
            if !TranslationFilter.needsTranslation(t, cjkSource: cjkSource) {
                outcome.translations[t] = t
                onResult?(t, t)
            } else if let hit = cache.value(for: t, in: scoped) {
                pace.recordLookup(hit: true)
                needing.append(t)
                outcome.translations[t] = hit
                onResult?(t, hit)
            } else {
                pace.recordLookup(hit: false)
                needing.append(t)
                todo.append(t)
            }
        }
        // The lines of this call join the thread when it is over, in the order they were asked for, cache hits included (§8.1).
        defer {
            if !options.memoryOnly {
                contexts.observe(lens, key: pass.key, lines: needing.map { ($0, outcome.translations[$0]) }, now: ProcessInfo.processInfo.systemUptime)
            }
        }
        guard !todo.isEmpty else { return outcome }

        var order: [String] = []
        var groups: [String: [String]] = [:]
        for t in todo {
            let language = sourceLanguage(for: t)
            if groups[language] == nil { order.append(language) }
            groups[language, default: []].append(t)
        }
        var results: [TranslationEvent.Group] = []
        defer { if !results.isEmpty { tell(TranslationEvent(groups: results)) } }
        for source in order {
            if Task.isCancelled { outcome.cancelled = true; break }
            let items = groups[source]!
            let run = await attemptWithContext(items, source: source, engine: engine, options: options, lens: lens, pass: pass, onResult: onResult)
            switch run.status {
            case .value:
                engineRecovered(engine)
                if engineIssue == nil { issueHandler?(nil) }
            case .cancelled:
                outcome.cancelled = true
                dropSessions(source: source)
            case let .failed(error):
                engineFailed(engine, reason: (error as? EngineError)?.localizedMessage ?? error.localizedDescription, after: error,
                             appleSpace: Self.namespace(settings, engine: nil))
            case .timedOut:
                engineFailed(engine, reason: String(localized: "The engine did not answer in time."), after: nil,
                             appleSpace: Self.namespace(settings, engine: nil))
            }
            await reportRejections(engine)
            // What the engine gave is kept; a group it failed goes the old way, where Apple takes it while the engine rests.
            let translated = run.translated
            let current = cache.namespace == space
            for (s, t) in translated {
                outcome.translations[s] = t
                if current { cache.store(t, for: s, in: scoped) }
            }
            if !run.isOK && !run.isCancelled {
                let rest = items.filter { translated[$0] == nil }
                if !rest.isEmpty {
                    let again = await translate(rest, onResult: onResult)
                    outcome.translations.merge(again.translations) { $1 }
                    outcome.failed.formUnion(again.failed)
                    outcome.timedOut = outcome.timedOut || again.timedOut
                    outcome.batchFailed = outcome.batchFailed || again.batchFailed
                    outcome.cancelled = outcome.cancelled || again.cancelled
                }
                if outcome.cancelled { break }
                continue
            }
            if run.isCancelled { break }
            if !translated.isEmpty {
                results.append(TranslationEvent.Group(route: TranslationRoute(source: source, target: target, engineID: engine.id, engineName: engine.name),
                                                      kind: .answered))
            }
            if items.allSatisfy({ translated[$0] == nil }) { outcome.batchFailed = true }
            let struck = StrikeRule.struck(items: items, translated: translated, groupFailed: false)
            if !struck.isEmpty { Trace.count("translate.struck", struck.count) }
            outcome.failed.formUnion(struck)
        }
        return outcome
    }

    /// One group through the added engine under context, under the engine deadline: what `attempt` does for an engine, with the
    /// context request in place of the plain one. Pace is learned from the engine's output only, as there.
    private func attemptWithContext(_ items: [String], source: String, engine: EngineConfig, options: MwoyeoCore.ContextOptions, lens: LensContext,
                                    pass: ContextBook.Pass, onResult: (@Sendable (String, String) -> Void)?) async -> Attempt {
        if !enginesSynced { await syncEngines() }
        let streamed = Streamed()
        let slot = Self.paceSlot(settings, engine: engine)
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
        let result = await withDeadline(Self.addedEngineDeadline(items: items.count)) {
            try await self.contextGroup(items, source: source, engine: engine, options: options, lens: lens, pass: pass, onResult: deliver)
        }
        var a = Attempt(route: .added(engine), translated: streamed.all, status: .value)
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

    /// The engine call itself. It prints no item (the old path's `engine ←` trace line stays the only place screen text can reach
    /// stderr, and only under MWOYEO_TRACE).
    private func contextGroup(_ items: [String], source: String, engine: EngineConfig, options: MwoyeoCore.ContextOptions, lens: LensContext,
                              pass: ContextBook.Pass, onResult: @escaping @Sendable (String, String) -> Void) async throws -> [String: String] {
        Trace.count("translate.requests")
        Trace.count("translate.texts", items.count)
        Trace.count("translate.context")
        try requirePermission(engine)
        let glossary = settings.glossaryPairs
        let request = contexts.request(lens, pass: pass, items: items, source: source == "und" ? nil : source, target: settings.targetLanguage,
                                       glossary: glossary)
        let clock = ContinuousClock()
        let start = clock.now
        let reply = try await client.translate(request, options: options, engine: engine)
        Trace.sample("translate.engine_ms", Double(Int((clock.now - start) / .milliseconds(1))))
        guard reply.lines.count == items.count else { throw EngineError.countMismatch(expected: items.count, got: reply.lines.count) }
        var out: [String: String] = [:]
        for (s, raw) in zip(items, reply.lines) {
            let t = TranslationCheck.displayForm(raw)
            if TranslationCheck.isUntranslated(source: s, translation: t, target: settings.targetLanguage) {
                Trace.count("translate.untranslated")
                continue
            }
            out[s] = t
            onResult(s, t)
        }
        let used = RequestLayout.selectedRows(request: request, options: options, kind: .engine(engine.kind))
        contexts.finish(lens, items: items, reply: reply, used: used, options: options, glossary: glossary)
        return out
    }

    // MARK: Apple Translation, with the user's pinned names and terms

    /// Apple Translation follows the names the user pinned for this app by getting them in the source text (design §7a, §9; off
    /// unless `appleUsesPinnedTerms`). The old path translates the changed texts, so its cache is keyed by them: a changed entry is a new
    /// key. An answer that lacks a pinned target is asked again as the text stood, so a line is never worse than it was. Apple takes no
    /// context, so nothing else of the app's memory is used.
    private func translateWithPins(_ texts: [String], entries: [MemoryEntry],
                                   onResult: (@Sendable (String, String) -> Void)?) async -> TranslationOutcome {
        var pre: [String: ApplePreinsertion] = [:]
        var sources: [String: [String]] = [:]
        var sent: [String] = []
        var seen = Set<String>()
        for t in texts where seen.insert(t).inserted {
            let p = ApplePreinsertion.insert(into: t, entries: entries, appleUsesPinnedTerms: true)
            if !p.isEmpty { pre[t] = p }
            if sources[p.text] == nil { sent.append(p.text) }
            sources[p.text, default: []].append(t)
        }
        // An answer that lacks a target is not shown: the retry below shows the plain one.
        let held = HeldSources()
        let first = await translate(sent) { [pre, sources] text, translation in
            for s in sources[text] ?? [text] {
                if let p = pre[s], !p.answerHoldsTargets(translation) { held.put(s); continue }
                onResult?(s, translation)
            }
        }
        var outcome = TranslationOutcome()
        var rejected: [String] = []
        for (text, translation) in first.translations {
            for s in sources[text] ?? [text] {
                if let p = pre[s], !p.answerHoldsTargets(translation) { rejected.append(s) } else { outcome.translations[s] = translation }
            }
        }
        outcome.failed = Set(first.failed.flatMap { sources[$0] ?? [$0] })
        outcome.timedOut = first.timedOut
        outcome.batchFailed = first.batchFailed
        outcome.cancelled = first.cancelled
        guard !rejected.isEmpty, !first.cancelled else { return outcome }
        Trace.count("translate.pins_rejected", rejected.count)
        let again = await translate(texts.filter(Set(rejected).contains), onResult: onResult)
        outcome.translations.merge(again.translations) { $1 }
        outcome.failed.formUnion(again.failed)
        outcome.timedOut = outcome.timedOut || again.timedOut
        outcome.batchFailed = outcome.batchFailed || again.batchFailed
        outcome.cancelled = outcome.cancelled || again.cancelled
        return outcome
    }

    // MARK: what the rest of the app reads and does with the context (the learned-memory file and the stats view, the referents)

    /// What the context path used for each app since launch: requests, tokens (cached ones counted), resets by reason. Numbers only.
    func contextUsage() -> [String: ContextUsage] { contexts.apps.mapValues(\.usage) }

    func contextUsage(for bundleID: String) -> ContextUsage { contexts.usage(for: bundleID) }

    /// The app's learned rows (RAM only), including those waiting for a second sighting.
    func learnedRows(for bundleID: String) -> [ContextMemory.LearnedRecord] { contexts.learned(for: bundleID) }

    func forgetLearned(for bundleID: String) { contexts.forgetLearned(bundleID) }

    /// "Remove" on one learned row, and the drop after "Pin" (`AppModel.pinLearned`: the profile has the row now).
    func removeLearned(src: String, for bundleID: String) { contexts.removeLearned(src: src, for: bundleID) }

    /// Told with the app's bundle id when its usable learned rows changed (`ContextBook.learnedChanged`). One handler.
    func setLearnedHandler(_ h: @escaping @Sendable (String) -> Void) { contexts.learnedChanged = h }

    /// "Start fresh" for the app's current thread: the transcript and the referents go, and the namespace generation moves on.
    func startFresh(for bundleID: String) { contexts.startFresh(bundleID) }

    /// Who the pronouns mean in the app's current document (`ContextThread.setReferents`).
    func setReferents(_ list: [Referent], for bundleID: String) { contexts.setReferents(list, for: bundleID) }
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
    /// For a namespace of the caller's choosing (a call under context has one of its own); no fallback place is read.
    func value(for text: String, in namespace: String) -> String? {
        lock.withLock { lru[Self.key(text, namespace)] }
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
        LanguageModelSession(model: model, instructions: RequestLayout.foundationModelsInstructions(source: source, target: target, glossary: glossary))
    }


}

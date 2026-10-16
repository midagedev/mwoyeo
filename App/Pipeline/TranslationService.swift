import Foundation
import FoundationModels
import MwoyeoCore
import NaturalLanguage
import Translation

/// Something the user can act on (missing language pack, Apple Intelligence off, …).
enum TranslationIssue: Error, Equatable, Sendable {
    case languagePackMissing(source: String, target: String)
    case intelligenceUnavailable(String)
    case unsupportedPair(source: String, target: String)
    case failed(String)
    case timedOut

    var message: String {
        switch self {
        case let .languagePackMissing(s, t):
            String(localized: "The \(Languages.name(s)) → \(Languages.name(t)) language pack is not installed. Download it in Settings › Translation.")
        case let .intelligenceUnavailable(why): String(localized: "Apple Intelligence is unavailable: \(why)")
        case let .unsupportedPair(s, t): String(localized: "\(Languages.name(s)) → \(Languages.name(t)) translation is not supported.")
        case let .failed(why): String(localized: "Translation failed: \(why)")
        case .timedOut: String(localized: "Translation is taking too long. Trying again shortly.")
        }
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

    init(settings: AppSettings) {
        self.settings = settings
        cache.use(Self.namespace(settings))
        cache.capacity = settings.cacheSize
    }

    func update(settings new: AppSettings) {
        let changed = new.sourceLanguage != settings.sourceLanguage || new.targetLanguage != settings.targetLanguage
            || new.glossary != settings.glossary || new.engine != settings.engine
        settings = new
        cache.capacity = new.cacheSize
        if changed {
            // Translations for the previous settings stay cached: switching back costs nothing.
            cache.use(Self.namespace(new))
            sessions.removeAll()
        }
    }

    /// What a cached translation depends on besides the text.
    private static func namespace(_ s: AppSettings) -> String {
        "\(s.sourceLanguage)>\(s.targetLanguage)|\(s.engine.rawValue)|\(s.glossary.hashValue)"
    }

    func setIssueHandler(_ h: @escaping @Sendable (TranslationIssue?) -> Void) { issueHandler = h }

    /// Call after the user downloads a language pack.
    func invalidateAvailability() {
        pairStatus.removeAll()
        sessions.removeAll()
    }

    func prewarm() async {
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
                outcome.translations[t] = hit
                onResult?(t, hit)
            } else {
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
            let items = groups[source]!
            let streamed = Streamed()
            let deliver: @Sendable (String, String) -> Void = { s, t in streamed.put(s, t); onResult?(s, t) }
            let space = cache.namespace
            var translated: [String: String] = [:]
            var groupFailed = false
            switch await withDeadline(Self.deadline(items: items.count), { try await self.translateGroup(items, source: source, onResult: deliver) }) {
            case let .value(r):
                translated = r
                issueHandler?(nil)
            case let .failed(error):
                translated = streamed.all
                groupFailed = true
                dropSessions(source: source)
                issueHandler?((error as? TranslationIssue) ?? .failed(error.localizedDescription))
            case .timedOut:
                translated = streamed.all
                groupFailed = true
                dropSessions(source: source)
                outcome.timedOut = true
                issueHandler?(.timedOut)
            }
            // Settings changed while it ran: the engine may have used either, so it is not cached under any.
            let current = cache.namespace == space
            for (s, t) in translated {
                outcome.translations[s] = t
                if current { cache.store(t, for: s, in: space) }
            }
            let missing = items.filter { translated[$0] == nil }
            if missing.count == items.count || groupFailed && !missing.isEmpty {
                outcome.batchFailed = true
            }
            // Some of the group came back and these did not: the engine skipped them.
            if missing.count < items.count { outcome.failed.formUnion(missing) }
        }
        return outcome
    }

    // MARK: - Engines

    private func translateGroup(_ items: [String], source: String,
                                onResult: @escaping @Sendable (String, String) -> Void) async throws -> [String: String] {
        Trace.count("translate.requests")
        Trace.count("translate.texts", items.count)
        Trace.mark("engine ← \(items.map { $0.debugDescription }.joined(separator: " | "))", since: Trace.now)
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
        let (session, _) = try await session(source: source)
        return try await stream(items, through: session, onResult: onResult)
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
        try? await Task.sleep(for: .milliseconds(delay))
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

    /// Batch request whose responses arrive one by one, in order.
    private func stream(_ items: [String], through session: TranslationSession,
                        onResult: @escaping @Sendable (String, String) -> Void) async throws -> [String: String] {
        let requests = items.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
        var out: [String: String] = [:]
        for try await r in session.translate(batch: requests) {
            guard let id = r.clientIdentifier, let i = Int(id), i < items.count else { continue }
            let t = applyGlossary(TranslationCleanup.restoreSourceTokens(TranslationCleanup.standaloneJamo(r.targetText), source: items[i]), source: items[i])
            out[items[i]] = t
            onResult(items[i], t)
        }
        return out
    }

    /// Apple Translation has no glossary; enforce entries whose source term survived untranslated.
    private func applyGlossary(_ translated: String, source: String) -> String {
        var t = translated
        for (s, d) in settings.glossaryPairs where source.contains(s) {
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

/// Source → translation, per language pair, engine and glossary (so switching settings and back reuses them),
/// lock-guarded so regions can read it from outside the actor. Memory only: screen text never goes to disk.
private final class Memory: @unchecked Sendable {
    private let lock = NSLock()
    private let lru = LRUCache<String, String>(capacity: 5000)
    private var space = ""
    var namespace: String { lock.withLock { space } }
    func use(_ namespace: String) { lock.withLock { space = namespace } }
    var capacity: Int {
        get { lock.withLock { lru.capacity } }
        set { lock.withLock { lru.capacity = max(1, newValue) } }
    }
    var count: Int { lock.withLock { lru.count } }
    func removeAll() { lock.withLock { lru.removeAll() } }
    /// For the current settings.
    subscript(text: String) -> String? { lock.withLock { lru[Self.key(text, space)] } }
    func store(_ translation: String, for text: String, in namespace: String) {
        lock.withLock { lru[Self.key(text, namespace)] = translation }
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

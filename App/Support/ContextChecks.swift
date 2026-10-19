#if !MAS
import AppKit
import MwoyeoCore
import MwoyeoEngines

/// The checks of the context request path, run by `--capture-ui … check-logic` (PASS/FAIL lines). Off first: the three ways to be
/// Off send the bytes main sent, end to end through `TranslationService`; then On: neighbours, the previous lines, the thread's
/// resets and keys, learning, usage; then Apple Translation, which never takes the context path.
///
/// The engine is `tools/mock-openai/server.py` on a free port, started and stopped here (its `--dump` files are the request bodies).
/// Every item of the On checks carries a sentinel (`MWOYEO_CTX_SENTINEL`, else random) that this file never prints; the runner greps
/// the output and the unified log for it. A failure prints counts and names, never a body or a line of text.
enum ContextChecks {
    final class Tally {
        var failures = 0
        func check(_ what: String, _ ok: Bool, _ note: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") context: \(what)" + (ok ? "" : note().isEmpty ? "" : " [\(note())]"))
            if !ok { failures += 1 }
        }
    }

    @MainActor
    static func run() async -> Int {
        let t = Tally()
        planChecks(t)
        gateChecks(t)
        watchChecks(t)
        bookChecks(t)
        memoryPlanChecks(t)
        learnedFileChecks(t)
        await offChecks(t)
        await onChecks(t)
        await memoryOnlyChecks(t)
        await routeChecks(t)
        await learnedFileRunChecks(t)
        await pinChecks(t)
        await appleChecks(t)
        return t.failures
    }

    // MARK: fixtures

    /// A string that stands in every screen line the On checks send; it is never printed, and the runner greps the output and the unified log
    /// for it (`MWOYEO_CTX_SENTINEL` fixes it). The learned-memory file must not hold it either.
    static let sentinel = ProcessInfo.processInfo.environment["MWOYEO_CTX_SENTINEL"] ?? "ZQ" + String(UUID().uuidString.prefix(8))
    static func line(_ s: String) -> String { "\(s) \(sentinel)" }

    static let chat = "com.example.chat", mail = "com.example.mail"
    static let ids = ["openai": "00000000-0000-0000-0000-0000000000A1", "anthropic": "00000000-0000-0000-0000-0000000000A2",
                      "deepl": "00000000-0000-0000-0000-0000000000A3"]

    static func lens(_ app: String = chat, title: String? = "Alice", id: String = "L1", screen: [String] = [], above: [String] = [],
                     below: [String] = []) -> LensContext {
        LensContext(bundleID: app, appName: app == chat ? "Example Chat" : "Example Mail", categoryWord: app == chat ? "social" : "productivity",
                    confirmedTitle: title, lensID: id, screen: screen, above: above, below: below)
    }

    static func engine(_ label: String, base: URL, context: EngineContext? = nil) -> EngineConfig {
        let id = UUID(uuidString: ids[label]!)!
        switch label {
        case "anthropic": return EngineConfig(id: id, name: "A", kind: .anthropic(baseURL: base, model: "claude-haiku-5-5", thinking: .off), context: context)
        case "deepl": return EngineConfig(id: id, name: "D", kind: .deepL(baseURL: base, formality: "prefer_more"), context: context)
        default: return EngineConfig(id: id, name: "O", kind: .openAICompatible(baseURL: base.appendingPathComponent("v1"), model: "m1", thinking: .off, extraHeaders: [:]),
                                     context: context)
        }
    }

    static func settings(_ e: EngineConfig?, profiles: [AppProfile] = [], target: String = "ko", glossary: String = "") -> AppSettings {
        var s = AppSettings()
        s.sourceLanguage = "en"
        s.targetLanguage = target
        s.glossary = glossary
        s.appProfiles = profiles
        if let e {
            s.engines = [e]
            s.customEngineID = e.id
        }
        return s
    }

    static func service(_ s: AppSettings) -> TranslationService {
        TranslationService(settings: s, secrets: MemorySecrets(Dictionary(uniqueKeysWithValues: s.engines.map { ($0.id, "dummy") })))
    }

    static func profile(_ app: String = chat, context: AppContextOverride? = nil, entries: [MemoryEntry] = [], note: String = "") -> AppProfile {
        AppProfile(bundleID: app, appName: app, source: "en", target: "ko", note: note, entries: entries, context: context)
    }

    // MARK: the plan

    @MainActor
    static func planChecks(_ t: Tally) {
        let url = URL(string: "http://127.0.0.1:1")!
        let on = engine("openai", base: url, context: EngineContext(enabled: true))
        let off = engine("openai", base: url, context: EngineContext(enabled: false, includeTitle: true, useLearned: true))
        let plain = engine("openai", base: url)
        func plan(_ e: EngineConfig?, rests: Bool = false, _ p: AppProfile? = nil, pins: Bool = false, engineChoice: TranslationEngineChoice = .auto) -> ContextPlan? {
            var s = settings(e, profiles: p.map { [$0] } ?? [])
            s.appleUsesPinnedTerms = pins
            s.engine = engineChoice
            return ContextPlan.decide(settings: s, engine: e, engineRests: rests, profile: p)
        }
        let entry = MemoryEntry(src: "token", dst: "토큰")
        t.check("the engine's switch puts the added engine on the context path", plan(on).map { if case .engine = $0 { true } else { false } } == true)
        t.check("no context, or enabled: false, is today's path", plan(plain) == nil && plan(off) == nil)
        t.check("an app override of off turns an engine's On off", plan(on, profile(context: AppContextOverride(mode: .off))) == nil)
        // Intended (design §9): writing the override in the app's profile is the user's opt-in, so `nearby` alone is On.
        t.check("an app override of nearby alone is On, though the engine says nothing",
                plan(plain, profile(context: AppContextOverride(mode: .nearby))).map { if case let .engine(_, o, _) = $0 { o.enabled && o.transcriptCount == 0 } else { false } } == true)
        t.check("a resting engine is Apple's stand-in: today's path", plan(on, rests: true) == nil)
        let template = EngineConfig(name: "T", kind: .httpTemplate(HTTPTemplate(url: "http://127.0.0.1:1/t", body: "{}", resultPath: "t", batching: .jsonArray)),
                                    context: EngineContext(enabled: true))
        t.check("an HTTP template owns its body: today's path", plan(template) == nil)
        // Apple Translation never takes the context path, whatever the override says.
        t.check("Apple Translation with a nearby override is today's path", plan(nil, profile(context: AppContextOverride(mode: .nearby), entries: [entry])) == nil)
        t.check("Apple with pinned terms off is today's path, entries or not", plan(nil, profile(entries: [entry])) == nil)
        t.check("Apple with pinned terms on and an entry pre-inserts", plan(nil, profile(entries: [entry]), pins: true) == .applePins([entry]))
        t.check("Apple with pinned terms on and no entry is today's path", plan(nil, profile(), pins: true) == nil && plan(nil, nil, pins: true) == nil)
        t.check("Foundation Models is not Apple Translation: no pre-insertion", plan(nil, profile(entries: [entry]), pins: true, engineChoice: .customModel) == nil)

        // A lens reads the window it covers only where something could use it.
        func needs(_ e: EngineConfig?, _ profiles: [AppProfile] = [], pins: Bool = false) -> Bool {
            var s = settings(e, profiles: profiles)
            s.appleUsesPinnedTerms = pins
            return ContextPlan.needsWindow(s)
        }
        t.check("no window is read by default, or with Off engines and Off apps", !needs(nil) && !needs(plain) && !needs(off, [profile(context: AppContextOverride(mode: .off))]))
        t.check("a window is read when an engine's switch or an app's override could put context on", needs(on) && needs(plain, [profile(context: AppContextOverride(mode: .nearby))]))
        t.check("Apple Translation reads a window only for pinned terms the user turned on and wrote",
                !needs(nil, [profile(context: AppContextOverride(mode: .nearby))]) && !needs(nil, [profile(entries: [entry])])
                && !needs(nil, [profile()], pins: true) && needs(nil, [profile(entries: [entry])], pins: true))
        t.check("an engine that owns its body reads no window", !needs(template))
    }

    // MARK: when the window is read

    @MainActor
    static func gateChecks(_ t: Tally) {
        var g = SampleGate()
        t.check("a lens reads no window while context could not be on", !g.admit(now: 0) && !g.admit(now: 100))
        g.enabled = true
        t.check("a read is due at once when enabled", g.admit(now: 10))
        t.check("none while one runs", !g.admit(now: 20))
        g.finish()
        t.check("none sooner than 0.5 s after the last", !g.admit(now: 10.4))
        t.check("one at 0.5 s", g.admit(now: 10.5))
        g.finish()
        g.enabled = false
        t.check("none after it is switched off", !g.admit(now: 99))
    }

    @MainActor
    static func watchChecks(_ t: Tally) {
        let w = LensWatch()
        func read(_ title: String, app: String = chat, at time: TimeInterval) -> LensContext? {
            w.ingest(LensWatch.Read(bundleID: app, appName: "Example Chat", title: title, category: "public.app-category.social-networking"),
                     lensID: "L1", now: time).context
        }
        let first = read("Alice - Example Chat", at: 0)
        t.check("the first title is taken at once, normalised", first?.confirmedTitle == "Alice" && first?.categoryWord == "social"
                && first?.appName == "Example Chat" && first?.lensID == "L1")
        t.check("the same read says nothing new", read("Alice - Example Chat", at: 0.5) == nil)
        t.check("a new title is not confirmed by one read", read("Bob - Example Chat", at: 1.0) == nil)
        t.check("nor by two", read("Bob - Example Chat", at: 1.5) == nil)
        t.check("the third read over at least 1 s confirms it", read("Bob - Example Chat", at: 2.0)?.confirmedTitle == "Bob")
        // The unread counter is not part of the title: a counter ticking must not look like a new document.
        t.check("an unread counter in the title changes nothing", read("(3) Bob - Example Chat", at: 2.5) == nil && read("(4) Bob - Example Chat", at: 3.0) == nil)
        let other = w.ingest(LensWatch.Read(bundleID: mail, appName: "Example Mail", title: "Inbox", category: "public.app-category.productivity"),
                             lensID: "L1", now: 3.5).context
        t.check("another app under the lens takes its first title at once", other?.bundleID == mail && other?.confirmedTitle == "Inbox"
                && other?.categoryWord == "productivity")
        let gone = w.ingest(nil, lensID: "L1", now: 4)
        t.check("a lens over no window says so once, then nothing", gone.gone && w.ingest(nil, lensID: "L1", now: 4.5) == (nil, false))
    }

    // MARK: the book

    @MainActor
    static func bookChecks(_ t: Tally) {
        let en = LanguagePair("en", "ko")
        let lines = (1...8).map { "line \($0)" }
        func observe(_ book: inout ContextBook, _ l: LensContext, _ pass: ContextBook.Pass, _ items: [String], at now: TimeInterval) {
            book.observe(l, key: pass.key, lines: items.map { ($0, nil) }, now: now)
        }
        func before(_ book: ContextBook, _ l: LensContext, _ pass: ContextBook.Pass, items: [String]) -> [String] {
            book.request(l, pass: pass, items: items, source: "en", target: "ko", glossary: []).before.map(\.source)
        }

        // The previous lines of a thread: what was observed, not the batch itself.
        var book = ContextBook()
        let screen = lines
        let l1 = lens(screen: screen)
        let p1 = book.begin(l1, profile: nil, pair: en, engineID: "e", now: 0)
        t.check("a fresh thread has no previous line", before(book, l1, p1, items: Array(lines[0..<2])).isEmpty && p1.reason == nil)
        observe(&book, l1, p1, Array(lines[0..<2]), at: 1)
        let p2 = book.begin(l1, profile: nil, pair: en, engineID: "e", now: 2)
        t.check("the next batch sees what was observed", before(book, l1, p2, items: Array(lines[2..<4])) == Array(lines[0..<2]) && p2.key == p1.key)
        t.check("a line being translated is never its own context", before(book, l1, p2, items: Array(lines[1..<3])) == [lines[0]])

        // Resets.
        let p3 = book.begin(l1, profile: nil, pair: en, engineID: "e", now: 2 + ThreadSignals.idleLimit)
        t.check("five minutes idle starts the transcript over", p3.reason == .idle && before(book, l1, p3, items: ["x"]).isEmpty && p3.key == p1.key)
        observe(&book, l1, p3, ["old one"], at: 400)
        let wholesale = lens(screen: (1...8).map { "other \($0)" })
        let p4 = book.begin(wholesale, profile: nil, pair: en, engineID: "e", now: 401)
        t.check("a wholly different screen starts the transcript over", p4.reason == .wholesaleChange && before(book, wholesale, p4, items: ["x"]).isEmpty)
        t.check("a reset that keeps the key keeps the namespace", p3.fingerprint == p1.fingerprint && p4.key == p1.key && p4.fingerprint == p1.fingerprint)

        // Keys: a pair or engine change is a key change, not a reset; going back resumes.
        var keys = ContextBook()
        let k1 = keys.begin(l1, profile: nil, pair: en, engineID: "e", now: 0)
        observe(&keys, l1, k1, ["kept one", "kept two"], at: 1)
        let k3 = keys.begin(l1, profile: nil, pair: en, engineID: "e2", now: 2)
        t.check("an engine change is a new key with an empty transcript", k3.key != k1.key && k3.reason == .engineChange && before(keys, l1, k3, items: ["x"]).isEmpty)
        let k2 = keys.begin(l1, profile: nil, pair: LanguagePair("en", "ja"), engineID: "e2", now: 3)
        t.check("a pair change is a new key with an empty transcript", k2.key != k1.key && k2.key != k3.key && k2.reason == .pairChange
                && before(keys, l1, k2, items: ["x"]).isEmpty)
        let k4 = keys.begin(l1, profile: nil, pair: en, engineID: "e", now: 4)
        t.check("back to the first pair and engine resumes its thread", k4.key == k1.key && before(keys, l1, k4, items: ["x"]) == ["kept one", "kept two"])
        let titleB = lens(title: "Bob", screen: screen)
        let k5 = keys.begin(titleB, profile: nil, pair: en, engineID: "e", now: 5)
        t.check("a confirmed title change is a new key", k5.key != k1.key && k5.reason == .titleChange && before(keys, titleB, k5, items: ["x"]).isEmpty)
        let k6 = keys.begin(l1, profile: nil, pair: en, engineID: "e", now: 6)
        t.check("A, B, A resumes A", k6.key == k1.key && before(keys, l1, k6, items: ["x"]) == ["kept one", "kept two"])
        let k7 = keys.begin(lens(id: "L2", screen: screen), profile: nil, pair: en, engineID: "e", now: 7)
        t.check("a second lens on the same document keeps a thread of its own", k7.key != k1.key && k7.reason == .lensChange)
        t.check("each key has its own namespace", Set([k1.key, k2.key, k3.key, k5.key, k7.key].map { ContextNamespace.make(base: "b", key: $0, fingerprint: "f") }).count == 5)

        // Apps do not share anything.
        let mailLens = lens(mail, title: "Inbox", screen: screen)
        let m1 = keys.begin(mailLens, profile: nil, pair: en, engineID: "e", now: 8)
        t.check("another app starts with an empty transcript", before(keys, mailLens, m1, items: ["x"]).isEmpty)

        // The lines above the batch on screen are lines the lens showed.
        var seen = ContextBook()
        let aboveLens = lens(screen: screen, above: ["above one", "above two"])
        let a1 = seen.begin(aboveLens, profile: nil, pair: en, engineID: "e", now: 0)
        t.check("lines right above the batch count as observed", before(seen, aboveLens, a1, items: ["x"]) == ["above one", "above two"])

        // The memory follows the profile, the namespace follows what the user wrote.
        var memory = ContextBook()
        let withNote = profile(entries: [MemoryEntry(src: "田中", dst: "Tanaka")], note: "casual")
        let n1 = memory.begin(l1, profile: nil, pair: en, engineID: "e", now: 0)
        let n2 = memory.begin(l1, profile: withNote, pair: en, engineID: "e", now: 1)
        let n3 = memory.begin(l1, profile: withNote, pair: en, engineID: "e", now: 2)
        t.check("a note and an entry change the namespace, the same ones do not", n2.fingerprint != n1.fingerprint && n3.fingerprint == n2.fingerprint)
        let req = memory.request(l1, pass: n3, items: ["x"], source: nil, target: "ko", glossary: [])
        t.check("the request carries the card, the note and the rows", req.card?.appName == "Example Chat" && req.card?.domain == "social"
                && req.card?.title == "Alice" && req.note == "casual" && req.memory.map(\.src) == ["田中"])
        let n4 = memory.begin(l1, profile: nil, pair: en, engineID: "e", now: 3)
        t.check("a profile that is gone empties the memory", n4.fingerprint == n1.fingerprint
                && memory.request(l1, pass: n4, items: ["x"], source: nil, target: "ko", glossary: []).memory.isEmpty)
        memory.startFresh(chat)
        let n5 = memory.begin(l1, profile: nil, pair: en, engineID: "e", now: 4)
        t.check("Start fresh moves the namespace on and empties the transcript", n5.fingerprint != n4.fingerprint && n5.key == n4.key)

        // Learning is only for the user who turned it on, and a term is used after two sightings.
        func replying(_ src: String) -> TranslationReply {
            TranslationReply(lines: ["⟦ko⟧ T_\(src) 번역"], terms: [TermHint(src: src, dst: "T_\(src)")], usage: TokenUsage(prompt: 1000, completion: 50, cached: 800))
        }
        var plain = ContextBook()
        _ = plain.begin(l1, profile: nil, pair: en, engineID: "e", now: 0)
        plain.finish(l1, items: ["Alice came"], reply: replying("Alice"), used: [], options: ContextOptions(enabled: true, includeLearned: false), glossary: [])
        plain.finish(l1, items: ["Alice left"], reply: replying("Alice"), used: [], options: ContextOptions(enabled: true, includeLearned: false), glossary: [])
        t.check("without includeLearned a reply's terms record nothing", plain.learned(for: chat).isEmpty && plain.usage(for: chat).sightings == 0)
        var learning = ContextBook()
        let on = ContextOptions(enabled: true, includeLearned: true)
        let q = learning.begin(l1, profile: nil, pair: en, engineID: "e", now: 0)
        learning.finish(l1, items: ["Alice came"], reply: replying("Alice"), used: [], options: on, glossary: [])
        t.check("with it on, one sighting is recorded but not used", learning.learned(for: chat).count == 1
                && learning.request(l1, pass: q, items: ["x"], source: nil, target: "ko", glossary: []).memory.isEmpty)
        learning.finish(l1, items: ["Alice left"], reply: replying("Alice"), used: [], options: on, glossary: [])
        t.check("an entry is usable after 2 sightings", learning.request(l1, pass: q, items: ["x"], source: nil, target: "ko", glossary: []).memory.map(\.src) == ["Alice"])
        t.check("usage sums tokens, cached ones included", learning.usage(for: chat).requests == 2 && learning.usage(for: chat).cached == 1600
                && learning.usage(for: chat).prompt == 2000 && learning.usage(for: chat).sightings == 2)
        learning.forgetLearned(chat)
        t.check("forgetting learned empties the rows", learning.learned(for: chat).isEmpty)

        // The book tells when the rows a request may use changed (the learned-memory file and the Memory sheet follow it), and not otherwise.
        final class Told: @unchecked Sendable {
            private let lock = NSLock()
            private var apps: [String] = []
            func note(_ app: String) { lock.withLock { apps.append(app) } }
            var count: Int { lock.withLock { apps.count } }
            var all: [String] { lock.withLock { apps } }
        }
        let told = Told()
        var watched = ContextBook()
        watched.learnedChanged = { told.note($0) }
        let w0 = watched.begin(l1, profile: nil, pair: en, engineID: "e", now: 0)
        watched.finish(l1, items: ["Alice came"], reply: replying("Alice"), used: [], options: on, glossary: [])
        t.check("learned rows: a first sighting is no change (the row is not used yet)", told.count == 0)
        watched.finish(l1, items: ["Alice left"], reply: replying("Alice"), used: [], options: on, glossary: [])
        t.check("learned rows: the second sighting makes the row usable, and the book tells once", told.all == [chat])
        watched.finish(l1, items: ["Alice again"], reply: replying("Alice"), used: [], options: on, glossary: [])
        t.check("learned rows: a third sighting changes nothing a file would hold", told.count == 1)
        watched.removeLearned(src: "alice", for: chat)
        t.check("learned rows: removing one tells (the source is matched as the sheet matches it), removing a missing one does not",
                told.count == 2 && watched.learned(for: chat).isEmpty)
        watched.removeLearned(src: "Nobody", for: chat)
        watched.forgetLearned(chat)
        t.check("learned rows: forgetting an empty memory tells nothing", told.count == 2)
        watched.finish(l1, items: ["Alice came"], reply: replying("Alice"), used: [], options: on, glossary: [])
        watched.finish(l1, items: ["Alice left"], reply: replying("Alice"), used: [], options: on, glossary: [])
        watched.forgetLearned(chat)
        t.check("learned rows: forgetting usable rows tells", told.count == 4)
        watched.finish(l1, items: ["Alice came"], reply: replying("Alice"), used: [], options: on, glossary: [])
        watched.finish(l1, items: ["Alice left"], reply: replying("Alice"), used: [], options: on, glossary: [])
        let toldBeforePin = told.count
        _ = watched.begin(l1, profile: profile(entries: [MemoryEntry(src: "Alice", dst: "앨리스")]), pair: en, engineID: "e", now: 1)
        t.check("learned rows: a name written (or pinned) in the profile replaces the learned row, and the book tells",
                told.count == toldBeforePin + 1 && watched.learned(for: chat).isEmpty)
        _ = w0

        // The lines right above the batch travel as their own field of the request: "nearby" sends them, the thread's history is not them.
        var aboveBook = ContextBook()
        let aboveSeen = lens(screen: screen, above: ["above one", "above two"], below: ["below one"])
        let ap = aboveBook.begin(aboveSeen, profile: nil, pair: en, engineID: "e", now: 0)
        let areq = aboveBook.request(aboveSeen, pass: ap, items: ["x"], source: nil, target: "ko", glossary: [])
        t.check("the request carries the lines right above and below the batch", areq.above == ["above one", "above two"] && areq.after == ["below one"])
    }

    // MARK: memory only (D1)

    @MainActor
    static func memoryPlanChecks(_ t: Tally) {
        let url = URL(string: "http://127.0.0.1:1")!
        let plain = engine("openai", base: url)
        let on = engine("openai", base: url, context: EngineContext(enabled: true, previousLines: 2))
        let loud = engine("openai", base: url, context: EngineContext(enabled: false, previousLines: 8, includeTitle: true, useLearned: true))
        let entries = [MemoryEntry(src: "Alice", dst: "앨리스", kind: .person, gender: .f)]
        let written = profile(entries: entries, note: "casual")
        func plan(_ e: EngineConfig?, _ p: AppProfile?) -> ContextPlan? {
            ContextPlan.decide(settings: settings(e, profiles: p.map { [$0] } ?? []), engine: e, engineRests: false, profile: p)
        }
        func options(_ p: ContextPlan?) -> ContextOptions? { if case let .engine(_, o, _)? = p { o } else { nil } }
        t.check("memory only: an app with a note and names puts an engine whose Context is off on the memory path",
                options(plan(plain, written)).map { $0.enabled && $0.memoryOnly && $0.transcriptCount == 0 } == true
                && options(plan(plain, profile(note: "casual"))).map(\.memoryOnly) == true
                && options(plan(plain, profile(entries: entries))).map(\.memoryOnly) == true)
        t.check("memory only: the engine's other switches do not widen it (no title, no learned rows, no lines)",
                options(plan(loud, written)).map { $0.memoryOnly && !$0.includeTitle && !$0.includeLearned && $0.transcriptCount == 0 } == true)
        t.check("memory only: an app with no note and no names is today's path", plan(plain, profile()) == nil && plan(plain, nil) == nil
                && plan(plain, profile(note: "  ")) == nil)
        let off = AppContextOverride(mode: .off)
        t.check("memory only: an override of off sends nothing, memory or not, the engine On or not",
                plan(plain, profile(context: off, entries: entries, note: "casual")) == nil && plan(on, profile(context: off, entries: entries, note: "casual")) == nil)
        t.check("memory only: the engine's switch and an app's nearby are the full context",
                options(plan(on, written)).map { $0.enabled && !$0.memoryOnly && $0.transcriptCount == 2 } == true
                && options(plan(plain, profile(context: AppContextOverride(mode: .nearby), entries: entries))).map { !$0.memoryOnly && $0.transcriptCount == 0 } == true)
        let deepL = engine("deepl", base: url)
        let template = EngineConfig(name: "T", kind: .httpTemplate(HTTPTemplate(url: "http://127.0.0.1:1/t", body: "{}", resultPath: "t", batching: .jsonArray)))
        t.check("memory only: Apple, DeepL and an engine that owns its body get none", plan(nil, written) == nil && plan(deepL, written) == nil && plan(template, written) == nil)
        func needs(_ e: EngineConfig?, _ profiles: [AppProfile]) -> Bool { ContextPlan.needsWindow(settings(e, profiles: profiles)) }
        t.check("memory only: a window is read for the app's name only where memory is written and not turned off",
                needs(plain, [written]) && !needs(plain, [profile()]) && !needs(plain, [profile(context: off, entries: entries, note: "x")])
                && !needs(deepL, [written]) && !needs(nil, [written]))
        let social = "public.app-category.social-networking"
        func summary(_ e: EngineConfig?, _ p: AppProfile?, learned: Int = 0) -> SentSummary {
            ContextPreview.summary(engine: e, profile: p, appName: "Example Chat", category: social, learnedUsable: learned)
        }
        t.check("sent preview: memory only says the card, the note and the names, and no title or lines",
                summary(plain, written).text == "Sent: Example Chat · social · note · up to 1 name" && summary(plain, written).mode == .memoryOnly)
        t.check("sent preview: an override of off, no memory and Apple Translation are lines only",
                summary(plain, profile(context: off, entries: entries, note: "x")).text == "Sent: lines only" && summary(plain, profile()).mode == .linesOnly
                && summary(nil, written).mode == .linesOnly && summary(nil, written).engineName == nil)
        t.check("sent preview: an engine that is On says its lines, the window title on this Mac, and learned rows when they are on",
                summary(on, written).text == "Sent: Example Chat · social · window title · note · up to 1 name · 2 lines before · 2 lines after"
                && summary(engine("openai", base: url, context: EngineContext(enabled: true, previousLines: 2, useLearned: true)), written, learned: 3).names == 4
                && summary(on, written, learned: 3).names == 1)
        t.check("sent preview: a cloud engine says the window title only with its opt-in",
                !summary(engine("anthropic", base: url, context: EngineContext(enabled: true)), written).windowTitle
                && summary(engine("anthropic", base: url, context: EngineContext(enabled: true, includeTitle: true)), written).windowTitle)
        t.check("memory only: the footnote about sent lines is not triggered by written memory",
                !EnginePermissions.sendsContext(plain, profiles: [written]) && EnginePermissions.sendsContext(on, profiles: [written]))

        // The disclosure follows what is sent (addendum A1): an engine whose Context is off still names the apps whose memory goes.
        let seen = EnginePermissions.disclosure(plain, profiles: [written])
        t.check("disclosure: Context off and an app with written memory is disclosed - the app, no lines",
                seen.memoryOnly && !seen.lines && !seen.isEmpty && seen.memoryApps == [written.appName])
        let other = profile(mail, entries: entries)
        let nothing = [EnginePermissions.disclosure(plain, profiles: []), EnginePermissions.disclosure(plain, profiles: [profile(), profile(mail, note: "  ")]),
                       EnginePermissions.disclosure(plain, profiles: [profile(context: off, entries: entries, note: "x")]),
                       EnginePermissions.disclosure(deepL, profiles: [written]), EnginePermissions.disclosure(template, profiles: [written])]
        t.check("disclosure: no memory, an override of off, DeepL and a template say nothing beyond the lines",
                nothing.allSatisfy { $0.isEmpty })
        // 2026-10-19 (t3m1, lead's drift fix): this line used to say that an app on another engine says nothing for this one. The request
        // pairs the engine of the app IN FRONT with the profile of the app UNDER THE LENS (`ContextRoute`), so a lens over that app's window
        // while an app on this engine is in front sends its memory here: the app is disclosed for every engine that can be in front. FAIL
        // first: `routeChecks` below shows the old rule against the request itself.
        let elsewhere = AppProfile(bundleID: mail, appName: mail, source: "en", target: "ko", customEngineID: UUID(), entries: entries)
        t.check("disclosure: an app that names another engine is still disclosed for this one (a lens over it while this engine's app is in front)",
                EnginePermissions.disclosure(plain, profiles: [elsewhere]).memoryApps == [mail])
        let both = EnginePermissions.disclosure(on, profiles: [written, other, profile(context: off, entries: entries, note: "x")])
        t.check("disclosure: an engine that is On says the lines and every app whose memory goes, not the app that turned context off",
                both.lines && !both.memoryOnly && both.memoryApps == [written.appName, other.appName])
        func engineLine(_ e: EngineConfig, _ p: [AppProfile]) -> SentSummary { ContextPreview.engineSummary(engine: e, profiles: p, category: { _ in "public.app-category.social-networking" }) }
        t.check("sent preview of an engine: Context off and an app with memory says what that app is sent, not \"lines only\"",
                engineLine(plain, [written]).text == "Sent: com.example.chat · social · note · up to 1 name" && engineLine(plain, [written]).mode == .memoryOnly
                && engineLine(plain, []).text == "Sent: lines only" && engineLine(on, []).text == "Sent: Example Chat · social · window title · 2 lines before · 2 lines after")
    }

    // MARK: the learned-memory file (G50), pure parts

    @MainActor
    static func learnedFileChecks(_ t: Tally) {
        let usable = ContextMemory.LearnedRecord(entry: MemoryEntry(src: "Bob", dst: "밥", kind: .person, gender: .m, note: "a note", origin: .learned, uses: 3), sightings: 2, contradictions: 0)
        let waiting = ContextMemory.LearnedRecord(entry: MemoryEntry(src: "Carol", dst: "캐럴", origin: .learned), sightings: 1, contradictions: 0)
        let second = ContextMemory.LearnedRecord(entry: MemoryEntry(src: "Alice", dst: "앨리스", kind: .person, gender: .f, origin: .learned), sightings: 5, contradictions: 0)
        let rows = LearnedMemoryFile.rows(from: [usable, waiting, second])
        t.check("learned file: only rows a request may use go in, sorted by source", rows.map(\.src) == ["Alice", "Bob"])
        let data = LearnedMemoryFile.render(bundleID: chat, appName: "Example Chat", rows: rows, updated: Date(timeIntervalSince1970: 0))
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let fileRows = root["rows"] as? [[String: Any]] ?? []
        t.check("learned file: the keys are fixed and a row holds the pair, its kind and gender and nothing else",
                Set(root.keys) == ["app", "appName", "updated", "about", "rows"]
                && fileRows.count == 2 && fileRows.allSatisfy { Set($0.keys).isSubset(of: ["src", "dst", "kind", "gender"]) }
                && fileRows[0]["src"] as? String == "Alice" && fileRows[0]["gender"] as? String == "f" && fileRows[1]["note"] == nil
                && root["updated"] as? String == "1970-01-01T00:00:00Z")
        let text = String(decoding: data, as: UTF8.self)
        t.check("learned file: no note, count, time of use or waiting row", !text.contains("a note") && !text.contains("Carol") && !text.contains("uses")
                && !text.contains("sightings"))
        t.check("learned file: the same memory is the same bytes", data == LearnedMemoryFile.render(bundleID: chat, appName: "Example Chat", rows: rows.reversed().sorted { $0.src < $1.src }, updated: Date(timeIntervalSince1970: 0)))
        t.check("learned file: a bundle id is a file name and a path is not one",
                LearnedMemoryFile.fileName(for: chat) == "com.example.chat.json" && LearnedMemoryFile.fileName(for: "../evil/x y") == "..-evil-x-y.json"
                && LearnedMemoryFile.fileName(for: "..") == "app.json" && LearnedMemoryFile.fileName(for: "").hasSuffix(".json")
                && !LearnedMemoryFile.fileName(for: "a/b\\c:d").contains("/"))

        // At most one write per app in 5 s; a change inside the interval is written when it ends. Numbers, no clock.
        var g = LearnedWriteGate()
        let steps = [g.changed("a", at: 100), g.changed("a", at: 101), g.changed("a", at: 103), g.changed("b", at: 101)]
        t.check("write gate: the first change of an app writes now, a change within 5 s waits for the end of the interval, then it is pending, and apps are independent",
                steps == [.now, .later(4), .pending, .now], "\(steps)")
        g.flushed("a", at: 105)
        let later = [g.changed("a", at: 106), g.changed("a", at: 110), g.changed("a", at: 111)]
        t.check("write gate: after the waiting write, the interval starts again; 5 s after a write is due", later == [.later(4), .pending, .pending], "\(later)")
        var g2 = LearnedWriteGate()
        _ = g2.changed("a", at: 0)
        t.check("write gate: exactly 5 s later writes now, and the interval counts from that write", g2.changed("a", at: 5) == .now && g2.changed("a", at: 8) == .later(2))
    }

    // MARK: Off, end to end (G3)

    /// What the mock saw: request bodies, in order (`--dump`).
    final class Mock: @unchecked Sendable {
        let port: Int
        let dump: URL
        private let process = Process()
        private let exited = DispatchSemaphore(value: 0)

        init?(mode: String, flags: String = "native") {
            guard let port = Self.freePort() else { return nil }
            self.port = port
            dump = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mwoyeo-ctx-\(getpid())-\(UUID().uuidString)")
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-I", root.appendingPathComponent("tools/mock-openai/server.py").path, "\(port)", mode, flags, "--dump", dump.path]
            process.standardError = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { [exited] _ in exited.signal() }
            guard (try? process.run()) != nil else { return nil }
            for _ in 0..<100 {
                if Self.accepts(port) { return }
                Thread.sleep(forTimeInterval: 0.05)
            }
            stop()
            return nil
        }

        var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

        func stop() {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 10) == .success { exited.signal() }
            try? FileManager.default.removeItem(at: dump)
        }

        /// The request bodies so far, oldest first.
        var bodies: [String] {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dump.path)) ?? []).sorted()
            return names.map { String(decoding: (try? Data(contentsOf: dump.appendingPathComponent($0))) ?? Data(), as: UTF8.self) }
        }

        private static func freePort() -> Int? {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: 0,
                                   sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard ok == 0 else { return nil }
            var out = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &out) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
            return Int(UInt16(bigEndian: out.sin_port))
        }

        private static func accepts(_ port: Int) -> Bool {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET),
                                   sin_port: UInt16(port).bigEndian, sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
                                   sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
            return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
        }
    }

    /// A request body read: every string in it, and the JSON of the user's last message.
    struct Sent {
        let text: String
        let last: [String: Any]

        init(_ body: String) {
            let root = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:]
            var strings: [String] = []
            func walk(_ v: Any) {
                if let s = v as? String { strings.append(s) } else if let a = v as? [Any] { a.forEach(walk) } else if let d = v as? [String: Any] { d.values.forEach(walk) }
            }
            walk(root)
            text = strings.joined(separator: "\n")
            let content = (root["messages"] as? [[String: Any]])?.last?["content"]
            let raw = (content as? String) ?? ((content as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? "")
            last = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
        }

        var items: [String] { ((last["translate"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String } }
        var before: [String] { (last["context_before"] as? [String]) ?? [] }
        var after: [String] { (last["context_after"] as? [String]) ?? [] }
        var memory: [String] { (last["memory"] as? [String]) ?? [] }
    }

    @MainActor
    static func offChecks(_ t: Tally) async {
        let first = ["Hello there, welcome back", "See you tomorrow at nine"], second = ["See you tomorrow at nine", "The meeting is moved to noon"]
        for label in ["openai", "anthropic", "deepl"] {
            guard let mock = Mock(mode: "ok") else { t.check("\(label): the mock server starts", false); continue }
            defer { mock.stop() }
            let off = EngineContext(enabled: false, previousLines: 5, includeTitle: true, useLearned: true, deepLInstructions: true)
            let variants: [(name: String, context: EngineContext?, profiles: [AppProfile], lensed: Bool)] = [
                ("no context argument", nil, [], false),
                ("(a) no context key", nil, [], true),
                ("(b) context enabled: false", off, [], true),
                ("(c) a profile override of off", EngineContext(enabled: true, includeTitle: true, useLearned: true),
                 [profile(chat, context: AppContextOverride(mode: .off)), profile(mail, context: AppContextOverride(mode: .off))], true),
                // The default path with a profile that remembers only languages: no memory, so nothing to send (the memory-only gate).
                ("(d) profiles with no memory", nil, [profile(chat), profile(mail)], true),
                ("(e) written memory and an override of off", EngineContext(enabled: true, includeTitle: true),
                 [profile(chat, context: AppContextOverride(mode: .off), entries: [MemoryEntry(src: "Alice", dst: "앨리스")], note: "casual"),
                  profile(mail, context: AppContextOverride(mode: .off), entries: [MemoryEntry(src: "Alice", dst: "앨리스")], note: "casual")], true),
            ] + (label == "deepl" ? [("(g) written memory, DeepL (it takes memory only through its own opt-in)", nil,
                                     [profile(chat, entries: [MemoryEntry(src: "Alice", dst: "앨리스")], note: "casual"),
                                      profile(mail, entries: [MemoryEntry(src: "Alice", dst: "앨리스")], note: "casual")], true)] : [])
            var keysOf: [Set<String>] = []
            for v in variants {
                let e = engine(label, base: mock.base, context: v.context)
                let s = service(settings(e, profiles: v.profiles, glossary: "Mwoyeo = 뭐여"))
                let start = mock.bodies.count
                // Two lenses of two apps translating in turn.
                _ = await s.translate(first, context: v.lensed ? lens(chat, id: "L1", screen: first, below: ["next line"]) : nil)
                _ = await s.translate(second, context: v.lensed ? lens(mail, title: "Inbox", id: "L2", screen: second, above: ["above line"]) : nil)
                let got = Array(mock.bodies.dropFirst(start))
                t.check("\(label) Off, \(v.name): the request bytes are main's", got == Golden.bodies[label],
                        "\(got.count) requests, first difference at call \(Array(zip(got, Golden.bodies[label] ?? [])).firstIndex { $0.0 != $0.1 }.map(String.init) ?? "-")")
                let stores = s.storeCounts
                let cachedCount = s.cachedCount
                let hit = s.cached("See you tomorrow at nine") != nil
                // Only the OpenAI-style mock answers in the target script, so only its lines are kept (and then they are three, one hit).
                let expectCached = label == "openai" ? 3 : 0
                t.check("\(label) Off, \(v.name): the cache holds and hits as before", cachedCount == expectCached && hit == (label == "openai")
                        && stores.values.reduce(0, +) == expectCached, "cached \(cachedCount), stored \(stores.values.reduce(0, +))")
                t.check("\(label) Off, \(v.name): one global namespace, none of the context's", stores.keys.allSatisfy { !$0.contains("|ctx:") } && stores.count == (expectCached == 0 ? 0 : 1)
                        && stores.keys.allSatisfy { $0.hasPrefix("en>ko|ext:00000000:") })
                keysOf.append(Set(stores.keys))
            }
            t.check("\(label) Off: the four variants use the same namespace", keysOf.dropFirst().allSatisfy { $0 == keysOf[0] })
        }
    }

    // MARK: On (G4, G5)

    @MainActor
    static func onChecks(_ t: Tally) async {
        let b1 = [line("Alice sent the first photo"), line("Bob liked the first photo")]
        let b2 = [line("Alice sent the second photo"), line("Bob liked the second photo")]
        let b3 = [line("Alice sent the third photo"), line("Bob liked the third photo")]
        let below = [line("Carol is typing now"), line("Dave is online")]
        let screen = b1 + b2 + b3 + below

        guard let mock = Mock(mode: "terms") else { t.check("the mock server starts", false); return }
        defer { mock.stop() }
        let two = EngineContext(enabled: true, previousLines: 2)
        let e = engine("openai", base: mock.base, context: two)
        let s = service(settings(e))

        // Three batches: neighbours below, and exactly the 2 previous lines.
        func send(_ s: TranslationService, _ items: [String], _ l: LensContext) async -> (Sent, TranslationOutcome) {
            let n = mock.bodies.count
            let outcome = await s.translate(items, context: l)
            let bodies = mock.bodies
            return (Sent(bodies.count > n ? bodies[n] : "{}"), outcome)
        }
        let l = lens(screen: screen, below: below)
        let (r1, o1) = await send(s, b1, l)
        t.check("On: the first batch carries its items, the lines below it, and no previous line",
                r1.items == b1 && r1.after == below && r1.before.isEmpty && o1.translations.count == 2)
        t.check("On: the card says the app, its category and (on this Mac) the window title",
                r1.text.contains("Document: Example Chat (social), window \"Alice\"."))
        let (r2, _) = await send(s, b2, l)
        t.check("On: the second batch carries the first batch as its previous lines", r2.items == b2 && r2.before == b1)
        let (r3, _) = await send(s, b3, l)
        t.check("On: the third batch carries exactly 2 previous lines, the last 2 read", r3.items == b3 && r3.before == b2 && r3.after == below)
        let before = mock.bodies.count
        let again = await s.translate(b3, context: l)
        t.check("On: a batch already translated in this thread is served from memory, no request", mock.bodies.count == before && again.translations.count == 2)
        t.check("On: its translations are not in the global namespace", s.cached(b3[0]) == nil && s.cached(b1[0]) == nil)
        let stores = s.storeCounts
        t.check("On: they are stored under the thread's namespace", !stores.isEmpty && stores.keys.allSatisfy { $0.contains("|ctx:") })
        let usage = await s.contextUsage(for: chat)
        t.check("On: usage counts requests and cached tokens", usage.requests == 3 && usage.prompt == 3000 && usage.cached == 2400 && usage.completion == 150,
                "requests \(usage.requests), prompt \(usage.prompt), cached \(usage.cached)")
        t.check("On: nothing but numbers is kept as usage", !String(describing: usage).contains(sentinel))

        // A thread is a document of an app: a new app, a new title, back again.
        let s2 = service(settings(e))
        let a1 = lens(screen: screen)
        _ = await send(s2, b1, a1)
        let (m1, _) = await send(s2, b2, lens(mail, title: "Inbox", screen: screen))
        t.check("On: another app is a new thread with an empty transcript", m1.before.isEmpty && m1.text.contains("Document: Example Mail (productivity)"))
        let (k1, _) = await send(s2, b3, lens(title: "Bob", screen: screen))
        t.check("On: a confirmed title change is a new thread", k1.before.isEmpty && k1.text.contains("window \"Bob\""))
        let (k2, _) = await send(s2, [line("Alice sent the fourth photo")], lens(title: "Alice", screen: screen))
        t.check("On: A, B, A resumes A's thread", k2.before == b1)
        var ja = settings(e, target: "ja")
        ja.glossary = ""
        await s2.update(settings: ja)
        let (p1, _) = await send(s2, [line("Alice sent the fifth photo")], lens(title: "Alice", screen: screen))
        t.check("On: a pair change is a new key, a new thread", p1.before.isEmpty)
        await s2.update(settings: settings(e))
        let (p2, _) = await send(s2, [line("Alice sent the sixth photo")], lens(title: "Alice", screen: screen))
        t.check("On: going back to the pair resumes its thread", p2.before == [b1[1], line("Alice sent the fourth photo")])
        await s2.startFresh(for: chat)
        let n = mock.bodies.count
        let (f1, _) = await send(s2, b1, lens(title: "Alice", screen: screen))
        t.check("On: Start fresh drops the transcript and the cached lines", mock.bodies.count == n + 1 && f1.before.isEmpty)

        // Learning is opt-in; a term is used after 2 sightings.
        let off = service(settings(engine("openai", base: mock.base, context: EngineContext(enabled: true, useLearned: false))))
        _ = await off.translate([line("Alice greeted me")], context: lens())
        _ = await off.translate([line("Alice waved at me")], context: lens())
        let none = await off.learnedRows(for: chat)
        t.check("On without useLearned: the reply's terms record nothing", none.isEmpty)
        let learn = service(settings(engine("openai", base: mock.base, context: EngineContext(enabled: true, previousLines: 0, useLearned: true))))
        let (c1, _) = await send(learn, [line("Alice greeted me")], lens())
        t.check("With useLearned the request asks for terms", c1.text.contains("\"terms\""))
        let rows1 = await learn.learnedRows(for: chat)
        t.check("With useLearned a first sighting is recorded, not used", rows1.count == 1 && rows1[0].isUsable == false)
        let (c2, _) = await send(learn, [line("Alice waved at me")], lens())
        t.check("It is still not in the second request", c2.memory.isEmpty)
        let (c3, _) = await send(learn, [line("Alice left early")], lens())
        t.check("After 2 sightings the third request carries it", c3.memory.count == 1 && c3.memory[0].hasPrefix("Alice -> T_Alice"))
        let (c0, _) = await send(s, [line("Frank has no term")], lens(screen: screen))
        t.check("Without useLearned the request does not ask for terms", !c0.text.contains("\"terms\""))

        // A profile override alone turns context on (intended, design §9: writing it is the opt-in).
        let nearby = service(settings(engine("openai", base: mock.base), profiles: [profile(chat, context: AppContextOverride(mode: .nearby))]))
        let (w1, _) = await send(nearby, [line("Alice nearby one")], lens(screen: screen, below: below))
        t.check("A nearby override alone is On: the lines below go, no previous line", w1.after == below && w1.before.isEmpty
                && w1.text.contains("Document: Example Chat"))
        let (w2, _) = await send(nearby, [line("Alice nearby two")], lens(screen: screen, below: below))
        t.check("nearby never sends previous lines", w2.before.isEmpty)

        // The user's memory goes along only when it is written; names are rows of the request.
        let written = profile(chat, context: AppContextOverride(mode: .conversation, previousLines: 0),
                              entries: [MemoryEntry(src: "Alice", dst: "앨리스", kind: .person, gender: .f)], note: "casual chat between friends")
        let mem = service(settings(engine("openai", base: mock.base), profiles: [written]))
        let (u1, _) = await send(mem, [line("Alice sent the photo")], lens(screen: screen))
        t.check("A written entry and note go to the engine", u1.memory.first?.hasPrefix("Alice -> 앨리스") == true && u1.text.contains("casual chat between friends"))
        let (u2, _) = await send(mem, [line("Bob sent the photo")], lens(screen: screen))
        t.check("An entry not in the items is not sent", u2.memory.isEmpty)

        // The window title leaves this Mac only with the user's opt-in; the app name always goes (design §8.5).
        for (title, label) in [(false, "off"), (true, "on")] {
            guard let cloud = Mock(mode: "terms") else { continue }
            defer { cloud.stop() }
            let ce = engine("anthropic", base: cloud.base, context: EngineContext(enabled: true, previousLines: 2, includeTitle: title))
            _ = await service(settings(ce)).translate([line("Alice sent the photo")], context: lens(screen: screen))
            let sent = Sent(cloud.bodies.first ?? "{}")
            t.check("Anthropic (cloud): the app name goes, the window title only with includeTitle \(label)",
                    sent.text.contains("Document: Example Chat (social)") && sent.text.contains("window \"Alice\"") == title)
        }
        if let deepl = Mock(mode: "terms") {
            defer { deepl.stop() }
            let de = engine("deepl", base: deepl.base, context: EngineContext(enabled: true, previousLines: 2))
            _ = await service(settings(de)).translate([line("Alice sent the photo")], context: lens(screen: screen, below: below))
            let body = deepl.bodies.first ?? "{}"
            t.check("DeepL: the lines go in `context`, `custom_instructions` only with its opt-in", body.contains("\"context\"") && !body.contains("custom_instructions"))
        }
    }

    // MARK: memory only, and nearby, end to end

    /// One lensed call: the request body the mock saw (read) and the outcome.
    @MainActor
    static func send(_ mock: Mock, _ service: TranslationService, _ items: [String], _ l: LensContext) async -> (sent: Sent, body: String, outcome: TranslationOutcome) {
        let n = mock.bodies.count
        let outcome = await service.translate(items, context: l)
        let bodies = mock.bodies
        let body = bodies.count > n ? bodies[n] : "{}"
        return (Sent(body), body, outcome)
    }

    @MainActor
    static func memoryOnlyChecks(_ t: Tally) async {
        let b1 = [line("Alice sent the first photo"), line("Bob liked the first photo")]
        let b2 = [line("Alice sent the second photo"), line("Bob liked the second photo")]
        let above = ["Above one \(sentinel)", "Above two \(sentinel)"], below = ["Carol is typing now \(sentinel)", "Dave is online \(sentinel)"]
        let screen = above + b1 + b2 + below
        guard let mock = Mock(mode: "terms") else { t.check("memory only: the mock server starts", false); return }
        defer { mock.stop() }
        let title = "Project Zebra"
        let doc = lens(title: title, screen: screen, above: above, below: below)
        let alice = MemoryEntry(src: "Alice", dst: "앨리스", kind: .person, gender: .f)
        let written = profile(chat, entries: [alice], note: "casual chat between friends")

        // The engine's Context is off; the app has a note and a name: the card, the note and the matching name, nothing of the screen.
        let held = service(settings(engine("openai", base: mock.base), profiles: [written]))
        let (r1, _, o1) = await send(mock, held, b1, doc)
        t.check("memory only: the request carries the items, the card, the note and the matching name",
                r1.items == b1 && o1.translations.count == 2 && r1.text.contains("Document: Example Chat (social).")
                && r1.text.contains("casual chat between friends") && r1.memory.first?.hasPrefix("Alice -> 앨리스") == true && r1.memory.count == 1)
        t.check("memory only: no neighbours, no earlier lines, no who's who and no window title",
                r1.before.isEmpty && r1.after.isEmpty && r1.last["referents"] == nil && !r1.text.contains("Zebra") && !r1.text.contains("window")
                && above.allSatisfy { !r1.text.contains($0) } && below.allSatisfy { !r1.text.contains($0) })
        let (r2, _, _) = await send(mock, held, b2, doc)
        t.check("memory only: the second batch does not carry the first, and still no screen", r2.items == b2 && r2.before.isEmpty && r2.after.isEmpty
                && b1.allSatisfy { !r2.text.contains($0) } && !r2.text.contains("Zebra"))
        let stores = held.storeCounts
        t.check("memory only: the translations are kept under the memory's namespace, not the global one",
                !stores.isEmpty && stores.keys.allSatisfy { $0.contains("|ctx:") } && held.cached(b1[0]) == nil)
        let again = await held.translate(b2, context: doc)
        t.check("memory only: a line already translated is served from memory", again.translations.count == 2 && mock.bodies.count == 2)
        let usage = await held.contextUsage(for: chat)
        t.check("memory only: usage counts the requests", usage.requests == 2)

        // Learned rows are a switch of their own: a loud engine that is off sends no `terms` request and learns nothing.
        let loud = EngineContext(enabled: false, previousLines: 8, includeTitle: true, useLearned: true)
        let loudService = service(settings(engine("openai", base: mock.base, context: loud), profiles: [written]))
        let (l1, _, _) = await send(mock, loudService, b1, doc)
        _ = await send(mock, loudService, b2, doc)
        let loudLearned = await loudService.learnedRows(for: chat)
        t.check("memory only: useLearned of an engine that is off asks for no terms and records none",
                !l1.text.contains("\"terms\"") && l1.before.isEmpty && !l1.text.contains("Zebra") && loudLearned.isEmpty)

        // An override of off sends exactly what no profile sends.
        let reference = service(settings(engine("openai", base: mock.base), profiles: []))
        let (_, refBody, _) = await send(mock, reference, b1, doc)
        let offOverride = profile(chat, context: AppContextOverride(mode: .off), entries: [alice], note: "casual chat between friends")
        let offAlone = service(settings(engine("openai", base: mock.base), profiles: [offOverride]))
        let (offSent, offBody, _) = await send(mock, offAlone, b1, doc)
        t.check("memory only: an override of off sends the bytes of no profile at all (no card, no note, no name)",
                offBody == refBody && offSent.last["translate"] == nil && !offBody.contains("casual chat") && !offBody.contains("Document:"))
        let onOff = service(settings(engine("openai", base: mock.base, context: EngineContext(enabled: true, previousLines: 2)), profiles: [offOverride]))
        let (_, onOffBody, _) = await send(mock, onOff, b1, doc)
        t.check("memory only: an override of off wins over the engine's own switch too", onOffBody == refBody)

        // No memory written: a profile that remembers languages only sends today's bytes.
        let memoryless = service(settings(engine("openai", base: mock.base), profiles: [profile(chat)]))
        let (_, memorylessBody, _) = await send(mock, memoryless, b1, doc)
        t.check("memory only: a profile with no note and no name sends the bytes of no profile", memorylessBody == refBody)

        // Cloud: the card (app and category) goes, never the title.
        if let cloud = Mock(mode: "terms") {
            defer { cloud.stop() }
            let anthropic = service(settings(engine("anthropic", base: cloud.base, context: EngineContext(enabled: false, includeTitle: true)), profiles: [written]))
            let (a1, _, _) = await send(cloud, anthropic, b1, doc)
            t.check("memory only: Anthropic gets the card, the note and the name, and no window title even with includeTitle",
                    a1.text.contains("Document: Example Chat (social).") && a1.text.contains("casual chat between friends") && !a1.text.contains("Zebra")
                    && a1.memory.first?.hasPrefix("Alice -> 앨리스") == true && a1.before.isEmpty && a1.after.isEmpty)
        }
        // DeepL takes the memory only through its own opt-in: written memory changes nothing for it.
        if let d = Mock(mode: "terms"), let dr = Mock(mode: "terms") {
            defer { d.stop(); dr.stop() }
            let withMemory = service(settings(engine("deepl", base: d.base), profiles: [written]))
            let without = service(settings(engine("deepl", base: dr.base), profiles: []))
            let (_, deeplBody, _) = await send(d, withMemory, b1, doc)
            let (_, deeplRef, _) = await send(dr, without, b1, doc)
            t.check("memory only: DeepL with written memory sends the bytes of no memory", deeplBody == deeplRef && !deeplBody.contains("casual chat"))
        }

        // Nearby (G8): the lines above the text on screen go with the lines below, and the thread's history does not.
        let nearby = service(settings(engine("openai", base: mock.base), profiles: [profile(chat, context: AppContextOverride(mode: .nearby))]))
        let (n1, _, _) = await send(mock, nearby, b1, lens(screen: screen, above: above, below: below))
        t.check("nearby: the lines above the text go, and the lines below", n1.before == above && n1.after == below)
        let aboveTwo = ["Above three \(sentinel)"]
        let (n2, _, _) = await send(mock, nearby, b2, lens(screen: screen, above: aboveTwo, below: below))
        t.check("nearby: only the lines right above this batch, not the batch read before", n2.before == aboveTwo && n2.after == below && b1.allSatisfy { !n2.text.contains($0) })
        let zero = service(settings(engine("openai", base: mock.base, context: EngineContext(enabled: true, previousLines: 0))))
        let (z1, _, _) = await send(mock, zero, b1, lens(screen: screen, above: above, below: below))
        t.check("nearby: an engine with previousLines 0 sends the same neighbours", z1.before == above && z1.after == below)
        let (n3, _, _) = await send(mock, nearby, [line("Zed arrived")], lens(screen: screen, below: below))
        t.check("nearby: with no line above there is no context_before", n3.before.isEmpty && n3.last["context_before"] == nil)
    }

    // MARK: the disclosure follows the request (engine of the app in front, memory of the app under the lens)

    /// A request pairs the engine of the app in front with the profile of the app under the lens (`ContextRoute`). The disclosures
    /// (`EnginePermissions.memoryProfiles`, the Memory sheet's "Also sent to …") must name what that rule sends, whichever app is in front.
    @MainActor
    static func routeChecks(_ t: Tally) async {
        guard let mock = Mock(mode: "terms") else { t.check("route: the mock server starts", false); return }
        defer { mock.stop() }
        let dead = URL(string: "http://127.0.0.1:9")!
        let x = engine("openai", base: mock.base), y = engine("anthropic", base: dead), d = engine("deepl", base: dead)
        let note = "casual chat between friends"
        // A is in front and uses engine X; B (the lens covers its window) uses Y and has written memory.
        let a = AppProfile(bundleID: chat, appName: "A Chat", source: "en", target: "ko", customEngineID: x.id)
        let b = AppProfile(bundleID: mail, appName: "B Mail", source: "en", target: "ko", customEngineID: y.id, note: note)
        var s = AppSettings()
        s.sourceLanguage = "en"; s.targetLanguage = "ko"
        s.engines = [y, x]; s.customEngineID = y.id; s.appProfiles = [a, b]

        let cross = ContextRoute.pair(settings: s.effective(frontmost: chat), lens: mail)
        t.check("route: a lens over B while A is in front pairs A's engine with B's profile",
                cross.engine?.id == x.id && cross.profile?.bundleID == mail && cross.options.memoryOnly)
        t.check("route: B's memory is disclosed for A's engine, although B names another engine",
                EnginePermissions.memoryProfiles(x, profiles: s.appProfiles).map(\.bundleID) == [mail]
                && EnginePermissions.disclosure(x, profiles: s.appProfiles).memoryApps == ["B Mail"],
                "\(EnginePermissions.memoryProfiles(x, profiles: s.appProfiles).map(\.bundleID))")
        t.check("route: B's own engine is disclosed for B too", EnginePermissions.memoryProfiles(y, profiles: s.appProfiles).map(\.bundleID) == [mail])
        t.check("route: B's sheet names its own engine first and A's engine as the other receiver",
                ContextRoute.own(mail, in: s).engine?.id == y.id && ContextRoute.otherReceivers(of: mail, in: s).map(\.id) == [x.id])
        var one = s
        one.appProfiles = [b]
        t.check("route: with one engine for every app there is no other receiver",
                ContextRoute.otherReceivers(of: mail, in: one).isEmpty && ContextRoute.otherReceivers(of: mail, in: AppSettings()).isEmpty)

        // The request itself: the service of the settings in effect while A is in front, a lens over B, A's engine is the mock.
        let svc = service(s.effective(frontmost: chat))
        let (sent, _, _) = await send(mock, svc, [line("Mail from Alice")], lens(mail, title: "Inbox", screen: [line("Mail from Alice")]))
        t.check("route: the request to A's engine carries B's note, as disclosed", sent.text.contains(note) && sent.text.contains("Document: Example Mail"))

        // Every state of base engine, A's profile and B's profile: the engines a lens can be paired with are the ones disclosed.
        var variants = 0, mismatches = 0, lastMismatch = ""
        let engines: [EngineConfig?] = [nil, x, y, d]
        let overrides: [AppContextOverride?] = [nil, AppContextOverride(mode: .off), AppContextOverride(mode: .nearby)]
        for base in engines {
            for aEngine in engines {
                for aHasMemory in [false, true] {
                    for bEngine in engines {
                        for bContext in overrides {
                            var v = AppSettings()
                            v.engines = [x, y, d]
                            v.customEngineID = base?.id
                            let pa = AppProfile(bundleID: chat, appName: "A Chat", source: "en", target: "ko", customEngineID: aEngine?.id,
                                                note: aHasMemory ? "a note" : "")
                            let pb = AppProfile(bundleID: mail, appName: "B Mail", source: "en", target: "ko", customEngineID: bEngine?.id,
                                                note: note, context: bContext)
                            v.appProfiles = aEngine == nil && !aHasMemory ? [pb] : [pa, pb]
                            variants += 1
                            let used = Set(ContextRoute.fronts(of: v).map { v.effective(frontmost: $0).customEngineID }.compactMap { $0 })
                            for e in v.engines {
                                let kind = LayoutKind.engine(e.kind)
                                var got = Set<String>()
                                for p in v.appProfiles {
                                    for pairing in ContextRoute.pairings(lens: p.bundleID, in: v)
                                    where pairing.engine?.id == e.id && pairing.options.enabled && kind.sendsMemory(pairing.options) && p.hasMemory {
                                        got.insert(p.bundleID)
                                    }
                                }
                                let said = Set(EnginePermissions.memoryProfiles(e, profiles: v.appProfiles).map(\.bundleID))
                                // An engine nobody has chosen yet is disclosed as if it were chosen: a superset of what the walk finds.
                                let ok = used.contains(e.id) ? got == said : got.isSubset(of: said)
                                if !ok { mismatches += 1; lastMismatch = "base \(base?.name ?? "-") A \(aEngine?.name ?? "-")/\(aHasMemory) B \(bEngine?.name ?? "-")/\(bContext?.mode.rawValue ?? "-") engine \(e.name): walk \(got.sorted()) said \(said.sorted())" }
                            }
                        }
                    }
                }
            }
        }
        t.check("route: over \(variants) states of base engine and two profiles, the disclosed memory is the memory the request path sends",
                mismatches == 0 && variants == 4 * 4 * 2 * 4 * 3, "\(mismatches) mismatches, last: \(lastMismatch)")
    }

    // MARK: the learned-memory file, written (G50)

    /// Everything the writer reads and does, held by the check: the settings, the clock, the folder, and the writes that wait.
    @MainActor
    final class FileWorld {
        var now: TimeInterval = 100
        var settings = AppSettings()
        var scheduled: [(seconds: TimeInterval, body: @MainActor () async -> Void)] = []
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mwoyeo-lm-\(getpid())-\(UUID().uuidString)")
        deinit { try? FileManager.default.removeItem(at: dir) }
    }

    @MainActor
    static func learnedFileRunChecks(_ t: Tally) async {
        guard let mock = Mock(mode: "terms") else { t.check("learned file: the mock server starts", false); return }
        defer { mock.stop() }
        let learning = EngineContext(enabled: true, previousLines: 0, useLearned: true)
        let svc = service(settings(engine("openai", base: mock.base, context: learning)))
        let b1 = [line("Alice sent the first photo"), line("Bob liked the first photo")]
        let b2 = [line("Alice sent the second photo"), line("Bob liked the second photo")]
        let screen = b1 + b2
        _ = await send(mock, svc, b1, lens(screen: screen))
        let firstOnly = await svc.learnedRows(for: chat)
        t.check("learned file: one sighting is a row that waits, not one that is used", firstOnly.count == 2 && firstOnly.allSatisfy { !$0.isUsable })
        _ = await send(mock, svc, b2, lens(screen: screen))
        let usable = await svc.learnedRows(for: chat).filter(\.isUsable)
        t.check("learned file: two sightings make both rows usable", usable.map(\.entry.src).sorted() == ["Alice", "Bob"])

        let world = FileWorld()
        world.settings.appProfiles = [profile(chat)]
        let file = world.dir.appendingPathComponent("Memory/com.example.chat.json")
        let writer = LearnedMemoryWriter(.init(
            settings: { world.settings },
            access: { _ in ExportFolder.Access(url: world.dir, scoped: false) },
            records: { await svc.learnedRows(for: $0) },
            now: { world.now }, date: { Date(timeIntervalSince1970: 1_000) },
            after: { world.scheduled.append(($0, $1)) }))
        func contents() -> String { String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self) }

        // Save transcripts off: no file, nothing planned.
        let offTask = writer.changed(chat)
        t.check("learned file: Save transcripts off writes no file and plans none",
                offTask == nil && world.scheduled.isEmpty && !FileManager.default.fileExists(atPath: world.dir.appendingPathComponent("Memory").path))

        // On: the file holds the usable rows and no screen text.
        world.settings.savesTranscripts = true
        await writer.changed(chat)?.value
        let text = contents()
        let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        let rows = root["rows"] as? [[String: Any]] ?? []
        t.check("learned file: with Save transcripts on, Memory/<bundle id>.json holds the usable rows (source, translation, kind)",
                rows.compactMap { $0["src"] as? String } == ["Alice", "Bob"] && rows.compactMap { $0["dst"] as? String } == ["T_Alice", "T_Bob"]
                && root["app"] as? String == chat && root["appName"] as? String == chat && rows.allSatisfy { Set($0.keys).isSubset(of: ["src", "dst", "kind", "gender"]) })
        t.check("learned file: no screen text but the terms - not the sentinel, not a line, not a sentence", !rows.isEmpty && !text.contains(sentinel)
                && screen.allSatisfy { !text.contains($0) } && !text.contains("photo") && !text.contains("sent the"))

        // A second change within 5 s waits and reads the newest rows when it is due.
        world.now = 101
        let waiting = writer.changed(chat)
        world.now = 102
        let pending = writer.changed(chat)
        t.check("learned file: a change within 5 s of the write waits for the end of the interval, once", waiting == nil && pending == nil && world.scheduled.count == 1
                && world.scheduled.first?.seconds == 4)
        await svc.removeLearned(src: "Bob", for: chat)
        world.now = 105
        await world.scheduled.first?.body()
        let afterRemove = (try? JSONSerialization.jsonObject(with: Data(contents().utf8))) as? [String: Any]
        t.check("learned file: the waiting write holds the rows of the moment it is done (Bob was removed)",
                (afterRemove?["rows"] as? [[String: Any]])?.compactMap { $0["src"] as? String } == ["Alice"])

        // The last row goes: the file says so, it is not left with the old rows.
        await svc.forgetLearned(for: chat)
        world.now = 200
        await writer.changed(chat)?.value
        let emptied = (try? JSONSerialization.jsonObject(with: Data(contents().utf8))) as? [String: Any]
        t.check("learned file: after Forget learned the file has no rows", (emptied?["rows"] as? [Any])?.isEmpty == true)

        // An app that never learned anything gets no file.
        world.now = 300
        await writer.changed("com.example.other")?.value
        t.check("learned file: an app with no learned row and no file gets none",
                !FileManager.default.fileExists(atPath: world.dir.appendingPathComponent("Memory/com.example.other.json").path))

        // Turning Save transcripts off stops writing; what is there stays, as a transcript does.
        await svc.removeLearned(src: "Alice", for: chat)
        world.settings.savesTranscripts = false
        world.now = 400
        let stale = contents()
        let offAgain = writer.changed(chat)
        t.check("learned file: turning Save transcripts off leaves the file as it was", offAgain == nil && contents() == stale)

        // Turning it on again writes what was learned while it was off, without waiting for the next change.
        let c3 = [line("Alice sent the third photo"), line("Bob liked the third photo")]
        let c4 = [line("Alice sent the fourth photo"), line("Bob liked the fourth photo")]
        _ = await send(mock, svc, c3, lens(screen: c3 + c4))
        _ = await send(mock, svc, c4, lens(screen: c3 + c4))
        let whileOff = contents()
        world.settings.savesTranscripts = true
        world.now = 500
        for task in writer.savingTurnedOn(for: [chat]) { await task.value }
        let turnedOn = (try? JSONSerialization.jsonObject(with: Data(contents().utf8))) as? [String: Any]
        t.check("learned file: turning Save transcripts on writes the rows learned meanwhile",
                whileOff == stale && (turnedOn?["rows"] as? [[String: Any]])?.compactMap { $0["src"] as? String } == ["Alice", "Bob"]
                && !contents().contains(sentinel))
    }

    // MARK: pin, written to settings.json and read back (G5)

    @MainActor
    static func pinChecks(_ t: Tally) async {
        guard let mock = Mock(mode: "terms") else { t.check("pin: the mock server starts", false); return }
        defer { mock.stop() }
        let e = engine("openai", base: mock.base, context: EngineContext(enabled: true, previousLines: 0, useLearned: true))
        var s = settings(e, profiles: [profile(chat)])
        let svc = service(s)
        let b1 = [line("Alice sent the first photo"), line("Bob liked the first photo")]
        _ = await send(mock, svc, b1, lens(screen: b1))
        _ = await send(mock, svc, [line("Alice sent the second photo")], lens(screen: b1))
        let row = await svc.learnedRows(for: chat).first { $0.entry.src == "Alice" }
        var profiles = s.appProfiles
        let result = AppProfiles.pin(row?.entry, bundleID: chat, in: &profiles)
        s.appProfiles = profiles
        await svc.removeLearned(src: "alice", for: chat)
        let left = await svc.learnedRows(for: chat)
        t.check("pin: a usable learned row becomes a row of the profile and leaves the learned rows",
                row?.isUsable == true && result == .pinned && s.appProfiles[0].entries.map(\.src) == ["Alice"] && left.map(\.entry.src) == ["Bob"])

        // Through the app's own settings file and back.
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mwoyeo-pin-\(getpid())-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        SettingsFileStore(url: url).save(s)
        let data = (try? Data(contentsOf: url)) ?? Data()
        let read = SettingsFileCheck.read(data, over: AppSettings())
        let back = read.settings.appProfiles.first { $0.bundleID == chat }?.entries ?? []
        let fileText = String(decoding: data, as: UTF8.self)
        t.check("pin: it is in settings.json under appProfiles[].entries, with the pair fields only, and reads back as a user row",
                read.issues.isEmpty && back.map(\.src) == ["Alice"] && back.first?.dst == "T_Alice" && back.first?.origin == .user
                && fileText.contains("\"T_Alice\"") && !fileText.contains("\"origin\"") && !fileText.contains("\"uses\"") && !fileText.contains("sightings"))

        // The reloaded profile is what a new service sends: as a name of the user, nothing learned about it.
        var s2 = settings(e, profiles: read.settings.appProfiles)
        s2.glossary = ""
        let svc2 = service(s2)
        let (sent, _, _) = await send(mock, svc2, [line("Alice sent the third photo")], lens(screen: b1))
        let learnedAgain = await svc2.learnedRows(for: chat)
        t.check("pin: the reloaded row goes in the request as the user's own, and is not learned again",
                sent.memory.first?.hasPrefix("Alice -> T_Alice") == true && learnedAgain.allSatisfy { $0.entry.src != "Alice" })
    }

    /// Counts the notices a service raised (its handler runs on any task).
    final class IssueCount: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    // MARK: Apple Translation (G6)

    @MainActor
    static func appleChecks(_ t: Tally) async {
        // The harness engine returns "⟦ko⟧ " + the text it was given, so the answer shows exactly what Apple received.
        setenv("MWOYEO_FAKE_ENGINE", "slow:5", 1)
        defer { unsetenv("MWOYEO_FAKE_ENGINE") }
        let text = "Hello there, welcome back"
        let entries = [MemoryEntry(src: "welcome", dst: "환영")]
        func run(_ s: AppSettings, context: LensContext?) async -> String? {
            await service(s).translate([text], context: context).translations[text]
        }
        let today = await run(settings(nil), context: nil)
        t.check("Apple: today's text goes to Apple", today == "⟦ko⟧ \(text)")

        let nearby = profile(chat, context: AppContextOverride(mode: .nearby), entries: entries)
        t.check("Apple with a nearby profile and pinned terms off: today's text", await run(settings(nil, profiles: [nearby]), context: lens()) == today)
        t.check("Apple with written memory (a note and a name) and no pinned terms on: today's text",
                await run(settings(nil, profiles: [profile(chat, entries: entries, note: "casual")]), context: lens()) == today)
        var pinsOff = settings(nil, profiles: [nearby])
        pinsOff.appleUsesPinnedTerms = false
        t.check("Apple with pinned terms off and an entry: today's text", await run(pinsOff, context: lens()) == today)

        var pinsOn = settings(nil, profiles: [profile(chat, entries: entries)])
        pinsOn.appleUsesPinnedTerms = true
        let inserted = ApplePreinsertion.insert(into: text, entries: entries, appleUsesPinnedTerms: true)
        let pinned = await run(pinsOn, context: lens())
        t.check("Apple with pinned terms on and an entry: Core's pre-inserted text goes to Apple", !inserted.isEmpty
                && inserted.text == "Hello there, 환영 back" && pinned == "⟦ko⟧ \(inserted.text)")
        t.check("Apple with pinned terms on, another app's lens: today's text", await run(pinsOn, context: lens(mail)) == today)
        t.check("Apple with pinned terms on and no lens context: today's text", await run(pinsOn, context: nil) == today)

        // An engine that fails hands its lines to Apple and rests, with context On as with it Off: the same answer, the same notice,
        // and while it rests no request goes to it.
        for (name, context) in [("Off", nil), ("On", EngineContext(enabled: true, previousLines: 2))] as [(String, EngineContext?)] {
            guard let bad = Mock(mode: "garbage") else { t.check("the failing mock starts", false); continue }
            defer { bad.stop() }
            setenv("MWOYEO_FAKE_ENGINE", "slow:5", 1)
            let s = service(settings(engine("openai", base: bad.base, context: context)))
            let notices = IssueCount()
            await s.setIssueHandler { issue in if case .engineUnavailable? = issue { notices.bump() } }
            let first = await s.translate([text], context: lens())
            let asked = bad.bodies.count
            let second = await s.translate(["See you tomorrow at nine"], context: lens())
            t.check("\(name): an engine that fails hands the line to Apple, who answers",
                    asked == 1 && first.translations[text] == "⟦ko⟧ \(text)" && !first.batchFailed && !first.cancelled && first.failed.isEmpty,
                    "requests \(asked), translated \(first.translations.count)")
            t.check("\(name): while the engine rests no request goes to it, and Apple still answers",
                    bad.bodies.count == asked && second.translations["See you tomorrow at nine"] == "⟦ko⟧ See you tomorrow at nine")
            t.check("\(name): the lens is told once that the engine is unavailable", notices.count == 1, "notices \(notices.count)")
        }

        // An answer that dropped the pinned term is asked again as the text stood: never worse than today.
        setenv("MWOYEO_FAKE_ENGINE", "drop:환영", 1)
        t.check("Apple that drops the pinned term: the plain text is asked again", await run(pinsOn, context: lens()) == today)
    }
}

/// What the unmodified tree sent for the G3 scenario, recorded 2026-10-19 from a plain `cp -R` copy of main bcf7d9a (the tree this branch
/// started from; its request path is that of 7c67d1d) built with a harness that called `TranslationService.translate(texts)` twice per engine
/// kind against `tools/mock-openai/server.py ok native --dump`. The bytes the three Off variants must give, call by call.
private enum Golden {
    static let bodies: [String: [String]] = [
        "openai": [
            #"{"messages":[{"content":"Translate each line of the user's JSON into Korean from English. Keep names, numbers, emoji, URLs and @handles unchanged. Give one translation per line, in the same order. Follow these glossary pairs exactly:\nMwoyeo → 뭐여\nReply with only {\"translations\": [...]}.","role":"system"},{"content":"{\"lines\":[\"Hello there, welcome back\",\"See you tomorrow at nine\"]}","role":"user"}],"model":"m1","stream":false,"temperature":0}"#,
            #"{"messages":[{"content":"Translate each line of the user's JSON into Korean from English. Keep names, numbers, emoji, URLs and @handles unchanged. Give one translation per line, in the same order. Follow these glossary pairs exactly:\nMwoyeo → 뭐여\nReply with only {\"translations\": [...]}.","role":"system"},{"content":"{\"lines\":[\"The meeting is moved to noon\"]}","role":"user"}],"model":"m1","stream":false,"temperature":0}"#,
        ],
        "anthropic": [
            #"{"max_tokens":452,"messages":[{"content":"{\"lines\":[\"Hello there, welcome back\",\"See you tomorrow at nine\"]}","role":"user"}],"model":"claude-haiku-5-5","system":"Translate each line of the user's JSON into Korean from English. Keep names, numbers, emoji, URLs and @handles unchanged. Give one translation per line, in the same order. Follow these glossary pairs exactly:\nMwoyeo → 뭐여\nReply with only {\"translations\": [...]}."}"#,
            #"{"max_tokens":464,"messages":[{"content":"{\"lines\":[\"See you tomorrow at nine\",\"The meeting is moved to noon\"]}","role":"user"}],"model":"claude-haiku-5-5","system":"Translate each line of the user's JSON into Korean from English. Keep names, numbers, emoji, URLs and @handles unchanged. Give one translation per line, in the same order. Follow these glossary pairs exactly:\nMwoyeo → 뭐여\nReply with only {\"translations\": [...]}."}"#,
        ],
        "deepl": [
            #"{"formality":"prefer_more","source_lang":"EN","target_lang":"KO","text":["Hello there, welcome back","See you tomorrow at nine"]}"#,
            #"{"formality":"prefer_more","source_lang":"EN","target_lang":"KO","text":["See you tomorrow at nine","The meeting is moved to noon"]}"#,
        ],
    ]
}
#endif

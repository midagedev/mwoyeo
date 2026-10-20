#if !MAS
import AppKit
import MwoyeoCore
import MwoyeoEngines

/// trust1 (2026-10-21): an added engine does what the app promises. The secret store of scratch runs, a line that reaches a busy engine, and
/// the transcript naming who really translated a line. Through `TranslationService` against the mock engine of `ContextChecks` and the
/// harness Apple (`MWOYEO_FAKE_ENGINE`, which answers "⟦ko⟧ <text>"; the mock engine's answer ends in "번역", see `Mock`).
extension ContextChecks {
    @MainActor
    static func trustChecks(_ t: Tally) async {
        secretChecks(t)
        await busyEngineChecks(t)
        await translatedByChecks(t)
    }

    // MARK: the key of a scratch run

    /// `MWOYEO_ENGINE_KEY` is the key of every engine nobody stored one for, when `MWOYEO_MEMORY_SECRETS` keeps the keys in memory (the
    /// capture and film path); nowhere else. FAIL-first: the store of a scratch run was `MemorySecrets()`, empty, so the first line failed.
    static func secretChecks(_ t: Tally) {
        let engine = UUID(), other = UUID()
        func key(_ store: any SecretStore, _ id: UUID) -> String? { (try? store.secret(for: id)) ?? nil }
        let seeded = SecretStoreChoice.current(environment: ["MWOYEO_MEMORY_SECRETS": "1", "MWOYEO_ENGINE_KEY": "scratch-key"])
        t.check("secrets: MWOYEO_ENGINE_KEY is the key of an engine nobody stored one for", key(seeded, engine) == "scratch-key")
        try? seeded.setSecret("typed", for: engine)
        t.check("secrets: a key stored for an engine wins, and the others keep the scratch key", key(seeded, engine) == "typed" && key(seeded, other) == "scratch-key")
        try? seeded.setSecret(nil, for: engine)
        t.check("secrets: clearing a stored key goes back to the scratch key", key(seeded, engine) == "scratch-key")
        t.check("secrets: with MWOYEO_MEMORY_SECRETS and no MWOYEO_ENGINE_KEY an engine has no key",
                key(SecretStoreChoice.current(environment: ["MWOYEO_MEMORY_SECRETS": "1"]), engine) == nil)
        t.check("secrets: MWOYEO_ENGINE_KEY alone changes nothing, the Keychain stays the store",
                SecretStoreChoice.current(environment: ["MWOYEO_ENGINE_KEY": "scratch-key"]) is KeychainSecrets)
    }

    // MARK: a line reaches a busy engine

    /// Who answered: the mock engine's reply ends in "번역"; Apple's stand-in is the harness's "⟦ko⟧ <text>".
    private static func answeredBy(_ translation: String?) -> String {
        guard let translation else { return "nothing" }
        return translation.hasSuffix("번역") ? "engine" : translation.hasPrefix("⟦ko⟧") ? "apple" : "other"
    }

    /// A line that is read as fragments goes to the engine as the fragment and then as the whole line (the lens cuts the fragment's call,
    /// `TranslationScheduling.Preemption.allGone`, or the whole line arrives while it is in flight). Film 2 saw the whole lines translated by
    /// Apple; the cause was not here: the take's tap (tools/film2/plates/tap.py) relayed Anthropic's gzip body without its `Content-Encoding`,
    /// so every engine call failed to read and the engine rested (2 s, doubling), during which each call went to Apple. Here the answers are
    /// readable and the whole line goes to the engine in every order, plain and with the app's memory; the control is an engine whose answer
    /// cannot be read, where the same sequence ends at Apple, so the predicate tells the two apart. `delay` is the mock's answer time in ms.
    @MainActor
    static func busyEngineChecks(_ t: Tally, delay: Int = 250) async {
        setenv("MWOYEO_FAKE_ENGINE", "slow:5", 1)
        defer { unsetenv("MWOYEO_FAKE_ENGINE") }
        let doc = lens(screen: [])
        let fragment = "Alice sent a pho", whole = "Alice sent a photo"
        let memory = profile(chat, entries: [MemoryEntry(src: "Alice", dst: "앨리스", kind: .person)])
        let orders = ["after the fragment's call answered", "after the fragment's call was cut", "while the fragment's call is in flight"]
        let runs: [(mode: String, path: String, profiles: [AppProfile])] = [
            ("slow:\(delay)", "plain", []), ("slow:\(delay)", "with memory", [memory]), ("garbage", "with memory", [memory]),
        ]
        for run in runs {
            for order in orders {
                guard let mock = Mock(mode: run.mode) else { t.check("busy: the mock server starts", false); return }
                defer { mock.stop() }
                let svc = service(settings(engine("openai", base: mock.base), profiles: run.profiles))
                let first = Task { await svc.translate([fragment], context: doc) }
                let outcome: TranslationOutcome
                switch order {
                case orders[1]:
                    try? await Task.sleep(for: .milliseconds(delay / 2))
                    first.cancel()
                    _ = await first.value
                    outcome = await svc.translate([whole], context: doc)
                case orders[2]:
                    try? await Task.sleep(for: .milliseconds(delay / 2))
                    outcome = await svc.translate([whole], context: doc)
                    _ = await first.value
                default:
                    _ = await first.value
                    outcome = await svc.translate([whole], context: doc)
                }
                let by = answeredBy(outcome.translations[whole])
                if run.mode == "garbage" {
                    t.check("busy, control: an engine whose answer cannot be read, \(order): the whole line goes to Apple", by == "apple", "answered by \(by)")
                } else {
                    let seen = mock.bodies.contains { Sent($0).items.contains(whole) || (Sent($0).last["lines"] as? [String])?.contains(whole) == true }
                    t.check("busy: \(run.path), \(order): the whole line goes to the engine", by == "engine" && seen, "answered by \(by), engine saw it \(seen)")
                }
            }
        }
    }

    // MARK: who really translated

    /// The JSON lines log names the translator that answered each line: the added engine's name, "apple" where Apple stood in for an engine
    /// that failed or rests, and for a text no translator was asked for the engine the lens is set to (`RegionSession` passes it as the
    /// fallback). FAIL-first: the writer was given the lens's engine once, so a line Apple translated said "O".
    @MainActor
    static func translatedByChecks(_ t: Tally) async {
        setenv("MWOYEO_FAKE_ENGINE", "slow:5", 1)
        defer { unsetenv("MWOYEO_FAKE_ENGINE") }
        let doc = lens(screen: [])
        let lines = ["Alice sent a photo", "See you tomorrow at nine"]
        for (mode, label) in [("ok", "answers"), ("garbage", "fails (its answer cannot be read, then it rests)")] {
            guard let mock = Mock(mode: mode) else { t.check("who: the mock server starts", false); return }
            defer { mock.stop() }
            let svc = service(settings(engine("openai", base: mock.base)))
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mwoyeo-trust-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let writer = TranscriptWriter(directory: directory, lens: "Lens", sourceCode: "en", targetCode: "ko", formats: [.jsonl],
                                          engine: { [svc] in svc.translatedBy($0) ?? "O" }, onError: {})
            var observed: [TranscriptRecorder.Observed] = []
            for line in lines {
                let outcome = await svc.translate([line], context: doc)
                observed.append(.init(source: line, translation: outcome.translations[line], inLens: true))
            }
            observed.append(.init(source: "Not asked", translation: "묻지 않음", inLens: true))
            writer.observe(time: 0, lines: observed)
            writer.finishAndWait(time: 30)
            var logged: [String: String] = [:]
            let file = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?.first { $0.pathExtension == "jsonl" }
            for text in file.flatMap({ try? String(contentsOf: $0, encoding: .utf8) })?.split(separator: "\n") ?? [] {
                let row = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
                if let original = row["original"] as? String, let engine = row["engine"] as? String { logged[original] = engine }
            }
            let want = mode == "ok" ? "O" : "apple"
            for line in lines {
                t.check("who: the engine \(label): \"\(line.prefix(8))…\" is logged as \(want)", logged[line] == want, "logged as \(logged[line] ?? "nothing")")
            }
            t.check("who: the engine \(label): a text no translator was asked for is logged as the engine the lens is set to",
                    logged["Not asked"] == "O", "logged as \(logged["Not asked"] ?? "nothing")")
        }
    }
}
#endif

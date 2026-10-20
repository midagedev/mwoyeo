#if !MAS
import AppKit
import MwoyeoCore
import MwoyeoEngines

/// A line that is only a name or a term of the memory a request sends is that row's translation and the engine is not asked
/// (mem-hints, 2026-10-20), through `TranslationService.translate` against the mock engine of `ContextChecks` and the harness Apple
/// (`MWOYEO_FAKE_ENGINE`). The engine not being asked is the mock's request count; a name that went to the engine is in its body.
extension ContextChecks {
    @MainActor
    static func memoryExactChecks(_ t: Tally) async {
        guard let mock = Mock(mode: "terms"), let reference = Mock(mode: "terms") else { t.check("exact: the mock servers start", false); return }
        defer { mock.stop(); reference.stop() }
        let alice = MemoryEntry(src: "Alice", dst: "앨리스", kind: .person, gender: .f)
        let zorro = MemoryEntry(src: "Zorro", dst: "조로", kind: .person)
        let written = profile(chat, entries: [alice, zorro])
        let rest = line("Carol is typing now")
        let doc = lens(screen: [rest])

        // The engine's Context is off and the app wrote names: Memory only. The name plate is the memory's, the other line is the engine's.
        let memoryOnly = service(settings(engine("openai", base: mock.base), profiles: [written]))
        _ = Trace.takeCounts()
        let mixed = await send(mock, memoryOnly, ["Alice", rest], doc)
        t.check("exact: a line that is only a name is the memory's translation, and the other line goes to the engine alone",
                mixed.outcome.translations["Alice"] == "앨리스" && mixed.sent.items == [rest] && mock.bodies.count == 1
                && mixed.outcome.translations[rest] != nil && !mixed.outcome.batchFailed,
                "items \(mixed.sent.items.count), requests \(mock.bodies.count)")
        let counted = Trace.takeCounts()["translate.memory_exact"]
        t.check("exact: the line served from memory is counted (translate.memory_exact), the engine's line is not", counted == 1, "\(String(describing: counted))")
        let plain = await memoryOnly.translate(["Alice", "Zorro"], context: doc)
        t.check("exact: a call of names alone asks the engine nothing and fails nothing",
                plain.translations == ["Alice": "앨리스", "Zorro": "조로"] && mock.bodies.count == 1 && !plain.batchFailed && plain.failed.isEmpty && !plain.cancelled,
                "requests \(mock.bodies.count), failed \(plain.failed.count)")
        let marks = await memoryOnly.translate(["【Alice】", "ZORRO:", "「 zorro 」"], context: doc)
        t.check("exact: the marks of a name plate come off to compare and stay around the translation; case is the sheet's",
                marks.translations == ["【Alice】": "【앨리스】", "ZORRO:": "조로:", "「 zorro 」": "「 조로 」"] && mock.bodies.count == 1,
                "\(marks.translations.values.sorted()), requests \(mock.bodies.count)")

        // A line that holds the name among other words is the engine's, with the name in its memory rows as before.
        let sentence = line("Alice sent a photo")
        let among = await send(mock, memoryOnly, [sentence, "Alice is here"], doc)
        t.check("exact: a line that only contains the name goes to the engine with the row beside it",
                among.sent.items == [sentence, "Alice is here"] && mock.bodies.count == 2 && among.sent.memory.first?.hasPrefix("Alice -> 앨리스") == true
                && among.outcome.translations["Alice is here"] != "앨리스")

        // Full context: the same rule on the context path with the thread; the served line joins the thread like a cache hit.
        let context = EngineContext(enabled: true, previousLines: 4)
        let full = service(settings(engine("openai", base: mock.base, context: context), profiles: [written]))
        let before = mock.bodies.count
        let onMixed = await send(mock, full, ["Zorro", rest], doc)
        t.check("exact: with Context on the name is served from memory and the engine gets the other line",
                onMixed.outcome.translations["Zorro"] == "조로" && onMixed.sent.items == [rest] && mock.bodies.count == before + 1)

        // Where the memory does not reach the request, nothing is served: no profile, no row for this app, Context off by the app's override.
        let bare = service(settings(engine("openai", base: reference.base), profiles: []))
        let bareMixed = await send(reference, bare, ["Alice", rest], doc)
        t.check("exact: without memory the name goes to the engine like any line",
                bareMixed.sent.last["lines"] as? [String] == ["Alice", rest] && bareMixed.outcome.translations["Alice"] != "앨리스" && reference.bodies.count == 1)
        let otherApp = service(settings(engine("openai", base: reference.base), profiles: [written]))
        _ = await otherApp.translate(["Alice"], context: lens(mail, screen: [rest]))
        t.check("exact: the memory of another app is not this lens's", reference.bodies.count == 2)
        let off = service(settings(engine("openai", base: reference.base), profiles: [profile(chat, context: AppContextOverride(mode: .off), entries: [alice, zorro])]))
        let offNames = await off.translate(["Alice"], context: doc)
        t.check("exact: an app whose Context override is off sends no memory and serves none", reference.bodies.count == 3 && offNames.translations["Alice"] != "앨리스")
        let noLens = await memoryOnly.translate(["Zorro"], context: nil)
        t.check("exact: a call without a lens takes today's path and asks the engine", mock.bodies.count == before + 2 && noLens.translations["Zorro"] != "조로",
                "requests \(mock.bodies.count - before)")

        // DeepL takes the memory only through its own opt-in, so without it the name is not the memory's.
        if let deepl = Mock(mode: "terms"), let optedIn = Mock(mode: "terms") {
            defer { deepl.stop(); optedIn.stop() }
            // Context is on for the engine but the memory goes to DeepL only through its own opt-in: the context path runs and sends no row.
            let closed = service(settings(engine("deepl", base: deepl.base, context: EngineContext(enabled: true, previousLines: 0)), profiles: [written]))
            let closedOut = await closed.translate(["Alice"], context: doc)
            t.check("exact: DeepL with Context on and without its opt-in gets the name like any line", deepl.bodies.count == 1 && closedOut.translations["Alice"] != "앨리스",
                    "requests \(deepl.bodies.count)")
            let open = service(settings(engine("deepl", base: optedIn.base, context: EngineContext(enabled: true, previousLines: 0, deepLInstructions: true)),
                                        profiles: [written]))
            let openOut = await open.translate(["Alice"], context: doc)
            t.check("exact: DeepL with its opt-in serves the name from memory", optedIn.bodies.isEmpty && openOut.translations["Alice"] == "앨리스",
                    "requests \(optedIn.bodies.count)")
        } else {
            t.check("exact: the DeepL mocks start", false)
        }

        // A learned row is served like a hint of the model, and an app entry of the same source wins.
        if let learning = Mock(mode: "terms") {
            defer { learning.stop() }
            let loud = EngineContext(enabled: true, previousLines: 0, useLearned: true)
            let svc = service(settings(engine("openai", base: learning.base, context: loud), profiles: [profile(chat)]))
            let b1 = [line("Bob liked the first photo")], b2 = [line("Bob liked the second photo")]
            _ = await send(learning, svc, b1, lens(screen: b1))
            _ = await send(learning, svc, b2, lens(screen: b2))
            let usable = await svc.learnedRows(for: chat).filter(\.isUsable).map(\.entry)
            let served = await svc.translate(["Bob"], context: lens(screen: b2))
            t.check("exact: a learned row that two sightings made usable is served from memory", usable.map(\.src) == ["Bob"] && served.translations["Bob"] == usable.first?.dst
                    && learning.bodies.count == 2, "usable \(usable.map(\.src)), requests \(learning.bodies.count)")
        }

        await memoryExactAppleChecks(t, alice: alice)
    }

    /// Apple Translation with the person's pinned names (`appleUsesPinnedTerms`): a line that is only a pinned name is not sent to Apple. The harness
    /// Apple answers "⟦ko⟧ " + the text it was given, so the answer shows what Apple received.
    @MainActor
    private static func memoryExactAppleChecks(_ t: Tally, alice: MemoryEntry) async {
        setenv("MWOYEO_FAKE_ENGINE", "slow:5", 1)
        defer { unsetenv("MWOYEO_FAKE_ENGINE") }
        let sentence = "Hello Alice, welcome back"
        var pinsOn = settings(nil, profiles: [profile(chat, entries: [alice])])
        pinsOn.appleUsesPinnedTerms = true
        let served = await service(pinsOn).translate(["Alice", "【Alice】", sentence], context: lens())
        t.check("exact: Apple with pinned names serves a line that is only the name, and sends the other line with the name put in",
                served.translations["Alice"] == "앨리스" && served.translations["【Alice】"] == "【앨리스】"
                && served.translations[sentence] == "⟦ko⟧ Hello 앨리스, welcome back" && !served.batchFailed && served.failed.isEmpty,
                "\(served.translations.values.sorted())")
        let alone = await service(pinsOn).translate(["Alice"], context: lens())
        t.check("exact: Apple with a call of names alone is not asked at all", alone.translations == ["Alice": "앨리스"] && !alone.batchFailed && alone.failed.isEmpty)
        var pinsOff = pinsOn
        pinsOff.appleUsesPinnedTerms = false
        let today = await service(pinsOff).translate(["Alice"], context: lens())
        t.check("exact: Apple with the pinned names off is today's text", today.translations["Alice"] == "⟦ko⟧ Alice")
        let otherLens = await service(pinsOn).translate(["Alice"], context: lens(mail))
        t.check("exact: Apple with pinned names on and another app's lens is today's text", otherLens.translations["Alice"] == "⟦ko⟧ Alice")
        let noLens = await service(pinsOn).translate(["Alice"], context: nil)
        t.check("exact: Apple with pinned names on and no lens is today's text", noLens.translations["Alice"] == "⟦ko⟧ Alice")
    }
}
#endif

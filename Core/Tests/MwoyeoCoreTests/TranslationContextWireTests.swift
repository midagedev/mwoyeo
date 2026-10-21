import Foundation
import Testing
@testable import MwoyeoCore

/// The helpers of the app's request path: the gate that keeps Off free, who is around a batch on screen, the per-call cache
/// namespace, the usage counter, and the check of Apple Translation's answer after a pre-insertion.
@Suite struct TranslationContextWireTests {
    private func engine(_ context: EngineContext?) -> EngineConfig {
        EngineConfig(name: "e", kind: .openAICompatible(baseURL: URL(string: "http://127.0.0.1:1/v1")!, model: "m", thinking: .off, extraHeaders: [:]),
                     context: context)
    }

    private func profile(_ mode: AppContextOverride.Mode?) -> AppProfile {
        AppProfile(bundleID: "com.example.\(mode?.rawValue ?? "none")", appName: "x", source: "ja", target: "en",
                   context: mode.map { AppContextOverride(mode: $0) })
    }

    // MARK: the gate

    @Test func noContextAnywhereCouldNotBeOn() {
        #expect(!ContextOptions.couldBeOn(engine: nil, profiles: []))
        #expect(!ContextOptions.couldBeOn(engine: engine(nil), profiles: [profile(nil)]))
        #expect(!ContextOptions.couldBeOn(engine: engine(EngineContext(enabled: false, includeTitle: true)), profiles: [profile(.off)]))
    }

    @Test func anEngineSwitchOrAnAppOverrideCouldBeOn() {
        #expect(ContextOptions.couldBeOn(engine: engine(EngineContext(enabled: true)), profiles: []))
        #expect(ContextOptions.couldBeOn(engine: nil, profiles: [profile(.nearby)]))
        #expect(ContextOptions.couldBeOn(engine: engine(nil), profiles: [profile(.off), profile(.conversation)]))
    }

    /// The gate must never say "no" where the effective options say On: for every combination, On implies `couldBeOn`.
    @Test func theGateNeverContradictsTheEffectiveOptions() {
        let engines: [EngineConfig?] = [nil, engine(nil), engine(EngineContext()), engine(EngineContext(enabled: true))]
        let modes: [AppContextOverride.Mode?] = [nil, .off, .nearby, .conversation]
        for e in engines {
            for m in modes {
                let p = profile(m)
                if ContextOptions.effective(engine: e, profile: p).enabled {
                    #expect(ContextOptions.couldBeOn(engine: e, profiles: [p]), "engine \(String(describing: e?.context)) mode \(String(describing: m))")
                }
            }
        }
    }

    // MARK: neighbours

    private func lines(_ texts: [String]) -> [ContextNeighbours.Line] {
        texts.enumerated().map { ContextNeighbours.Line(source: $1, rect: CGRect(x: 0, y: CGFloat($0) * 20, width: 100, height: 14)) }
    }

    @Test func neighboursAreTheLinesAboveTheFirstAndBelowTheLastOfTheBatch() {
        let screen = lines(["a", "b", "c", "d", "e", "f", "g"])
        let n = ContextNeighbours.around(batch: ["d", "e"], lines: screen)
        #expect(n.above == ["b", "c"])
        #expect(n.below == ["f", "g"])
    }

    /// The order comes from the rects, not from the order the lines were handed in.
    @Test func neighboursFollowReadingOrderWhateverTheInputOrder() {
        let screen = lines(["a", "b", "c", "d", "e"])
        let n = ContextNeighbours.around(batch: ["c"], lines: [screen[3], screen[0], screen[4], screen[2], screen[1]])
        #expect(n.above == ["a", "b"])
        #expect(n.below == ["d", "e"])
    }

    @Test func aBatchOutOfReadingOrderStillHasItsOwnNeighbours() {
        let screen = lines(["a", "b", "c", "d", "e", "f"])
        // The lens's priority can put a lower line first; the sides are still above the topmost and below the lowest.
        let n = ContextNeighbours.around(batch: ["e", "b"], lines: screen, above: 1, below: 1)
        #expect(n.above == ["a"])
        #expect(n.below == ["f"])
    }

    @Test func linesBetweenTheBatchsLinesAndTheBatchItselfAreNeverNeighbours() {
        let screen = lines(["a", "b", "c", "d", "e"])
        let n = ContextNeighbours.around(batch: ["b", "d"], lines: screen)
        #expect(n.above == ["a"])
        #expect(n.below == ["e"])
        #expect(!(n.above + n.below).contains("c"))
    }

    @Test func emptyLinesRepeatsAndTheLimitsAreHonoured() {
        let screen = lines(["a", "  ", "a", "b", "x", "y", "y", "z"])
        let n = ContextNeighbours.around(batch: ["x"], lines: screen, above: 5, below: 2)
        #expect(n.above == ["a", "b"])
        #expect(n.below == ["y", "z"])
        let none = ContextNeighbours.around(batch: ["x"], lines: screen, above: 0, below: 0)
        #expect(none.above.isEmpty && none.below.isEmpty)
    }

    @Test func aBatchNotOnScreenHasNoNeighbours() {
        let n = ContextNeighbours.around(batch: ["gone"], lines: lines(["a", "b"]))
        #expect(n.above.isEmpty && n.below.isEmpty)
        let empty = ContextNeighbours.around(batch: [], lines: lines(["a", "b"]))
        #expect(empty.above.isEmpty && empty.below.isEmpty)
    }

    @Test func twoColumnsReadLeftToRightWithinARow() {
        let screen = [ContextNeighbours.Line(source: "right", rect: CGRect(x: 200, y: 0, width: 100, height: 14)),
                      ContextNeighbours.Line(source: "left", rect: CGRect(x: 0, y: 1, width: 100, height: 14)),
                      ContextNeighbours.Line(source: "next", rect: CGRect(x: 0, y: 40, width: 100, height: 14))]
        let n = ContextNeighbours.around(batch: ["right"], lines: screen)
        #expect(n.above == ["left"])
        #expect(n.below == ["next"])
    }

    // MARK: namespace

    private func key(_ title: String = "Alice", lens: String = "", target: String = "ko", engine: String = "e1") -> ThreadKey {
        ThreadKey(bundleID: "com.example.chat", title: title, lens: lens, pair: LanguagePair("ja", target), engineID: engine)
    }

    @Test func theNamespaceKeepsTodaysAsItsPrefix() {
        let ns = ContextNamespace.make(base: "ja>ko|apple:auto|123", key: key(), fingerprint: "gen=0")
        #expect(ns.hasPrefix("ja>ko|apple:auto|123|ctx:"))
        #expect(ns != "ja>ko|apple:auto|123")
    }

    @Test func eachPartOfTheThreadAndTheMemoryChangesTheNamespace() {
        let base = "b"
        let reference = ContextNamespace.make(base: base, key: key(), fingerprint: "gen=0")
        var seen: Set<String> = [reference]
        for ns in [ContextNamespace.make(base: base, key: key("Bob"), fingerprint: "gen=0"),
                   ContextNamespace.make(base: base, key: key(lens: "lens-2"), fingerprint: "gen=0"),
                   ContextNamespace.make(base: base, key: key(target: "en"), fingerprint: "gen=0"),
                   ContextNamespace.make(base: base, key: key(engine: "e2"), fingerprint: "gen=0"),
                   ContextNamespace.make(base: base, key: key(), fingerprint: "gen=1"),
                   ContextNamespace.make(base: base, key: key(), fingerprint: "gen=0\u{1E}note=formal"),
                   ContextNamespace.make(base: "other", key: key(), fingerprint: "gen=0")] {
            #expect(seen.insert(ns).inserted, "a part did not change the namespace")
        }
        #expect(ContextNamespace.make(base: base, key: key(), fingerprint: "gen=0") == reference)
    }

    /// A title or a note is user text: it must not lie in a cache key as it is.
    @Test func theNamespaceHoldsNoTitleAndNoNote() {
        let ns = ContextNamespace.make(base: "b", key: key("Secret plans"), fingerprint: "note=my private note")
        #expect(!ns.contains("Secret") && !ns.contains("private") && !ns.contains("com.example"))
    }

    /// The transcript and the learned rows are out of the namespace (§8.1): memory with and without learned rows, and a thread with
    /// and without a transcript, give the same key.
    @Test func theTranscriptAndLearnedRowsDoNotChangeTheNamespace() {
        var memory = ContextMemory(note: "casual chat", entries: [MemoryEntry(src: "田中", dst: "Tanaka")])
        var thread = ContextThread(key: key())
        let before = ContextNamespace.make(base: "b", key: thread.key, fingerprint: thread.namespaceFingerprint(memory: memory))
        thread.append(source: "line one")
        thread.append(source: "line two", translation: "x")
        _ = memory.learn([TermHint(src: "Alice", dst: "앨리스")], items: ["Alice said hi"], reply: ["앨리스가 말했다"])
        _ = memory.learn([TermHint(src: "Alice", dst: "앨리스")], items: ["Alice again"], reply: ["앨리스 또"])
        #expect(memory.usableLearned.count == 1)
        let after = ContextNamespace.make(base: "b", key: thread.key, fingerprint: thread.namespaceFingerprint(memory: memory))
        #expect(before == after)
    }

    // MARK: usage

    @Test func usageSumsWhatTheProviderReported() {
        var u = ContextUsage()
        #expect(u.cachedShare == nil)
        u.add(TokenUsage(prompt: 1000, completion: 50, cached: 800))
        u.add(TokenUsage(prompt: 500, completion: 20, cached: 0, cacheWrite: 400))
        #expect(u.requests == 2 && u.prompt == 1500 && u.completion == 70 && u.cached == 800 && u.cacheWrite == 400)
        #expect(abs((u.cachedShare ?? 0) - 800.0 / 1500.0) < 1e-9)
    }

    @Test func usageCountsResetsByReasonAndSightings() {
        var u = ContextUsage()
        u.noteReset(.appSwitch)
        u.noteReset(.appSwitch)
        u.noteReset(.idle)
        u.noteSightings(3)
        #expect(u.resets == [.appSwitch: 2, .idle: 1] && u.sightings == 3)
    }

    // MARK: Apple's answer

    @Test func anAnswerHoldsTheTargetsPutIntoTheSource() {
        let entries = [MemoryEntry(src: "token", dst: "토큰", origin: .user), MemoryEntry(src: "raid", dst: "레이드", origin: .user)]
        let pre = ApplePreinsertion.insert(into: "The raid gives a token", entries: entries)
        #expect(pre.targets == ["레이드", "토큰"])
        #expect(pre.answerHoldsTargets("레이드는 토큰을 줍니다"))
        #expect(!pre.answerHoldsTargets("레이드는 코인을 줍니다"))
        #expect(!pre.answerHoldsTargets(""))
    }

    @Test func anUntouchedSourceHasNothingToHold() {
        let pre = ApplePreinsertion.insert(into: "Hello", entries: [MemoryEntry(src: "raid", dst: "레이드")])
        #expect(pre.isEmpty && pre.answerHoldsTargets("anything"))
    }
}

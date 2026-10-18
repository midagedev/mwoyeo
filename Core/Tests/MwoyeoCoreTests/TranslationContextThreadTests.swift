import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct TranslationContextThreadTests {
    private let jaKo = LanguagePair("ja", "ko")

    private func signals(app: String = "com.app.chat", title: String? = "Room", lens: String = "", pair: LanguagePair? = nil,
                         engine: String = "E1", idle: TimeInterval = 0, shared: Double? = nil, user: Bool = false) -> ThreadSignals {
        ThreadSignals(bundleID: app, confirmedTitle: title, lensID: lens, pair: pair ?? jaKo, engineID: engine,
                      idleSeconds: idle, sharedLineRatio: shared, userReset: user)
    }

    private var base: ThreadKey { signals().key }

    // MARK: each reset signal

    @Test func noSignalNoReset() {
        #expect(signals().resetReason(against: base) == nil)
        #expect(signals().resetReason(against: nil) == nil)
        #expect(signals(idle: 299.9, shared: 0.2).resetReason(against: base) == nil)   // just inside both limits
    }

    @Test func eachSignalGivesItsReason() {
        #expect(signals(user: true).resetReason(against: base) == .userReset)
        #expect(signals(app: "com.other").resetReason(against: base) == .appSwitch)
        #expect(signals(title: "Other room").resetReason(against: base) == .titleChange)
        #expect(signals(title: nil).resetReason(against: base) == .titleChange)          // the title went away
        #expect(signals(lens: "lens-2").resetReason(against: base) == .lensChange)
        #expect(signals(pair: LanguagePair("en", "ko")).resetReason(against: base) == .pairChange)
        #expect(signals(engine: "E2").resetReason(against: base) == .engineChange)
        #expect(signals(idle: 300).resetReason(against: base) == .idle)                  // 5 min, inclusive
        #expect(signals(shared: 0.19).resetReason(against: base) == .wholesaleChange)    // under 20 % shared lines
    }

    @Test func oneReasonByPriority() {
        let all = signals(app: "com.other", title: "x", pair: LanguagePair("en", "ko"), engine: "E2", idle: 999, shared: 0, user: true)
        #expect(all.resetReason(against: base) == .userReset)
        #expect(signals(app: "com.other", title: "x", engine: "E2", idle: 999, shared: 0).resetReason(against: base) == .appSwitch)
        #expect(signals(title: "x", engine: "E2", idle: 999, shared: 0).resetReason(against: base) == .titleChange)
        #expect(signals(engine: "E2", idle: 999, shared: 0).resetReason(against: base) == .engineChange)
        #expect(signals(idle: 999, shared: 0).resetReason(against: base) == .idle)
    }

    @Test func keyChangesAreNotClearingResets() {
        for r in [ResetReason.appSwitch, .titleChange, .lensChange, .pairChange, .engineChange] { #expect(r.isKeyChange) }
        for r in [ResetReason.userReset, .idle, .wholesaleChange] { #expect(!r.isKeyChange) }
        // Referents die with a title or app change and "Start fresh", never with idle (design §8.3).
        #expect(ResetReason.allCases.filter(\.clearsReferents).sorted { $0.rawValue < $1.rawValue } == [.appSwitch, .titleChange, .userReset])
    }

    @Test func sharedLineRatio() {
        #expect(ThreadSignals.sharedLineRatio(previous: ["a", "b", "c", "d"], current: ["a", "b", "x", "y"]) == 0.5)
        #expect(ThreadSignals.sharedLineRatio(previous: ["a"], current: ["x", "y"]) == 0)
        #expect(ThreadSignals.sharedLineRatio(previous: [], current: ["x"]) == nil)
        #expect(ThreadSignals.sharedLineRatio(previous: ["a"], current: []) == nil)
        #expect(ThreadSignals.sharedLineRatio(previous: ["a  b"], current: ["a b"]) == 1)       // spaces do not matter
    }

    // MARK: the thread

    @Test func transcriptKeepsTheLastLinesWithoutRepeats() {
        var t = ContextThread(key: base)
        for i in 0..<10 { t.append(source: "line \(i)") }
        #expect(t.transcript.count == ContextThread.maxLines)
        #expect(t.transcript.first?.source == "line 2")
        t.append(source: "line 9")                                         // an observed repeat is not appended again
        t.append(source: "line 8", translation: "줄 8", trusted: true)      // ...but it can gain its translation
        #expect(t.transcript.count == 8 && t.transcript.last?.source == "line 9")
        #expect(t.transcript[6].translation == "줄 8" && t.transcript[6].trusted)
        t.append(source: "  ")
        #expect(t.transcript.count == 8)
    }

    @Test func contextLinesTakeTheLastNAndSkipTheItems() {
        var t = ContextThread(key: base)
        for i in 1...6 { t.append(source: "l\(i)") }
        #expect(t.contextLines(count: 2).map(\.source) == ["l5", "l6"])
        #expect(t.contextLines(count: 3, excluding: ["l6"]).map(\.source) == ["l3", "l4", "l5"])
        #expect(t.contextLines(count: 0).isEmpty)
    }

    @Test func applyClearsTheTranscriptAndReferentsByReason() {
        var t = ContextThread(key: base)
        t.append(source: "x")
        t.setReferents([Referent(pronoun: "he", refersTo: "田中")])
        t.apply(.idle)
        #expect(t.transcript.isEmpty && t.referents.count == 1 && t.generation == 0)
        t.append(source: "y")
        t.apply(.wholesaleChange)
        #expect(t.transcript.isEmpty && t.referents.count == 1)
        t.apply(.userReset)
        #expect(t.referents.isEmpty && t.generation == 1)
        t.setReferents((0..<12).map { Referent(pronoun: "p\($0)", refersTo: "q") } + [Referent(pronoun: "", refersTo: "x")])
        #expect(t.referents.count == Referent.maxCount)
    }

    // MARK: the store

    @Test func tabsResumeTheirThreads() {
        var store = ThreadStore()
        let a = store.step(signals(title: "A"), now: 0)
        store.update(a.key) { $0.append(source: "line in A") }
        let b = store.step(signals(title: "B"), now: 10)
        #expect(b.reason == .titleChange && !b.resumed && store.current?.transcript.isEmpty == true)
        let back = store.step(signals(title: "A"), now: 20)
        #expect(back.reason == .titleChange && back.resumed)
        #expect(store.current?.transcript.map(\.source) == ["line in A"])       // A → B → A resumes
    }

    @Test func idleAndWholesaleClearOnlyTheTranscript() {
        var store = ThreadStore()
        let k = store.step(signals(), now: 0).key
        store.update(k) { $0.append(source: "x"); $0.setReferents([Referent(pronoun: "he", refersTo: "田中")]) }
        let idle = store.step(signals(idle: 400), now: 400)
        #expect(idle.reason == .idle && store.current?.transcript.isEmpty == true && store.current?.referents.count == 1)
        store.update(k) { $0.append(source: "y") }
        let wholesale = store.step(signals(shared: 0.0), now: 401)
        #expect(wholesale.reason == .wholesaleChange && store.current?.transcript.isEmpty == true && store.current?.referents.count == 1)
    }

    @Test func startFreshClearsEverythingAndBumpsTheGeneration() {
        var store = ThreadStore()
        let k = store.step(signals(), now: 0).key
        store.update(k) { $0.append(source: "x"); $0.setReferents([Referent(pronoun: "he", refersTo: "田中")]) }
        let step = store.step(signals(user: true), now: 5)
        #expect(step.reason == .userReset)
        #expect(store.current?.transcript.isEmpty == true && store.current?.referents.isEmpty == true && store.current?.generation == 1)
    }

    @Test func aPairOrEngineChangeIsAKeyChangeThatKeepsTheReferents() {
        var store = ThreadStore()
        let k = store.step(signals(), now: 0).key
        store.update(k) { $0.append(source: "x"); $0.setReferents([Referent(pronoun: "he", refersTo: "田中")]) }
        let pair = store.step(signals(pair: LanguagePair("en", "ko")), now: 1)
        #expect(pair.reason == .pairChange && !pair.resumed && pair.key != k)
        #expect(store.current?.transcript.isEmpty == true)                       // another thread: no transcript
        #expect(store.current?.referents.count == 1)                             // the document did not change
        // A title change does not carry them.
        let title = store.step(signals(title: "Other"), now: 2)
        #expect(title.reason == .titleChange && store.current?.referents.isEmpty == true)
        // The thread of the old pair is still there.
        #expect(store.thread(k)?.transcript.map(\.source) == ["x"])
    }

    @Test func aKeptThreadLosesItsTranscriptAfterFiveIdleMinutes() {
        var store = ThreadStore()
        let a = store.step(signals(title: "A"), now: 0).key
        store.update(a) { $0.append(source: "x"); $0.setReferents([Referent(pronoun: "he", refersTo: "田中")]) }
        store.step(signals(title: "B"), now: 10)
        let back = store.step(signals(title: "A"), now: 400)
        #expect(back.resumed && store.current?.transcript.isEmpty == true)
        #expect(store.current?.referents.count == 1)                             // referents never expire by idle
    }

    @Test func emptyIdleThreadsAreDroppedAndAppsKeepAtMostEight() {
        var store = ThreadStore()
        for i in 0..<12 { store.step(signals(title: "T\(i)"), now: Double(i)) }
        #expect(store.threads.keys.filter { $0.bundleID == "com.app.chat" }.count == 8)       // 12 were opened; the literal 8 is the rule
        #expect(ThreadStore.maxPerApp == 8)
        #expect(store.currentKey?.title == "T11")
        // Another app's threads are not counted against this app.
        for i in 0..<3 { store.step(signals(app: "com.other", title: "O\(i)"), now: 20 + Double(i)) }
        #expect(store.threads.keys.filter { $0.bundleID == "com.other" }.count == 3)
        // A thread that holds something survives the idle sweep; an empty one does not.
        var s2 = ThreadStore()
        let keep = s2.step(signals(title: "keep"), now: 0).key
        s2.update(keep) { $0.append(source: "x") }
        let husk = s2.step(signals(title: "husk"), now: 1).key
        s2.step(signals(title: "now"), now: 1000)
        #expect(s2.thread(keep) != nil && s2.thread(husk) == nil)
    }

    // MARK: key and namespace

    @Test func cacheKeyIsStableAndLeaksNothing() {
        let k = ThreadKey(bundleID: "com.apple.MobileSMS", title: "Alice Smith", pair: jaKo, engineID: "E1")
        #expect(k.cacheKey == ThreadKey(bundleID: "com.apple.MobileSMS", title: "Alice Smith", pair: jaKo, engineID: "E1").cacheKey)
        #expect(k.cacheKey.hasPrefix("mwoyeo-") && k.cacheKey.count == 7 + 16)
        #expect(!k.cacheKey.contains("Alice") && !k.cacheKey.contains("MobileSMS"))
        var other = k
        other.title = "Bob"
        #expect(other.cacheKey != k.cacheKey)
        other = k
        other.pair = LanguagePair("en", "ko")
        #expect(other.cacheKey != k.cacheKey)
        // FNV-1a 64 of the empty string.
        #expect(ContextText.stableHash("") == "cbf29ce484222325")
    }

    @Test func namespaceFingerprintFollowsWhatTheUserWroteOnly() {
        var t = ContextThread(key: base)
        let m = ContextMemory(note: "casual", entries: [CtxFix.alice])
        let f0 = t.namespaceFingerprint(memory: m)
        t.append(source: "a new line")                                          // the transcript stays out
        var learned = m
        learned.learn([TermHint(src: "田中", dst: "다나카")], items: ["田中だ"], reply: ["다나카다"])
        #expect(t.namespaceFingerprint(memory: learned) == f0)                  // learned hints stay out
        t.setReferents([Referent(pronoun: "he", refersTo: "田中")])
        #expect(t.namespaceFingerprint(memory: m) != f0)
        let f1 = t.namespaceFingerprint(memory: m)
        t.apply(.userReset)
        #expect(t.namespaceFingerprint(memory: m) != f1)                        // "Start fresh" generation
        #expect(t.namespaceFingerprint(memory: ContextMemory(note: "formal", entries: [CtxFix.alice])) != t.namespaceFingerprint(memory: m))
    }
}

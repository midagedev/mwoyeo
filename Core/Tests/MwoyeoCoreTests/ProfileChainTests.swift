import Foundation
import Testing
@testable import MwoyeoCore

/// The chain of a lens (design §1.3), what the chain sends (design §2.1, §2.2) and the request table (design §4.2).
@Suite struct ProfileChainTests {
    private let app = "com.example.app"

    /// A profile of the new shape (design §1.1): an id, a name, its conditions and what it sets.
    private func profile(_ id: String, _ name: String, when conditions: [ProfileCondition] = [],
                         source: String = "ja", target: String = "ko", note: String = "", entries: [MemoryEntry] = [],
                         context: AppContextOverride? = nil, engine: ProfileEngine? = nil, useLearned: Bool? = nil) -> AppProfile {
        AppProfile(bundleID: conditions.compactMap(\.app).first ?? id, appName: name, source: source, target: target,
                   note: note, entries: entries, context: context, id: id, name: name, when: conditions,
                   engine: engine, useLearned: useLearned)
    }

    /// The chain of a lens with no profile: All apps, with the base's values.
    private func allAppsChain(_ base: ChainBase) -> MergedChain { ProfileChain.merge([.allApps], base: base) }

    private func base(_ amount: ContextAmount = .memory, learn: Bool = false, engines: Set<UUID> = [],
                      bundleID: String? = nil, engine: ProfileEngine? = nil) -> ChainBase {
        ChainBase(pair: LanguageChoice(source: "auto", target: "en", customEngineID: nil), engine: engine,
                  reader: .documentLayout, amount: amount, learn: learn, glossary: [], knownEngines: engines,
                  bundleID: bundleID)
    }

    private let kinds: [(String, EngineKind)] = [
        ("local", .openAICompatible(baseURL: URL(string: "http://localhost:8765/v1")!, model: "qwen3:8b", thinking: .off, extraHeaders: [:])),
        ("cloud", .openAICompatible(baseURL: URL(string: "https://api.example.com/v1")!, model: "m", thinking: .off, extraHeaders: [:])),
        ("anthropic", .anthropic(baseURL: EngineKind.anthropicDefaultBaseURL, model: "claude", thinking: .off)),
        ("deepL", .deepL(baseURL: URL(string: "https://api.deepl.com")!, formality: nil)),
        ("template", .httpTemplate(HTTPTemplate(url: "http://localhost:5000/t", body: "{}", resultPath: "t"))),
        ("command", .command(CommandSpec(executable: "/usr/bin/python3", arguments: ["-I", "e.py"]))),
    ]

    // MARK: the chain (design §1.3)

    @Test func autoPicksTheNarrowestMatchFirst() {
        let emu = profile("emu", "Emulator", when: [ProfileCondition(app: "com.example.emu")])
        let game = profile("game", "Game", when: [ProfileCondition(app: "com.example.emu", titleContains: "月涙譚")])
        let other = profile("other", "Other", when: [ProfileCondition(app: "com.example.other")])
        let chain = ProfileChain.chain(for: WindowFacts(bundleID: "com.example.emu", title: "月涙譚 — 第二章"),
                                       profiles: [emu, game, other], pin: .auto)
        // App and title (3) before the app alone (1); the app that is not in front is not in the chain.
        #expect(chain.map(\.id) == ["game", "emu", "all"])
        #expect(chain.last == .allApps)
    }

    @Test func aTitleConditionWaitsForTheConfirmedTitle() {
        let emu = profile("emu", "Emulator", when: [ProfileCondition(app: "com.example.emu")])
        let game = profile("game", "Game", when: [ProfileCondition(app: "com.example.emu", titleContains: "月涙譚")])
        let first = ProfileChain.chain(for: WindowFacts(bundleID: "com.example.emu", title: nil), profiles: [emu, game], pin: .auto)
        #expect(first.map(\.id) == ["emu", "all"])
        let confirmed = ProfileChain.chain(for: WindowFacts(bundleID: "com.example.emu", title: "月涙譚"), profiles: [emu, game], pin: .auto)
        #expect(confirmed.map(\.id) == ["game", "emu", "all"])
    }

    @Test func aTieGoesToTheLongerPhraseThenToTheEarlierProfile() {
        let short = profile("short", "Short", when: [ProfileCondition(app: app, titleContains: "Preprint")])
        let long = profile("long", "Long", when: [ProfileCondition(app: app, titleContains: "Preprint draft")])
        let window = WindowFacts(bundleID: app, title: "Preprint draft")
        #expect(ProfileChain.chain(for: window, profiles: [short, long], pin: .auto).map(\.id) == ["long", "short", "all"])
        // The same phrase twice: the earlier profile in the list wins.
        let first = profile("first", "First", when: [ProfileCondition(app: app, titleContains: "Same")])
        let second = profile("second", "Second", when: [ProfileCondition(app: app, titleContains: "Same")])
        let same = WindowFacts(bundleID: app, title: "Same thing")
        #expect(ProfileChain.chain(for: same, profiles: [first, second], pin: .auto).map(\.id) == ["first", "second", "all"])
    }

    @Test func aPinIsThatProfileAndAllAppsAndARemovedPinIsAuto() {
        let emu = profile("emu", "Emulator", when: [ProfileCondition(app: "com.example.emu")])
        let other = profile("other", "Other", when: [ProfileCondition(app: "com.example.other")])
        let window = WindowFacts(bundleID: "com.example.other", title: nil)
        #expect(ProfileChain.chain(for: window, profiles: [emu, other], pin: .profile("emu")).map(\.id) == ["emu", "all"])
        #expect(ProfileChain.chain(for: window, profiles: [emu, other], pin: .profile("gone")).map(\.id) == ["other", "all"])
        #expect(ProfileChain.chain(for: window, profiles: [emu, other], pin: .allAppsOnly) == [.allApps])
    }

    @Test func noProfileMeansAllApps() {
        let chain = ProfileChain.chain(for: WindowFacts(bundleID: app, title: "T"), profiles: [], pin: .auto)
        #expect(chain == [.allApps])
        #expect(ProfileChain.merge(chain, base: base()).links == [.allApps])
    }

    // MARK: the merge (design §2.1)

    @Test func theNarrowestSetsTheSingleValuedFields() {
        let broad = profile("broad", "Broad", when: [ProfileCondition(app: app)], source: "ja", target: "ko",
                            context: AppContextOverride(mode: .nearby), useLearned: true)
        let narrow = profile("narrow", "Narrow", when: [ProfileCondition(app: app, titleContains: "T")], source: "en", target: "de")
        let chain = ProfileChain.chain(for: WindowFacts(bundleID: app, title: "T"), profiles: [broad, narrow], pin: .auto)
        let merged = ProfileChain.merge(chain, base: base(.nearby, learn: false))
        // The pair is the head's (a profile always has one).
        #expect(merged.pair.source == "en" && merged.pair.target == "de")
        // The amount and the learn switch: the narrowest that sets them (the broad profile here).
        #expect(merged.amount == .nearby)
        #expect(merged.learn)
        // The reader: the narrowest that sets one, else All apps'.
        #expect(merged.reader == .documentLayout)
    }

    @Test func aGoneEngineIsSkipped() {
        let gone = UUID(), here = UUID()
        let p = profile("p", "P", when: [ProfileCondition(app: app)], engine: .added(gone))
        let chain = ProfileChain.chain(for: WindowFacts(bundleID: app), profiles: [p], pin: .auto)
        let merged = ProfileChain.merge(chain, base: base(engines: [here], engine: .added(here)))
        #expect(merged.engine == .added(here))
        #expect(merged.pair.customEngineID == here)
        // With no engine left at all, the chain has none.
        let none = ProfileChain.merge(chain, base: base(engines: []))
        #expect(none.engine == nil && none.pair.customEngineID == nil)
    }

    @Test func theNarrowestUserRowWinsAndTheBroaderOneIsAShadow() {
        let broad = profile("broad", "Broad", when: [ProfileCondition(app: app)], entries: [MemoryEntry(src: "ハク", dst: "Haku")])
        let narrow = profile("narrow", "Narrow", when: [ProfileCondition(app: app, titleContains: "T")],
                             entries: [MemoryEntry(src: "ハク", dst: "하쿠")])
        let chain = ProfileChain.chain(for: WindowFacts(bundleID: app, title: "T"), profiles: [broad, narrow], pin: .auto)
        let merged = ProfileChain.merge(chain, base: base())
        #expect(merged.rows.count == 1)
        #expect(merged.rows[0].entry.dst == "하쿠" && merged.rows[0].from == "narrow")
        // The broader row is not put in; it is remembered as the shadow it is (design §2.2).
        #expect(merged.rows[0].shadows.count == 1)
        #expect(merged.rows[0].shadows[0].entry.dst == "Haku" && merged.rows[0].shadows[0].from == "broad")
    }

    @Test func aLearnedRowWhoseSourceIsAUserRowIsNotSent() {
        let p = profile("p", "P", when: [ProfileCondition(app: app)], entries: [MemoryEntry(src: "ハク", dst: "하쿠")])
        let chain = ProfileChain.chain(for: WindowFacts(bundleID: app), profiles: [p], pin: .auto)
        let learned = [MemoryEntry(src: "ハク", dst: "Haku", origin: .learned), MemoryEntry(src: "ムシ", dst: "Mushi", origin: .learned)]
        let merged = ProfileChain.merge(chain, base: base(), learned: learned)
        #expect(merged.rows.map(\.entry.src) == ["ハク", "ムシ"])
        #expect(merged.rows[0].from == "p")
        #expect(merged.rows[1].from == "learned:p")
        // The learned rows are kept under the head (design §2.1's third rule).
        #expect(merged.learnedKey == "p")
    }

    @Test func theLearnedRowsAreKeyedUnderTheBundleIDWhenAllAppsIsTheHead() {
        let merged = ProfileChain.merge([.allApps], base: base(bundleID: "com.example.front"))
        #expect(merged.learnedKey == "com.example.front")
    }

    @Test func theNotesGoBroadToNarrowAndWholeNotesAreDropped() {
        let long = String(repeating: "b", count: 400)
        let narrow = String(repeating: "n", count: 200)
        let broad = profile("broad", "Broad", when: [ProfileCondition(app: app)], note: long)
        let head = profile("head", "Head", when: [ProfileCondition(app: app, titleContains: "T")], note: narrow)
        let chain = ProfileChain.chain(for: WindowFacts(bundleID: app, title: "T"), profiles: [broad, head], pin: .auto)
        let merged = ProfileChain.merge(chain, base: base())
        // Broad to narrow, a blank line between: 400 + 2 + 200 is over 500, so the broadest note goes whole.
        #expect(merged.note == narrow)
        // Two notes that fit are both there, broad first.
        let small = profile("small", "Small", when: [ProfileCondition(app: app)], note: "broad")
        let smallHead = profile("smallHead", "SmallHead", when: [ProfileCondition(app: app, titleContains: "T")], note: "narrow")
        let chain2 = ProfileChain.chain(for: WindowFacts(bundleID: app, title: "T"), profiles: [small, smallHead], pin: .auto)
        #expect(ProfileChain.merge(chain2, base: base()).note == "broad\n\nnarrow")
    }

    // MARK: the request table (design §4.2)

    /// The default path (design §8, row R1): no profile means every chain is All apps, and the request is today's for
    /// every kind and every combination of the five old switches.
    @Test func theDefaultPathIsTodaysRequestForEveryKindAndEverySwitch() {
        let chain = ProfileChain.chain(for: WindowFacts(bundleID: nil), profiles: [], pin: .auto)
        #expect(chain == [.allApps])
        var checked = 0
        for (label, kind) in kinds {
            for enabled in [false, true] {
                for previousLines in 0...AppContextOverride.maxPreviousLines {
                    for includeTitle in [false, true] {
                        for useLearned in [false, true] {
                            for deepLInstructions in [false, true] {
                                let old = EngineContext(enabled: enabled, previousLines: previousLines,
                                                        includeTitle: includeTitle, useLearned: useLearned,
                                                        deepLInstructions: deepLInstructions)
                                var engine = EngineConfig(name: "E", kind: kind, context: old)
                                engine.allow = EngineAllow(lines: true, title: includeTitle, deepLInstructions: deepLInstructions)
                                let amount: ContextAmount = enabled ? (previousLines == 0 ? .nearby : .conversation(previousLines)) : .off
                                let merged = ProfileChain.merge(chain, base: base(amount, learn: useLearned))
                                let got = ContextOptions.requestOptions(engine: engine, chain: merged)
                                let today = ContextOptions.requestOptions(engine: engine, profile: nil)
                                #expect(got == today,
                                        "\(label): enabled \(enabled) lines \(previousLines) title \(includeTitle) learned \(useLearned) deepL \(deepLInstructions): \(got) != \(today)")
                                checked += 1
                            }
                        }
                    }
                }
            }
        }
        #expect(checked == 6 * 2 * 9 * 2 * 2 * 2)
    }

    /// The same, with one app profile of each mode (design §8, row R1): the request is the one 1.1.4 made.
    @Test func anAppProfileOfEachModeMakesTheRequest1_1_4Made() {
        for (label, kind) in kinds {
            let old = EngineContext(enabled: true, previousLines: 3, includeTitle: false, useLearned: true, deepLInstructions: false)
            var engine = EngineConfig(name: "E", kind: kind, context: old)
            engine.allow = EngineAllow(lines: true, title: false, deepLInstructions: false)
            for mode in [AppContextOverride.Mode.off, .nearby, .conversation] {
                let p = profile(app, "App", when: [ProfileCondition(app: app)], context: AppContextOverride(mode: mode, previousLines: 3))
                let chain = ProfileChain.chain(for: WindowFacts(bundleID: app), profiles: [p], pin: .auto)
                let merged = ProfileChain.merge(chain, base: base(.nearby, learn: true))
                let got = ContextOptions.requestOptions(engine: engine, chain: merged)
                let today = ContextOptions.requestOptions(engine: engine, profile: p)
                let request = CtxFix.rich()
                #expect(RequestLayout.body(kind: LayoutKind.engine(kind), request: request, options: got)
                        == RequestLayout.body(kind: LayoutKind.engine(kind), request: request, options: today),
                        "\(label) \(mode.rawValue)")
            }
        }
    }

    /// §5.2's exception (c): an engine whose context was off, an app whose override sent lines and another engine with
    /// context on. The new rules apply: the chain's learn switch is the chain's, so the learned rows go where 1.1.4's
    /// OR kept them out.
    @Test func theNewRulesApplyWhenTheEngineWasOffAndAnAppSentLines() {
        let old = EngineContext(enabled: false, previousLines: 3, includeTitle: false, useLearned: true, deepLInstructions: false)
        var engine = EngineConfig(name: "E", kind: CtxFix.openAI(), context: old)
        engine.allow = EngineAllow(lines: true, title: false, deepLInstructions: false)
        let p = profile(app, "App", when: [ProfileCondition(app: app)], context: AppContextOverride(mode: .nearby))
        let chain = ProfileChain.chain(for: WindowFacts(bundleID: app), profiles: [p], pin: .auto)
        let merged = ProfileChain.merge(chain, base: base(.off, learn: true))
        let got = ContextOptions.requestOptions(engine: engine, chain: merged)
        let today = ContextOptions.requestOptions(engine: engine, profile: p)
        #expect(got.enabled && today.enabled)
        #expect(got.transcriptCount == 0 && today.transcriptCount == 0)
        // The learned rows go with the new rules; 1.1.4's OR left them out.
        #expect(got.includeLearned && !today.includeLearned)
    }

    @Test func theTableIsOneTable() {
        let chat = EngineConfig(name: "E", kind: CtxFix.openAI())
        let withNote = ProfileChain.merge([.allApps], base: base(.memory))
        var noted = withNote
        noted.note = "a note"
        // Off: today's request, byte for byte.
        #expect(ContextOptions.requestOptions(engine: chat, chain: allAppsChain(base(.off))) == .off)
        // Memory: the card, the note and the rows; nothing else.
        let memory = ContextOptions.requestOptions(engine: chat, chain: noted)
        #expect(memory.enabled && memory.memoryOnly && memory.transcriptCount == 0 && !memory.includeTitle && !memory.includeLearned)
        // Memory without anything to send: Off.
        #expect(ContextOptions.requestOptions(engine: chat, chain: withNote) == .off)
        // Nearby: the lines around, no earlier lines.
        let nearby = ContextOptions.requestOptions(engine: chat, chain: allAppsChain(base(.nearby)))
        #expect(nearby.enabled && nearby.transcriptCount == 0 && !nearby.longTranscript)
        // Conversation n: n earlier lines, and longTranscript over four.
        let conversation = ContextOptions.requestOptions(engine: chat, chain: allAppsChain(base(.conversation(3))))
        #expect(conversation.enabled && conversation.transcriptCount == 3 && !conversation.longTranscript)
        let long = ContextOptions.requestOptions(engine: chat, chain: allAppsChain(base(.conversation(5))))
        #expect(long.transcriptCount == 5 && long.longTranscript)
    }

    @Test func theLinesAreDeniedWhenTheEngineSaysSo() {
        let chat = EngineConfig(name: "E", kind: CtxFix.openAI(), allow: EngineAllow(lines: false))
        // Nothing to send: Off.
        #expect(ContextOptions.requestOptions(engine: chat, chain: allAppsChain(base(.nearby))) == .off)
        // With a note, the request is the memory case: the note and the rows, and no lines.
        var noted = allAppsChain(base(.nearby))
        noted.note = "a note"
        let denied = ContextOptions.requestOptions(engine: chat, chain: noted)
        #expect(denied.enabled && denied.memoryOnly && denied.transcriptCount == 0)
    }

    @Test func deepLTakesTheMemoryOnlyAsInstructions() {
        let deepL = EngineConfig(name: "D", kind: .deepL(baseURL: URL(string: "https://api.deepl.com")!, formality: nil))
        let withNote = ProfileChain.merge([.allApps], base: base(.memory))
        var noted = withNote
        noted.note = "a note"
        // Without the opt-in, the memory does not go.
        #expect(ContextOptions.requestOptions(engine: deepL, chain: noted) == .off)
        // With it, the memory goes as the instructions.
        let allowed = EngineConfig(name: "D", kind: deepL.kind, allow: EngineAllow(lines: true, title: false, deepLInstructions: true))
        let got = ContextOptions.requestOptions(engine: allowed, chain: noted)
        #expect(got.enabled && got.deepLInstructions && got.transcriptCount == 0)
    }

    @Test func appleTranslationAndTheEnginesThatOwnTheirBodyAreOutsideTheTable() {
        // Apple Translation (no engine) takes only replacement rows: Off.
        #expect(ContextOptions.requestOptions(engine: nil, chain: allAppsChain(base(.nearby))) == .off)
        // A template and a command own their body: today's options, and the layout sends them nothing either way.
        for kind in [EngineKind.httpTemplate(HTTPTemplate(url: "http://localhost:5000/t", body: "{}", resultPath: "t")),
                     .command(CommandSpec(executable: "/usr/bin/python3"))] {
            let engine = EngineConfig(name: "E", kind: kind, context: EngineContext(enabled: true, previousLines: 3))
            #expect(ContextOptions.requestOptions(engine: engine, chain: allAppsChain(base(.nearby)))
                    == ContextOptions.requestOptions(engine: engine, profile: nil))
        }
    }
}

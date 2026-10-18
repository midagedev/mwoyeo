import Foundation
import Testing
@testable import BenchKit

private func line(_ id: Int, _ speaker: String? = nil, _ text: String? = nil) -> BenchLine {
    BenchLine(id: id, speaker: speaker, text: text ?? "text \(id)", ref: "ref \(id)")
}

private func sequence(lines n: Int, screens: [[Int]], speakers: Bool = true, target: String = "ko") -> BenchSequence {
    BenchSequence(id: "t", kind: "chat", source: "ja", target: target, speakerVisible: speakers,
                  lines: (1...n).map { line($0, speakers ? (["A", "B"][$0 % 2]) : nil) }, screens: screens)
}

private let memory = Memory(
    entities: [MemoryEntity(name: "海", reading: "かい", dst: nil, gender: "male", role: "senior", speaksTo: ["A": "반말", "B": "해요체"])],
    document: MemoryDocument(title: "Doc", domain: "git", summary: "a tutorial"),
    window: MemoryWindow(title: "テニス部", app: "LINE", category: "Social Networking"),
    terms: [MemoryTerm(src: "合宿", dst: "엠티")])

@Suite struct ReplayTests {
    @Test func everyLineIsTranslatedOnceInBatchesOfThree() {
        let seq = sequence(lines: 10, screens: [[1, 2, 3, 4, 5, 6], [4, 5, 6, 7, 8, 9], [7, 8, 9, 10]])
        let plan = Replay.plan(seq)
        #expect(plan.map { $0.items.map(\.id) } == [[1, 2, 3], [4, 5, 6], [7, 8, 9], [10]])
        #expect(plan.map(\.screen) == [1, 1, 2, 3])
        #expect(plan.map(\.number) == [1, 2, 3, 4])
    }

    @Test func neighboursComeFromTheSameScreen() {
        let seq = sequence(lines: 9, screens: [[1, 2, 3, 4, 5, 6], [4, 5, 6, 7, 8, 9]])
        let plan = Replay.plan(seq)
        #expect(plan[0].above.isEmpty && plan[0].below.map(\.id) == [4, 5, 6])
        #expect(plan[1].above.map(\.id) == [1, 2, 3] && plan[1].below.isEmpty)
        // screen 2 adds 7, 8, 9: its lines above them are 4, 5, 6 (already translated)
        #expect(plan[2].above.map(\.id) == [4, 5, 6])
    }

    @Test func aSubtitleScreenGivesOneLineBatches() {
        let seq = sequence(lines: 4, screens: [[1], [2], [3, 4]])
        #expect(Replay.plan(seq).map { $0.items.map(\.id) } == [[1], [2], [3, 4]])
    }
}

@Suite struct ConditionParseTests {
    @Test func namesFromTheSpec() {
        #expect(ConditionSpec.parse("A")?.isOff == true)
        #expect(ConditionSpec.parse("B2")?.window == .previous(2))
        #expect(ConditionSpec.parse("B4")?.window == .previous(4))
        #expect(ConditionSpec.parse("C16")?.window == .conversation(16))
        let m = ConditionSpec.parse("M")!
        #expect(m.memory && m.window == .previous(2) && !m.learned && !m.windowMeta)
        let w = ConditionSpec.parse("W")!
        #expect(w.windowMeta && !w.memory && w.window == .previous(2))
        let l = ConditionSpec.parse("L")!
        #expect(l.learned && !l.memory)
        #expect(ConditionSpec.parse("B2+2")?.below == 2)
        #expect(ConditionSpec.parse("M4")?.window == .previous(4))
    }

    @Test func nonsenseIsRejected() {
        #expect(ConditionSpec.parse("") == nil)
        #expect(ConditionSpec.parse("X2") == nil)
        #expect(ConditionSpec.parse("a") == nil)
        #expect(ConditionSpec.parse("M+2") == nil)
    }
}

@Suite struct ReferenceLayoutTests {
    let layout = ReferenceLayout()

    private func step(_ seq: BenchSequence, upTo n: Int, memory: Memory = memory) -> Step {
        let plan = Replay.plan(seq)
        let batch = plan.first { $0.items.first!.id == n }!
        let history = seq.lines.filter { $0.id < n }.map { Turn(line: $0, translation: "t\($0.id)", trusted: true) }
        return Step(sequence: seq, memory: memory, batch: batch, history: history)
    }

    @Test func conditionAAddsNothing() throws {
        let seq = sequence(lines: 9, screens: [[1, 2, 3, 4, 5, 6, 7, 8, 9]])
        let p = try layout.build(ConditionSpec.parse("A")!, step: step(seq, upTo: 7), thread: ThreadState())
        #expect(p == Prompt())
        // and the wire is today's, untouched
        let wire = Wiring.compose(system: "S", user: "U", prompt: p)
        #expect(wire == Wire(system: "S", user: "U"))
    }

    @Test func b2CarriesThePreviousTwoSourceLinesAndTheSpeakers() throws {
        let seq = sequence(lines: 9, screens: [[1, 2, 3, 4, 5, 6, 7, 8, 9]])
        let p = try layout.build(ConditionSpec.parse("B2")!, step: step(seq, upTo: 7), thread: ThreadState())
        #expect(p.contextIDs == [5, 6])
        let user = try JSONSerialization.jsonObject(with: Data(p.user!.utf8)) as! [String: Any]
        #expect(user["context"] as? [String] == ["B: text 5", "A: text 6"])
        #expect(user["lines"] as? [String] == ["text 7", "text 8", "text 9"])
        #expect(user["speakers"] as? [String] == ["B", "A", "B"])
        #expect(p.user!.contains(p.historyText))
        #expect(p.systemAddition.contains("\"context\"") && p.systemAddition.contains("\"speakers\""))
        #expect(p.memoryText.isEmpty && !p.askForTerms)
    }

    @Test func hiddenSpeakersAreNotSent() throws {
        let seq = sequence(lines: 9, screens: [[1, 2, 3, 4, 5, 6, 7, 8, 9]], speakers: false)
        let p = try layout.build(ConditionSpec.parse("B2")!, step: step(seq, upTo: 4), thread: ThreadState())
        let user = try JSONSerialization.jsonObject(with: Data(p.user!.utf8)) as! [String: Any]
        #expect(user["speakers"] == nil)
        #expect(user["context"] as? [String] == ["text 2", "text 3"])
    }

    @Test func belowLinesJoinTheContext() throws {
        let seq = sequence(lines: 9, screens: [[1, 2, 3, 4, 5, 6]])
        let p = try layout.build(ConditionSpec.parse("B2+2")!, step: step(seq, upTo: 1), thread: ThreadState())
        #expect(p.contextIDs == [4, 5])
    }

    @Test func conversationWindowDropsTheOlderHalfWhenFull() {
        let spec = ConditionSpec.parse("C16")!
        let seq = sequence(lines: 33, screens: [Array(1...33)])
        let thread = ThreadState()
        var sizes: [Int] = []
        for batch in Replay.plan(seq).prefix(11) {
            let s = Step(sequence: seq, memory: memory, batch: batch, history: [])
            layout.observe(spec, step: s, translations: batch.items.map(\.text), replyText: "", thread: thread)
            sizes.append(thread.conversation.count)
        }
        // append-only to 15, then the older 7 go at once (15 + 3 > 16), and so on: the prefix changes once per half window
        #expect(sizes == [3, 6, 9, 12, 15, 11, 14, 10, 13, 16, 11])
        #expect(thread.conversation.map(\.id) == Array(23...33))
    }

    @Test func memoryConditionRendersTheNotesInTheSystemPrompt() throws {
        let seq = sequence(lines: 9, screens: [[1, 2, 3, 4, 5, 6, 7, 8, 9]])
        let p = try layout.build(ConditionSpec.parse("M")!, step: step(seq, upTo: 4), thread: ThreadState())
        #expect(p.memoryText == memory.render())
        #expect(p.systemAddition.contains(p.memoryText))
        #expect(p.systemAddition.contains("Notes from the user"))
        #expect(p.systemAddition.contains("Speech levels:"))     // Korean target, speaks_to present
        let en = sequence(lines: 9, screens: [[1, 2, 3, 4, 5, 6, 7, 8, 9]], target: "en")
        let pe = try layout.build(ConditionSpec.parse("M")!, step: step(en, upTo: 4), thread: ThreadState())
        #expect(!pe.systemAddition.contains("Speech levels:"))
    }

    @Test func windowConditionCarriesOnlyTheWindow() throws {
        let seq = sequence(lines: 9, screens: [[1, 2, 3, 4, 5, 6, 7, 8, 9]])
        let p = try layout.build(ConditionSpec.parse("W")!, step: step(seq, upTo: 4), thread: ThreadState())
        #expect(p.memoryText == "Window: テニス部 | app: LINE | category: Social Networking")
        #expect(!p.memoryText.contains("People") && !p.memoryText.contains("Terms"))
    }

    @Test func hiddenSpeakersHideSpeaksTo() throws {
        let seq = sequence(lines: 9, screens: [[1, 2, 3, 4, 5, 6, 7, 8, 9]], speakers: false)
        let p = try layout.build(ConditionSpec.parse("M")!, step: step(seq, upTo: 4), thread: ThreadState())
        #expect(!p.memoryText.contains("speaks to") && p.memoryText.contains("海 (かい)"))
    }

    @Test func learnedTermsFollowTheAdmissionRules() {
        let thread = ThreadState()
        let items = [BenchLine(id: 1, text: "海は来た。合宿だ", ref: "")]
        func learn(_ json: String, translations: [String] = ["카이는 왔다. 엠티다"]) {
            ReferenceLayout.learn(replyText: json, items: items, translations: translations, thread: thread)
        }
        learn(#"{"translations": ["x"], "terms": [{"src": "海", "dst": "카이"}, {"src": "山", "dst": "산"}, {"src": "合宿", "dst": "합숙"}]}"#)
        // 山 is not in the lines, 합숙 is not in the translations: only 海 is admitted
        #expect(thread.learnedOrder == ["海"] && thread.learned["海"]?.dst == "카이")
        learn(#"{"terms": [{"src": "海", "dst": "카이"}]}"#)
        #expect(thread.learned["海"]?.seen == 2)
        // a different rendering is a contradiction; the second one drops the term
        learn(#"{"terms": [{"src": "海", "dst": "엠티"}]}"#)
        #expect(thread.learned["海"]?.dst == "카이" && thread.learned["海"]?.contradicted == 1)
        learn(#"{"terms": [{"src": "海", "dst": "엠티"}]}"#)
        #expect(thread.learned["海"] == nil && thread.learnedOrder.isEmpty)
        // a fenced reply and an overlong or multi-line term
        learn("```json\n{\"terms\": [{\"src\": \"合宿\", \"dst\": \"엠티\"}]}\n```")
        #expect(thread.learnedOrder == ["合宿"])
        learn(#"{"terms": [{"src": "合宿", "dst": "엠티\n엠티"}]}"#)
        #expect(thread.learned["合宿"]?.dst == "엠티")
    }

    @Test func theLearnedBlockAndTheTermsRequestReachThePrompt() throws {
        let seq = sequence(lines: 9, screens: [[1, 2, 3, 4, 5, 6, 7, 8, 9]])
        let thread = ThreadState()
        thread.learned["海"] = LearnedTerm(dst: "카이", seen: 1, contradicted: 0)
        thread.learnedOrder = ["海"]
        let p = try layout.build(ConditionSpec.parse("L")!, step: step(seq, upTo: 4), thread: thread)
        #expect(p.askForTerms && p.systemAddition.contains("海 = 카이") && p.memoryText.isEmpty)
        let wire = Wiring.compose(system: "Intro.\nReply with only {\"translations\": [...]}.", user: "U", prompt: p)
        #expect(wire.system.contains("\"terms\": [{\"src\""))
        #expect(!wire.system.contains("Reply with only {\"translations\": [...]}."))
    }
}

@Suite struct EngineTests {
    @Test func openAIUsageIncludingLlamaTimings() throws {
        let plain = try JSONSerialization.jsonObject(with: Data(#"{"usage": {"prompt_tokens": 111, "completion_tokens": 70, "prompt_tokens_details": {"cached_tokens": 56}}}"#.utf8)) as! [String: Any]
        #expect(Usage.openAI(plain) == Usage(input: 111, output: 70, cached: 56))
        let llama = try JSONSerialization.jsonObject(with: Data(#"{"usage": {"prompt_tokens": 90, "completion_tokens": 12}, "timings": {"cache_n": 64, "prompt_n": 26}}"#.utf8)) as! [String: Any]
        #expect(Usage.openAI(llama) == Usage(input: 90, output: 12, cached: 64))
        #expect(Usage.openAI([:]) == nil)
    }

    @Test func anthropicUsageAddsTheCacheFields() throws {
        let root = try JSONSerialization.jsonObject(with: Data(#"{"usage": {"input_tokens": 30, "cache_read_input_tokens": 500, "cache_creation_input_tokens": 20, "output_tokens": 44}}"#.utf8)) as! [String: Any]
        #expect(Usage.anthropic(root) == Usage(input: 550, output: 44, cached: 500, cacheWrite: 20))
    }

    @Test func theLayoutRecordSplitsTheTokensAndFindsTheSharedPrefix() {
        var prompt = Prompt()
        prompt.historyText = "[\"c\"]"
        let a = Wire(system: "system prompt", user: "{\"context\":[\"c\"],\"lines\":[\"x\"]}")
        let b = Wire(system: "system prompt", user: "{\"context\":[\"c\",\"d\"],\"lines\":[\"y\"]}")
        let rec = LayoutRecord.measure(wire: b, prompt: prompt, previous: a, usage: Usage(input: 40, output: 5))
        #expect(rec.stableChars == 13 && rec.historyChars == 5)
        // calibrated: the parts add up to the reported prompt tokens
        #expect(abs(rec.stableTok + rec.historyTok + rec.volatileTok - 40) < 1e-9)
        #expect(rec.calibration != nil)
        // the prefix shared with the previous request ends where the context lists diverge: `{"context":["c"` then `]` vs `,`
        #expect(rec.lcpTok > rec.stableTok && rec.lcpTok < 40)
        let first = LayoutRecord.measure(wire: a, prompt: prompt, previous: nil, usage: nil)
        #expect(first.lcpTok == 0 && first.calibration == nil)
    }

    @Test func estimateMatchesThePythonRule() {
        #expect(Tokens.estimate("가나다") == 3.0)
        #expect(abs(Tokens.estimate("abcd") - 1.08) < 1e-9)
        #expect(abs(Tokens.estimate("a b") - 0.54) < 1e-9)
    }

    @Test func theRenderedMemoryIsTheTextThePythonScorerPins() {
        let mem = Memory(entities: [MemoryEntity(name: "Mina", reading: nil, dst: nil, gender: "female", role: nil, speaksTo: ["海": "해요체"]),
                                    MemoryEntity(name: "海", reading: "かい", dst: nil, gender: "male", role: nil, speaksTo: ["Mina": "반말"])],
                         document: nil, window: MemoryWindow(title: "テニス部", app: "LINE", category: "Social Networking"),
                         terms: [MemoryTerm(src: "合宿", dst: "엠티")])
        let want = "Window: テニス部 | app: LINE | category: Social Networking\nPeople:\n- Mina; female; speaks to 海: 해요체\n- 海 (かい); male; speaks to Mina: 반말\nTerms: 合宿 = 엠티"
        #expect(mem.render() == want)
    }
}

@Suite struct RunTests {
    @Test func theOracleReplaysEverySequenceAndWritesTheFiles() async throws {
        let seq = sequence(lines: 7, screens: [[1, 2, 3, 4], [3, 4, 5, 6, 7]])
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let spec = ConditionSpec.parse("B2")!
        let options = RunOptions(spec: spec, layout: ReferenceLayout(), layoutName: "reference", engine: OracleEngine(name: "oracle"), out: tmp)
        try await Runner.run([(seq, memory)], options: options)
        let out = try JSONDecoder().decode(SequenceOutput.self, from: Data(contentsOf: tmp.appendingPathComponent("t.json")))
        #expect(out.condition == "B2")
        #expect(out.translations["5"] == "ref 5" && out.translations.count == 7)
        #expect(out.requests.map(\.items) == [[1, 2, 3], [4], [5, 6, 7]])
        #expect(out.requests[0].context == [] && out.requests[1].context == [2, 3])
        #expect(out.requests[2].layout.lcpTok > 0)
        let meta = try JSONDecoder().decode(RunMeta.self, from: Data(contentsOf: tmp.appendingPathComponent("meta.json")))
        #expect(meta.condition == "B2" && meta.engine == "oracle" && meta.jobs == 1)
    }

    @Test func theUnconnectedT2SeamFailsBeforeTheFirstRequest() async throws {
        let seq = sequence(lines: 4, screens: [[1, 2, 3, 4]])
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let options = RunOptions(spec: ConditionSpec.parse("M")!, layout: T2Layout(), layoutName: "t2", engine: OracleEngine(name: "oracle"), out: tmp)
        await #expect(throws: SeamError.self) { try await Runner.run([(seq, memory)], options: options) }
    }
}

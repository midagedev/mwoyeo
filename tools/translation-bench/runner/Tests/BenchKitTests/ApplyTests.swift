import Foundation
import Testing
import MwoyeoCore
@testable import BenchKit

// Round both-bench (2026-10-21): `--apply hint|both|both-names` and `--memory-dir`. The gates:
//   1. `both` writes an entity's dst into the item line being translated, `hint` does not, and a history line is never rewritten.
//   2. `both-names` rewrites entities only; `both` rewrites the terms too.
//   3. The rows still go out as hints, selected on the original lines (a replaced name keeps its row), and are the same rows in every arm.
//   4. Substituting the texts a body already carries gives the same bytes (the re-encoding is Core's), so a request nothing was written
//      into is byte-identical across arms.
//   5. The run records which lines were rewritten, and only under `--apply both|both-names`.
// FAIL-first: each of these was run on the layout before `SourceRewrite.substituting` was wired in (see the round's note).

private let benchRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

private let local = LayoutKind.engine(.openAICompatible(baseURL: URL(string: "http://127.0.0.1:11434/v1")!, model: "gemma4:e4b",
                                                        thinking: .off, extraHeaders: [:]))
private let cloud = LayoutKind.engine(.anthropic(baseURL: EngineKind.anthropicDefaultBaseURL, model: "claude-haiku-5-5", thinking: .off))

/// chat-ja-ko-1 with the named memory (every entity has its target form). The batch is `number` of the plan (1: lines 1-3, 2: lines 4-6);
/// the history is every earlier line plus `extra` (the line translated last, so the context window holds it).
private func step(batch number: Int, extra: [BenchLine] = []) throws -> Step {
    let (seq, memory) = try #require(Corpus.load(root: benchRoot, only: ["chat-ja-ko-1"], memoryDir: "memory-named").first)
    let plan = Replay.plan(seq)
    let done = Set(plan.prefix(number - 1).flatMap { $0.items.map(\.id) })
    let history = (seq.lines.filter { done.contains($0.id) } + extra).map { Turn(line: $0, translation: "번역 \($0.id)", trusted: true) }
    return Step(sequence: seq, memory: memory, batch: plan[number - 1], history: history)
}

/// The last user message of a body as the model reads it.
private func user(_ body: Data?) throws -> [String: Any] {
    let sent = Wiring.messages(ofBody: try #require(body))
    return try #require(JSONSerialization.jsonObject(with: Data(sent.user.utf8)) as? [String: Any])
}

/// The source texts of `context_before` (plain strings, or `{src, dst}` pairs when translations ride along).
private func contextBefore(_ body: Data?) throws -> [String] {
    let raw = try user(body)["context_before"] as? [Any] ?? []
    return raw.compactMap { ($0 as? String) ?? ($0 as? [String: Any])?["src"] as? String }
}

private func translateTexts(_ body: Data?) throws -> [String] {
    ((try user(body)["translate"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }
}

private let m = ConditionSpec.parse("M")!

@Suite struct ApplyModeTests {
    @Test func bothWritesAnEntitysTargetIntoTheItemLineAndHintDoesNot() throws {
        // line 5 is "宿は海が取ってくれるんだよね?" (海 is a person row, dst 카이); the history line 90 names 海 too and stays as it was
        let named = BenchLine(id: 90, text: "海に伝えておいて", ref: "")
        let s = try step(batch: 2, extra: [named])
        #expect(s.batch.items.map(\.id) == [4, 5, 6])
        let hint = try T2Layout(kind: local, apply: .hint).build(m, step: s, thread: ThreadState())
        let both = try T2Layout(kind: local, apply: .both).build(m, step: s, thread: ThreadState())
        let hintTexts = try translateTexts(hint.bodyOverride), bothTexts = try translateTexts(both.bodyOverride)
        #expect(hintTexts[1] == "宿は海が取ってくれるんだよね?")
        #expect(bothTexts[1] == "宿は카이が取ってくれるんだよね?", "\(bothTexts)")
        #expect(hint.rewrites.isEmpty)
        #expect(both.rewrites == [ItemRewrite(id: 5, text: "宿は카이が取ってくれるんだよね?", spans: [["海", "카이"]])])
        // the history line is the screen's text in both arms, and no written target leaks into it
        let before = try contextBefore(both.bodyOverride), hintBefore = try contextBefore(hint.bodyOverride)
        #expect(before == hintBefore && before.contains("海に伝えておいて"), "\(before)")
        #expect(!before.contains { $0.contains("카이") })
    }

    @Test func bothNamesLeavesTheTermRowsAsHintsAndBothTakesThemToo() throws {
        let s = try step(batch: 1)   // lines 1-3; line 1 is "みんな、今週末の合宿どうする?" (合宿 is a term row, dst 엠티)
        let hint = try T2Layout(kind: local, apply: .hint).build(m, step: s, thread: ThreadState())
        let names = try T2Layout(kind: local, apply: .bothNames).build(m, step: s, thread: ThreadState())
        let both = try T2Layout(kind: local, apply: .both).build(m, step: s, thread: ThreadState())
        let hintTexts = try translateTexts(hint.bodyOverride), namesTexts = try translateTexts(names.bodyOverride)
        let bothTexts = try translateTexts(both.bodyOverride)
        #expect(hintTexts[0] == "みんな、今週末の合宿どうする?")
        #expect(namesTexts[0] == "みんな、今週末の合宿どうする?")
        #expect(bothTexts[0] == "みんな、今週末の엠티どうする?")
        #expect(names.rewrites.map(\.id) == [] && both.rewrites.first?.id == 1)
        // no entity name stands in line 1, so both-names changes nothing: the same bytes as hint
        #expect(names.bodyOverride == hint.bodyOverride)
    }

    @Test func theRowsAreTheSameInEveryArmAndAReplacedNameKeepsItsHint() throws {
        let s = try step(batch: 2)
        let rows = try ["hint", "both", "both-names"].map { name -> [String] in
            let p = try T2Layout(kind: local, apply: ApplyMode(rawValue: name)!).build(m, step: s, thread: ThreadState())
            return try #require(try user(p.bodyOverride)["memory"] as? [String])
        }
        #expect(rows[0] == rows[1] && rows[1] == rows[2])
        #expect(rows[0].contains { $0.hasPrefix("海 -> 카이 (person, m,") }, "\(rows[0])")
    }

    @Test func aRequestNothingIsWrittenIntoIsByteIdenticalToHintOnEveryEngineKind() throws {
        let s = try step(batch: 4)   // lines 10-12: no entity name or term stands in them
        for kind in [local, cloud] {
            let hint = try T2Layout(kind: kind, apply: .hint).build(m, step: s, thread: ThreadState())
            let both = try T2Layout(kind: kind, apply: .both).build(m, step: s, thread: ThreadState())
            #expect(both.rewrites.isEmpty && both.bodyOverride == hint.bodyOverride && hint.bodyOverride != nil)
            let items = s.batch.items.map(\.text)
            #expect(SourceRewrite.substituting(items: items, intoBody: hint.bodyOverride!) == hint.bodyOverride)
        }
    }

    @Test func substitutingAnItemChangesOnlyThatTextOnEveryEngineKind() throws {
        let s = try step(batch: 2)
        for kind in [local, cloud] {
            let body = try #require(try T2Layout(kind: kind).build(m, step: s, thread: ThreadState()).bodyOverride)
            var items = s.batch.items.map(\.text)
            items[1] = "X"
            let changed = try #require(SourceRewrite.substituting(items: items, intoBody: body))
            let texts = try translateTexts(changed)
            #expect(texts == items)
            let back = try #require(SourceRewrite.substituting(items: s.batch.items.map(\.text), intoBody: changed))
            #expect(back == body, "restoring the texts gives the original bytes")
        }
        let plain = try #require(try T2Layout(kind: local).build(m, step: s, thread: ThreadState()).bodyOverride)
        #expect(SourceRewrite.substituting(items: ["only one"], intoBody: plain) == nil, "a different item count is not a substitution")
        #expect(SourceRewrite.substituting(items: [], intoBody: Data("not json".utf8)) == nil)
    }

    @Test func aConditionWithoutTheMemoryWritesNothing() throws {
        let s = try step(batch: 2)
        let b2 = try T2Layout(kind: local, apply: .both).build(ConditionSpec.parse("B2")!, step: s, thread: ThreadState())
        #expect(b2.rewrites.isEmpty)
        let plain = try T2Layout(kind: local).build(ConditionSpec.parse("B2")!, step: s, thread: ThreadState())
        #expect(b2.bodyOverride == plain.bodyOverride)
    }
}

@Suite struct ApplyRunTests {
    private func run(_ apply: ApplyMode, seq id: String = "chat-ja-ko-1", memoryDir: String = "memory-named") async throws -> (SequenceOutput, RunMeta) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let kind = try #require(EngineFile(name: "o", kind: "oracle").layoutKind)
        var options = RunOptions(spec: m, layout: T2Layout(kind: kind, apply: apply), layoutName: "t2", engine: OracleEngine(name: "oracle"), out: tmp)
        options.apply = apply
        options.memoryDir = memoryDir == "memory" ? nil : memoryDir
        try await Runner.run(try Corpus.load(root: benchRoot, only: [id], memoryDir: memoryDir), options: options)
        let out = try JSONDecoder().decode(SequenceOutput.self, from: Data(contentsOf: tmp.appendingPathComponent("\(id).json")))
        let meta = try JSONDecoder().decode(RunMeta.self, from: Data(contentsOf: tmp.appendingPathComponent("meta.json")))
        return (out, meta)
    }

    @Test func theRunSaysWhichLinesWereRewrittenAndOnlyUnderBothModes() async throws {
        let (hint, hintMeta) = try await run(.hint)
        #expect(hint.requests.allSatisfy { $0.replaced == nil } && hintMeta.apply == nil && hintMeta.replacedLines == nil)
        let (both, meta) = try await run(.both)
        let replaced = both.requests.flatMap { $0.replaced ?? [] }
        #expect(both.requests.allSatisfy { $0.replaced != nil })
        #expect(replaced.count > 0 && replaced.contains { $0.id == 5 && $0.text == "宿は카이が取ってくれるんだよね?" })
        #expect(meta.apply == "both" && meta.memoryDir == "memory-named" && meta.replacedLines == replaced.count)
        // the translations are the references (the oracle), so scoring and judging read the original lines unchanged
        #expect(hint.translations == both.translations)
        // the request records differ where a line was written into
        let hintVolatile = hint.requests.map(\.layout.volatileChars), bothVolatile = both.requests.map(\.layout.volatileChars)
        #expect(hintVolatile != bothVolatile)
    }

    @Test func bothNamesRewritesFewerLinesThanBoth() async throws {
        let (_, names) = try await run(.bothNames)
        let (_, both) = try await run(.both)
        #expect(0 < (names.replacedLines ?? 0) && (names.replacedLines ?? 0) < (both.replacedLines ?? 0))
    }
}

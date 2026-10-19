import Foundation
import Testing
import MwoyeoCore
import MwoyeoEngines
@testable import BenchKit

// Round T3 R4: the bench under `--layout t2` sends the product's request. The gates:
//   1. T2Layout builds the bytes `RequestLayout.body` gives for a `ContextRequest` written out by hand the way `ContextBook.request`
//      fills one (the card, the note, the rows, the lines before and after), for B, B+k and M, and today's body for A.
//   2. Those bytes reach the wire unchanged: the bench's `ChatEngine` and the app's own `EngineClient` post the same body to the
//      mock server (tools/mock-openai, `--dump`) for the same fixture.
//   3. FAIL-first: a layout that drops the rows, the card or the lines after, or that changes the card, no longer equals the hand-made body.

private let benchRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
private let repoRoot = benchRoot.deletingLastPathComponent().deletingLastPathComponent()

private let local = LayoutKind.engine(.openAICompatible(baseURL: URL(string: "http://127.0.0.1:11434/v1")!, model: "gemma3:4b",
                                                        thinking: .off, extraHeaders: [:]))

/// chat-ja-ko-1 of the corpus: the third batch (lines 7-9, after six translated lines) and the first (lines 1-3, with 4-6 below).
private func fixture(batch number: Int) throws -> Step {
    let (seq, memory) = try #require(Corpus.load(root: benchRoot, only: ["chat-ja-ko-1"]).first)
    let plan = Replay.plan(seq)
    let batch = plan[number - 1]
    let done = Set(plan.prefix(number - 1).flatMap { $0.items.map(\.id) })
    let history = seq.lines.filter { done.contains($0.id) }.map { Turn(line: $0, translation: "번역 \($0.id)", trusted: true) }
    return Step(sequence: seq, memory: memory, batch: batch, history: history)
}

private func text(_ id: Int, _ step: Step) -> String { step.sequence.lines.first { $0.id == id }!.text }

/// `ContextBook.request` for this fixture, by hand: the rows are the memory of chat-ja-ko-1 written the way a user would fill the sheet.
private func handMadeRequest(_ step: Step, below: Int, memory: Bool) -> ContextRequest {
    let ids = step.batch.items.map(\.id)
    let first = ids.first!
    let all = step.sequence.lines
    let rows: [MemoryEntry] = memory ? [
        MemoryEntry(src: "ミナ", dst: "ミナ", kind: .person, gender: .f, note: "club 2nd-year", reading: "みな",
                    addressing: [Addressing(to: "ユウ", register: .casual), Addressing(to: "海", register: .casual)]),
        MemoryEntry(src: "海", dst: "海", kind: .person, gender: .m, note: "club senior", reading: "かい",
                    addressing: [Addressing(to: "ミナ", register: .casual), Addressing(to: "ユウ", register: .casual)]),
        MemoryEntry(src: "ユウ", dst: "ユウ", kind: .person, gender: .f, note: "club 1st-year", reading: "ゆう",
                    addressing: [Addressing(to: "ミナ", register: .polite), Addressing(to: "海", register: .polite)]),
        MemoryEntry(src: "合宿", dst: "엠티", kind: .term), MemoryEntry(src: "民宿", dst: "펜션", kind: .term),
    ] : []
    return ContextRequest(
        items: step.batch.items.map(\.text),
        before: all.filter { $0.id < first }.map { ContextLine(source: $0.text, translation: "번역 \($0.id)", trusted: true) },
        after: all.filter { $0.id > ids.last! && step.batch.below.map(\.id).contains($0.id) }.prefix(below).map(\.text),
        memory: rows, card: DocumentCard(appName: "LINE", domain: "social", title: "テニス部 合宿どうする?"), note: "",
        source: "ja", target: "ko", glossary: [], threadKey: "chat-ja-ko-1")
}

private func handMade(_ step: Step, previous: Int, below: Int, memory: Bool) -> Data {
    RequestLayout.body(kind: local, request: handMadeRequest(step, below: below, memory: memory),
                       options: ContextOptions.from(engine: EngineContext(enabled: true, previousLines: previous)))
}

@Suite struct ProductLayoutTests {
    @Test func b2IsTheCardAndTheTwoPreviousLinesInTheProductsBytes() throws {
        let step = try fixture(batch: 3)
        let prompt = try T2Layout(kind: local).build(ConditionSpec.parse("B2")!, step: step, thread: ThreadState())
        let want = handMade(step, previous: 2, below: 0, memory: false)
        #expect(prompt.bodyOverride == want, "\(String(decoding: prompt.bodyOverride ?? Data(), as: UTF8.self))")
        let sent = Wiring.messages(ofBody: want)
        #expect(sent.system.hasSuffix("Document: LINE (social), window \"テニス部 合宿どうする?\"."))
        let user = try #require(JSONSerialization.jsonObject(with: Data(sent.user.utf8)) as? [String: Any])
        #expect(user["context_before"] as? [String] == [text(5, step), text(6, step)])
        #expect(user["memory"] == nil && user["context_after"] == nil)
        // the size accounting reads the lines back from the body
        #expect(prompt.contextIDs == [5, 6] && prompt.historyText == ReferenceLayout.json([text(5, step), text(6, step)]))
    }

    @Test func b2PlusTwoAddsTheLinesBelowOnTheScreen() throws {
        let step = try fixture(batch: 1)
        #expect(step.batch.below.map(\.id) == [4, 5, 6])
        let prompt = try T2Layout(kind: local).build(ConditionSpec.parse("B2+2")!, step: step, thread: ThreadState())
        #expect(prompt.bodyOverride == handMade(step, previous: 2, below: 2, memory: false))
        let user = try #require(JSONSerialization.jsonObject(with: Data(Wiring.messages(ofBody: prompt.bodyOverride!).user.utf8)) as? [String: Any])
        #expect(user["context_after"] as? [String] == [text(4, step), text(5, step)] && user["context_before"] == nil)
        #expect(prompt.contextIDs == [4, 5] && prompt.historyFragments == [ReferenceLayout.json([text(4, step), text(5, step)])])
        // plain B2 on the same batch carries no lines below
        let plain = try T2Layout(kind: local).build(ConditionSpec.parse("B2")!, step: step, thread: ThreadState())
        #expect(plain.bodyOverride == handMade(step, previous: 2, below: 0, memory: false))
    }

    /// The corpus screens add their lines at the bottom: a batch with nothing below it is the same request under B2 and B2+2
    /// (233 of the 252 requests), so the two conditions differ on the 19 that have lines below and nowhere else.
    @Test func withNothingBelowB2PlusTwoIsByteIdenticalToB2() throws {
        let step = try fixture(batch: 3)
        #expect(step.batch.below.isEmpty)
        let layout = T2Layout(kind: local)
        let plain = try layout.build(ConditionSpec.parse("B2")!, step: step, thread: ThreadState())
        let plus = try layout.build(ConditionSpec.parse("B2+2")!, step: step, thread: ThreadState())
        #expect(plain.bodyOverride == plus.bodyOverride && plain.bodyOverride != nil)
    }

    @Test func mAddsOnlyTheRowsTheLinesCall() throws {
        let step = try fixture(batch: 3)   // lines 7-9: ユウ, ミナ and ユウ speak; ミナ and ユウ and 海 occur in the lines
        let prompt = try T2Layout(kind: local).build(ConditionSpec.parse("M")!, step: step, thread: ThreadState())
        let want = handMade(step, previous: 2, below: 0, memory: true)
        #expect(prompt.bodyOverride == want, "\(Wiring.messages(ofBody: prompt.bodyOverride ?? Data()).user)\n\(Wiring.messages(ofBody: want).user)")
        let sent = Wiring.messages(ofBody: prompt.bodyOverride!)
        let user = try #require(JSONSerialization.jsonObject(with: Data(sent.user.utf8)) as? [String: Any])
        let rows = try #require(user["memory"] as? [String])
        #expect(rows.allSatisfy { !$0.hasPrefix("民宿") } && !rows.isEmpty, "a row goes out only when its name is in the items or the lines around them: \(rows)")
        #expect(prompt.memoryText.contains(rows[0]))
    }

    @Test func aIsTodaysRequestAndTheLayoutAddsNothing() throws {
        let step = try fixture(batch: 3)
        #expect(try T2Layout(kind: local).build(ConditionSpec.parse("A")!, step: step, thread: ThreadState()) == Prompt())
    }

    @Test func theNoteIsTheDocumentAndSubtitlesSendNoAddressing() throws {
        let memory = Memory(entities: [MemoryEntity(name: "A", reading: nil, dst: nil, gender: "nonbinary", role: "r", speaksTo: ["B": "합쇼체", "C": "해요체"])],
                            document: MemoryDocument(title: "T", domain: "d", summary: "s"), window: nil, terms: [])
        #expect(T2Layout.note(memory) == "T; d; s")
        #expect(T2Layout.card(memory) == nil)
        let spoken = T2Layout.rows(memory, speech: true)
        #expect(spoken.map(\.addressing) == [[Addressing(to: "B", register: .formal), Addressing(to: "C", register: .polite)]])
        #expect(spoken[0].dst == "A" && spoken[0].gender == .n && spoken[0].kind == .person)
        #expect(T2Layout.rows(memory, speech: false)[0].addressing.isEmpty)
    }

    // FAIL-first: the checks above must see each of these defects.
    @Test func aLayoutThatLosesAPartDoesNotEqualTheHandMadeBody() throws {
        let step = try fixture(batch: 1)
        let want = handMade(step, previous: 2, below: 2, memory: true)
        func request(_ edit: (inout ContextRequest) -> Void) -> Data {
            var r = handMadeRequest(step, below: 2, memory: true)
            edit(&r)
            return RequestLayout.body(kind: local, request: r, options: ContextOptions.from(engine: EngineContext(enabled: true, previousLines: 2)))
        }
        let full = request { _ in }
        #expect(full == want, "the baseline of this test is the hand-made body")
        #expect(request { $0.memory = [] } != want)
        #expect(request { $0.card = nil } != want)
        #expect(request { $0.after = [] } != want)
        #expect(request { $0.card = DocumentCard(appName: "LINE", domain: "social", title: "other") } != want)
        #expect(request { $0.items = Array($0.items.dropLast()) } != want)
    }

    @Test func theOracleSizesTheProductsOwnPromptNotTodaysSystemPrompt() async throws {
        let step = try fixture(batch: 3)
        let kind = try #require(EngineFile(name: "o", kind: "oracle").layoutKind)
        let prompt = try T2Layout(kind: kind).build(ConditionSpec.parse("M")!, step: step, thread: ThreadState())
        let reply = await OracleEngine(name: "oracle").translate(EngineRequest(items: step.batch.items, source: "ja", target: "ko", prompt: prompt, sequenceID: "t"))
        #expect(reply.wire.system.contains("\"translate\" array") && reply.wire.user.contains("\"translate\""))
        #expect(reply.translations == step.batch.items.map(\.ref))
    }
}

/// The mock server (tools/mock-openai) with `--dump`: the bodies it was sent, in order, byte for byte.
private final class Mock: @unchecked Sendable {
    let port: Int
    let dump: URL
    private let process = Process()

    init?() {
        guard let port = Self.freePort() else { return nil }
        self.port = port
        dump = FileManager.default.temporaryDirectory.appendingPathComponent("bench-mock-\(UUID().uuidString)")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", repoRoot.appendingPathComponent("tools/mock-openai/server.py").path, "\(port)", "ok", "", "--dump", dump.path]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        for _ in 0..<100 {
            if Self.accepts(port) { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        stop()
        return nil
    }

    var base: URL { URL(string: "http://127.0.0.1:\(port)/v1")! }

    func stop() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: dump)
    }

    var bodies: [Data] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dump.path)) ?? []).sorted()
        return names.map { (try? Data(contentsOf: dump.appendingPathComponent($0))) ?? Data() }
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
        var addr = sockaddr_in(sin_len: UInt8(MemoryLayout<sockaddr_in>.size), sin_family: sa_family_t(AF_INET), sin_port: UInt16(port).bigEndian,
                               sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")), sin_zero: (0, 0, 0, 0, 0, 0, 0, 0))
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0
    }
}

private struct NoSecrets: SecretStore {
    func secret(for engine: UUID) throws -> String? { nil }
    func setSecret(_ secret: String?, for engine: UUID) throws {}
}

@Suite struct ProductWireTests {
    /// The bench posts the bytes the app's own `EngineClient` posts, for B2, B2+2 and M on a corpus fixture.
    @Test func theBenchEngineAndTheAppsEngineClientPostTheSameBytes() async throws {
        let mock = try #require(Mock(), "the mock server starts")
        defer { mock.stop() }
        let file = try JSONDecoder().decode(EngineFile.self, from: Data(
            #"{"name":"mock","kind":"openAICompatible","baseURL":"\#(mock.base.absoluteString)","model":"gemma3:4b","thinking":"off"}"#.utf8))
        let bench = try EngineFactory.make(file)
        let layout = T2Layout(kind: try #require(file.layoutKind))
        let kind = EngineKind.openAICompatible(baseURL: mock.base, model: "gemma3:4b", thinking: .off, extraHeaders: [:])
        let config = EngineConfig(name: "mock", kind: kind, context: EngineContext(enabled: true, previousLines: 2))
        let client = EngineClient(secrets: NoSecrets())
        var compared = 0
        for (name, number) in [("B2", 3), ("B2+2", 1), ("M", 3), ("M", 1)] {
            let step = try fixture(batch: number)
            let prompt = try layout.build(ConditionSpec.parse(name)!, step: step, thread: ThreadState())
            let n = mock.bodies.count
            let reply = await bench.translate(EngineRequest(items: step.batch.items, source: "ja", target: "ko", prompt: prompt, sequenceID: "chat-ja-ko-1"))
            #expect(reply.translations?.count == step.batch.items.count, "\(name) \(number): \(reply.error ?? "")")
            // the app's call: the request ContextBook builds, the options the engine's switches give
            let request = handMadeRequest(step, below: name == "B2+2" ? 2 : 0, memory: name == "M")
            let want = RequestLayout.body(kind: .engine(kind), request: request, options: ContextOptions.from(engine: config.context))
            _ = try await client.translate(request, options: ContextOptions.from(engine: config.context), engine: config)
            let sent = Array(mock.bodies.dropFirst(n))
            #expect(sent.count == 2, "\(name) \(number): two requests reached the mock")
            if sent.count == 2 {
                #expect(sent[0] == sent[1], "\(name) \(number): the bench's body differs from the app's:\n\(String(decoding: sent[0], as: UTF8.self))\n\(String(decoding: sent[1], as: UTF8.self))")
                #expect(sent[1] == want, "\(name) \(number): the body on the wire differs from RequestLayout.body")
                compared += 1
            }
        }
        #expect(compared == 4)
    }
}

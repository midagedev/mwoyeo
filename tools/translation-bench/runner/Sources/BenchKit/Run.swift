import Foundation

// MARK: - records (the files score.py reads)

public struct AttemptRecord: Codable, Sendable, Equatable {
    public var ok: Bool
    public var latencyMs: Int
    public var retries: Int
    public var stateless: Bool
    public var error: String?
    /// The model's text of a failed attempt that got one (a parse error, a count mismatch), so the scorer can tell a
    /// leaked context line from a broken JSON. Absent on an attempt that counted (`RequestRecord.reply` has it) and in
    /// runs made before 2026-10-19.
    public var reply: String?
    enum CodingKeys: String, CodingKey { case ok, error, retries, stateless, reply, latencyMs = "latency_ms" }
}

/// Where the tokens of one request sit. `stable` is the system prompt (rules, notes, learned terms), `history` the context
/// lines, `volatile` the rest of the user message (the items). `lcp` is the prefix shared with the previous request of the
/// sequence, the part a provider's prefix cache can reuse. Estimated tokens, scaled so the three parts add up to the
/// engine's reported prompt tokens when it reports them (`calibration`).
public struct LayoutRecord: Codable, Sendable, Equatable {
    public var stableChars: Int
    public var historyChars: Int
    public var volatileChars: Int
    public var stableTok: Double
    public var historyTok: Double
    public var volatileTok: Double
    public var lcpTok: Double
    public var memoryTok: Double
    public var calibration: Double?
    enum CodingKeys: String, CodingKey {
        case calibration
        case stableChars = "stable_chars", historyChars = "history_chars", volatileChars = "volatile_chars"
        case stableTok = "stable_tok", historyTok = "history_tok", volatileTok = "volatile_tok", lcpTok = "lcp_tok", memoryTok = "memory_tok"
    }

    public static func measure(wire: Wire, prompt: Prompt, previous: Wire?, usage: Usage?) -> LayoutRecord {
        let parts = ([prompt.historyText] + prompt.historyFragments).filter { !$0.isEmpty }
        let history = parts.joined()
        let volatile = parts.reduce(wire.user) { $0.replacingOccurrences(of: $1, with: "") }
        let eS = Tokens.estimate(wire.system), eH = Tokens.estimate(history), eV = Tokens.estimate(volatile)
        var k = 1.0
        var calibrated: Double?
        if let n = usage?.input, usage?.estimated != true, n > 0, eS + eH + eV > 0 {
            k = Double(n) / (eS + eH + eV)
            calibrated = k
        }
        var lcp = 0.0
        if let previous {
            let a = Array((wire.system + "\u{1}" + wire.user).unicodeScalars)
            let b = Array((previous.system + "\u{1}" + previous.user).unicodeScalars)
            var i = 0
            while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
            var scalars = String.UnicodeScalarView()
            scalars.append(contentsOf: a[0..<i])
            lcp = Tokens.estimate(String(scalars)) * k
        }
        return LayoutRecord(stableChars: wire.system.count, historyChars: history.count, volatileChars: volatile.count,
                            stableTok: eS * k, historyTok: eH * k, volatileTok: eV * k, lcpTok: lcp,
                            memoryTok: Tokens.estimate(prompt.memoryText) * k, calibration: calibrated)
    }
}

public struct RequestRecord: Codable, Sendable, Equatable {
    public var n: Int
    public var screen: Int
    public var items: [Int]
    public var context: [Int]
    public var attempts: [AttemptRecord]
    public var latencyMs: Int
    public var reply: String
    public var usage: Usage?
    public var layout: LayoutRecord
    /// Lines the stateless retry translated, and lines no attempt translated.
    public var fallback: [Int]
    public var failed: [Int]
    /// Learned terms this request added (source, target).
    public var termsAdded: [[String]]
    enum CodingKeys: String, CodingKey {
        case n, screen, items, context, attempts, reply, usage, layout, fallback, failed
        case latencyMs = "latency_ms", termsAdded = "terms_added"
    }
}

public struct SequenceOutput: Codable, Sendable {
    public var id: String
    public var condition: String
    public var translations: [String: String]
    public var requests: [RequestRecord]
}

public struct RunMeta: Codable, Sendable {
    public var condition: String
    public var layout: String
    public var engine: String
    public var kind: String
    public var model: String
    public var price: String?
    public var jobs: Int
    public var batchSize: Int
    public var sequences: [String]
    public var started: String
    public var seconds: Double
    enum CodingKeys: String, CodingKey { case condition, layout, engine, kind, model, price, jobs, sequences, started, seconds, batchSize = "batch_size" }
}

// MARK: - the replay

public struct RunOptions: Sendable {
    public var spec: ConditionSpec
    public var layout: any ContextLayout
    public var layoutName: String
    public var engine: any BenchEngine
    public var out: URL
    public var jobs = 1
    public var batchSize = 3
    public var progress: @Sendable (String) -> Void = { _ in }

    public init(spec: ConditionSpec, layout: any ContextLayout, layoutName: String, engine: any BenchEngine, out: URL) {
        self.spec = spec
        self.layout = layout
        self.layoutName = layoutName
        self.engine = engine
        self.out = out
    }
}

public enum Runner {
    /// Replays one sequence: batch by batch, the condition's request first; when it fails (HTTP, parse, count) the same
    /// batch once more as today's stateless request (design 6.5: break the chain on trouble; for condition A that is the
    /// same request again), then its lines stay empty.
    public static func replay(_ seq: BenchSequence, memory: Memory, options o: RunOptions) async throws -> SequenceOutput {
        let thread = ThreadState()
        var history: [Turn] = []
        var translations: [Int: String] = [:]
        var records: [RequestRecord] = []
        var previousWire: Wire?
        let plan = Replay.plan(seq, batchSize: o.batchSize)
        for batch in plan {
            let step = Step(sequence: seq, memory: memory, batch: batch, history: history)
            let prompt = try o.layout.build(o.spec, step: step, thread: thread)
            var attempts: [AttemptRecord] = []
            var reply = await o.engine.translate(EngineRequest(items: batch.items, source: seq.source, target: seq.target,
                                                               prompt: prompt, sequenceID: seq.id))
            attempts.append(AttemptRecord(ok: reply.translations != nil, latencyMs: reply.latencyMs, retries: reply.retries,
                                          stateless: false, error: reply.error,
                                          reply: reply.translations == nil && !reply.text.isEmpty ? reply.text : nil))
            var usedPrompt = prompt
            var stateless = false
            if reply.translations == nil {
                let plain = Prompt()
                let second = await o.engine.translate(EngineRequest(items: batch.items, source: seq.source, target: seq.target,
                                                                    prompt: plain, sequenceID: seq.id))
                attempts.append(AttemptRecord(ok: second.translations != nil, latencyMs: second.latencyMs, retries: second.retries,
                                              stateless: true, error: second.error,
                                              reply: second.translations == nil && !second.text.isEmpty ? second.text : nil))
                // The size and usage of the request that counted: both are paid, the first one's usage is kept in the log line.
                reply = EngineReply(translations: second.translations, text: second.text, usage: merged(reply.usage, second.usage),
                                    latencyMs: second.latencyMs, retries: second.retries, error: second.error, wire: second.wire)
                usedPrompt = plain
                stateless = true
            }
            let ok = reply.translations != nil
            let t = reply.translations ?? []
            let before = thread.learned
            if ok {
                for (item, tr) in zip(batch.items, t) {
                    translations[item.id] = tr
                    history.append(Turn(line: item, translation: tr, trusted: !stateless))
                }
                if !stateless { o.layout.observe(o.spec, step: step, translations: t, replyText: reply.text, thread: thread) }
            }
            let added = thread.learnedOrder.compactMap { src -> [String]? in
                guard before[src] == nil, let l = thread.learned[src] else { return nil }
                return [src, l.dst]
            }
            records.append(RequestRecord(
                n: batch.number, screen: batch.screen, items: batch.items.map(\.id), context: usedPrompt.contextIDs,
                attempts: attempts, latencyMs: attempts.reduce(0) { $0 + $1.latencyMs }, reply: reply.text, usage: reply.usage,
                layout: LayoutRecord.measure(wire: reply.wire, prompt: usedPrompt, previous: previousWire, usage: reply.usage),
                fallback: stateless && ok ? batch.items.map(\.id) : [], failed: ok ? [] : batch.items.map(\.id), termsAdded: added))
            previousWire = reply.wire
            o.progress("\(seq.id) \(batch.number)/\(plan.count) \(attempts.reduce(0) { $0 + $1.latencyMs }) ms\(ok ? "" : " FAILED: " + (reply.error ?? ""))")
        }
        return SequenceOutput(id: seq.id, condition: o.spec.name, translations: Dictionary(uniqueKeysWithValues: translations.map { (String($0.key), $0.value) }),
                              requests: records)
    }

    static func merged(_ a: Usage?, _ b: Usage?) -> Usage? {
        guard let a else { return b }
        guard let b else { return a }
        func sum(_ x: Int?, _ y: Int?) -> Int? { (x == nil && y == nil) ? nil : (x ?? 0) + (y ?? 0) }
        return Usage(input: sum(a.input, b.input), output: sum(a.output, b.output), cached: sum(a.cached, b.cached),
                     cacheWrite: sum(a.cacheWrite, b.cacheWrite), chars: sum(a.chars, b.chars), estimated: a.estimated ?? b.estimated)
    }

    /// All sequences, `jobs` at a time (each sequence is its own thread, so they are independent; latency is comparable
    /// across runs only at the same `jobs`). Writes `<out>/<id>.json` as each finishes and `meta.json` at the end.
    public static func run(_ corpus: [(BenchSequence, Memory)], options o: RunOptions) async throws {
        try FileManager.default.createDirectory(at: o.out, withIntermediateDirectories: true)
        let clock = ContinuousClock()
        let start = clock.now
        let started = ISO8601DateFormatter().string(from: Date())
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            var running = 0
            func launch() {
                guard next < corpus.count else { return }
                let (seq, mem) = corpus[next]
                next += 1
                running += 1
                group.addTask {
                    let out = try await replay(seq, memory: mem, options: o)
                    try enc.encode(out).write(to: o.out.appendingPathComponent("\(seq.id).json"))
                }
            }
            for _ in 0..<max(1, o.jobs) { launch() }
            while running > 0 {
                try await group.next()
                running -= 1
                launch()
            }
        }
        let secs = Double((clock.now - start) / .milliseconds(1)) / 1000
        let meta = RunMeta(condition: o.spec.name, layout: o.layoutName, engine: o.engine.label, kind: o.engine.kindName, model: o.engine.model,
                           price: o.engine.price, jobs: o.jobs, batchSize: o.batchSize, sequences: corpus.map { $0.0.id }, started: started, seconds: secs)
        let pretty = JSONEncoder()
        pretty.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        try pretty.encode(meta).write(to: o.out.appendingPathComponent("meta.json"))
    }
}

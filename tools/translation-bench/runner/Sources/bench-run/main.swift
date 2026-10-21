import BenchKit
import Foundation

// bench-run: replays the translation bench's sequences against an engine under one condition.
//
//   bench-run run --engine engines/<file>.json --condition A --out <dir> [--root <bench dir>] [--seq id,id] [--jobs N]
//                 [--layout reference|t2|tg] [--batch 3] [--apply hint|both|both-names] [--memory-dir <dir>] [--dump-bodies <dir>]
//   bench-run plan [--root <bench dir>] [--seq id,id] [--batch 3]      the batches of each sequence, no engine
//   bench-run render-memory <memory.json> [--sections window,document,entities,terms] [--no-speech]
//   bench-run conditions
//
// Keys come from the environment variable the engine file names (keyEnv), never from a file, and are never printed.

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func out(_ s: String) { print(s) }

final class Arguments {
    var rest: [String]
    init(_ a: [String]) { rest = a }
    func option(_ name: String) -> String? {
        guard let i = rest.firstIndex(of: name), i + 1 < rest.count else { return nil }
        let v = rest[i + 1]
        rest.removeSubrange(i...(i + 1))
        return v
    }
    func flag(_ name: String) -> Bool {
        guard let i = rest.firstIndex(of: name) else { return false }
        rest.remove(at: i)
        return true
    }
}

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
guard !arguments.rest.isEmpty else { fail("usage: bench-run run|plan|render-memory|conditions (see the header of main.swift)") }
let command = arguments.rest.removeFirst()

let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
func defaultRoot() -> URL {
    // <bench>/runner/.build/... or <bench>/runner: walk up to the directory that has sequences/.
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<6 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("sequences").path) { return dir }
        dir.deleteLastPathComponent()
    }
    _ = here
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

switch command {
case "conditions":
    out("A            off: today's request (MwoyeoCore, byte for byte)")
    out("B<n>         the previous n source lines as context          (B2, B4)")
    out("B<n>+<k>     the same plus k lines below the batch on screen")
    out("C<n>         a conversation of up to n lines, drop the older half when full (C16)")
    out("M[<n>]       B2 (or B<n>) + the user memory (entities, document, window, terms)")
    out("W[<n>]       B2 (or B<n>) + window metadata only")
    out("L[<n>]       B2 (or B<n>) + a learned memory built from earlier replies only")
    out("layouts: reference (the bench's own prompt layout), t2 (the product's RequestLayout; B, B+k and M only),")
    out("         tg (TranslateGemma's own prompt format: one user message, a reply of one translation per line)")

case "plan":
    let root = arguments.option("--root").map { URL(fileURLWithPath: $0) } ?? defaultRoot()
    let only = arguments.option("--seq").map { Set($0.split(separator: ",").map(String.init)) }
    let size = Int(arguments.option("--batch") ?? "3") ?? 3
    var total = 0
    for (seq, _) in try Corpus.load(root: root, only: only) {
        let plan = Replay.plan(seq, batchSize: size)
        total += plan.count
        out("\(seq.id): \(seq.lines.count) lines, \(plan.count) requests: " + plan.map { "[" + $0.items.map { String($0.id) }.joined(separator: ",") + "]" }.joined())
    }
    out("total requests \(total)")

case "render-memory":
    guard let path = arguments.rest.first else { fail("render-memory <memory.json>") }
    arguments.rest.removeFirst()
    let sections = arguments.option("--sections").map { Set($0.split(separator: ",").compactMap { Memory.Section(rawValue: String($0)) }) } ?? Set(Memory.Section.allCases)
    let mem = try Corpus.loadMemory(URL(fileURLWithPath: path))
    out(mem.render(sections: sections, speech: !arguments.flag("--no-speech")))

case "run":
    let root = arguments.option("--root").map { URL(fileURLWithPath: $0) } ?? defaultRoot()
    guard let enginePath = arguments.option("--engine"), let conditionName = arguments.option("--condition"), let outPath = arguments.option("--out") else {
        fail("run needs --engine <file> --condition <name> --out <dir>")
    }
    let only = arguments.option("--seq").map { Set($0.split(separator: ",").map(String.init)) }
    let jobs = Int(arguments.option("--jobs") ?? "1") ?? 1
    let batch = Int(arguments.option("--batch") ?? "3") ?? 3
    let layoutName = arguments.option("--layout") ?? "reference"
    let memoryDir = arguments.option("--memory-dir")
    let dumpBodies = arguments.option("--dump-bodies").map { URL(fileURLWithPath: $0) }
    let applyName = arguments.option("--apply")
    guard let apply = ApplyMode(rawValue: applyName ?? "hint") else { fail("unknown --apply \(applyName ?? ""); use hint, both or both-names") }
    guard let spec = ConditionSpec.parse(conditionName) else { fail("unknown condition \(conditionName); see `bench-run conditions`") }
    let engineFile: EngineFile
    let engine: any BenchEngine
    do {
        engineFile = try EngineFile.load(URL(fileURLWithPath: enginePath))
        engine = try EngineFactory.make(engineFile)
    } catch { fail("engine: \(error)") }
    let layout: any ContextLayout
    switch layoutName {
    case "reference": layout = ReferenceLayout()
    case "t2":
        guard let kind = engineFile.layoutKind else { fail("layout t2 does not cover engine kind \(engineFile.kind)", code: 3) }
        layout = T2Layout(kind: kind, apply: apply)
    case "tg": layout = TranslateGemmaLayout()
    default: fail("unknown layout \(layoutName)")
    }
    if let problem = engine.preflight() { fail("engine \(engine.label) cannot run: \(problem)", code: 3) }
    if layoutName == "tg" && engine.kindName != "openAICompatible" { fail("layout tg needs an openAICompatible engine", code: 3) }
    // A mode that writes into the source is the product layout's: another layout would silently run as `hint`.
    if apply.rewrites && (layoutName != "t2" || !spec.memory) { fail("--apply \(apply.rawValue) needs --layout t2 and a condition with the memory (M)", code: 3) }
    if let memoryDir, !FileManager.default.fileExists(atPath: root.appendingPathComponent(memoryDir).path) {
        fail("--memory-dir \(memoryDir): no such directory under \(root.path)", code: 3)
    }
    let corpus = try Corpus.load(root: root, only: only, memoryDir: memoryDir ?? "memory")
    if corpus.isEmpty { fail("no sequences under \(root.path)") }
    var options = RunOptions(spec: spec, layout: layout, layoutName: layoutName, engine: engine, out: URL(fileURLWithPath: outPath))
    options.jobs = jobs
    options.batchSize = batch
    options.apply = apply
    options.memoryDir = memoryDir
    options.dumpBodies = dumpBodies
    options.progress = { line in FileHandle.standardError.write(Data((line + "\n").utf8)) }
    do { try await Runner.run(corpus, options: options) } catch { fail("run failed: \(error)", code: 4) }
    out("wrote \(corpus.count) sequences to \(outPath)")

default:
    fail("unknown command \(command)")
}

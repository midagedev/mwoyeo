// fast117: does the low-latency model, run beside high fidelity, slow high fidelity's batch? One process, both models warmed, then rounds of four arms in
// rotation, each arm a batch of three lines that no earlier batch had (the system may keep answers):
//   alone      high fidelity only (today)
//   together   low latency and high fidelity started at once (the first paint, `.parallel`)
//   quickfirst low latency, and when it has answered, high fidelity (`.sequential`)
//   after      low latency answers a batch, then 1 s later high fidelity answers another (the model was used, not the request)
// usage: penalty <rounds>      prints one line per batch: round arm hf_ms ll_ms   (ll_ms: when the low-latency answer was complete; -1 for none)
import Foundation
import Translation

func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b - a) / 1e6 }
let rounds = Int(CommandLine.arguments.dropFirst().first ?? "6") ?? 6
let ko = Locale.Language(identifier: "ko"), en = Locale.Language(identifier: "en")
guard #available(macOS 26.4, *) else { print("needs macOS 26.4"); exit(2) }
let hf = TranslationSession(installedSource: en, target: ko, preferredStrategy: .highFidelity)
let ll = TranslationSession(installedSource: en, target: ko, preferredStrategy: .lowLatency)
_ = try? await hf.translate("Hello.")
_ = try? await ll.translate("Hello.")

let subjects = ["The scheduler", "A reader", "The overlay", "Each lens", "The cache", "A translation", "The queue", "This page", "The engine", "A paragraph", "The frame", "Every block"]
let verbs = ["keeps", "drops", "waits for", "paints", "replaces", "measures", "ignores", "reads", "hides", "retries", "splits", "joins"]
let objects = ["the first line of text", "a long paragraph in the left column", "the numbers in the table", "its own copy of the page", "a heading and the note under it",
               "what the person asked for", "the words that did not fit", "the text it has already seen", "a short caption", "the lines around the text", "a reply to the message", "the last sentence"]
var counter = 0
func batch() -> [String] {
    (0..<3).map { _ in
        counter += 1
        return "\(subjects[counter % subjects.count]) \(verbs[(counter / 3) % verbs.count]) \(objects[(counter / 5 + counter) % objects.count]) when it is asked at step \(counter) of the run."
    }
}
func run(_ s: TranslationSession, _ lines: [String]) async -> UInt64 {
    let reqs = lines.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
    do { for try await _ in s.translate(batch: reqs) {} } catch { FileHandle.standardError.write("ERR \(error)\n".data(using: .utf8)!) }
    return now()
}
for round in 1...rounds {
    for arm in ["alone", "together", "quickfirst", "after"].rotated(by: round) {
        let lines = batch()
        let t0 = now()
        var llEnd: UInt64 = 0, hfEnd: UInt64 = 0
        switch arm {
        case "alone": hfEnd = await run(hf, lines)
        case "together":
            async let a = run(ll, lines), b = run(hf, lines)
            (llEnd, hfEnd) = await (a, b)
        case "quickfirst":
            llEnd = await run(ll, lines)
            hfEnd = await run(hf, lines)
        default:
            _ = await run(ll, batch())
            try? await Task.sleep(for: .seconds(1))
            let t1 = now()
            hfEnd = await run(hf, lines)
            print(String(format: "%d %@ %.0f -1", round, arm, ms(t1, hfEnd))); continue
        }
        // quickfirst: hf is measured from the end of ll (what the final model took), not from the start of the batch
        let hfStart = arm == "quickfirst" ? llEnd : t0
        print(String(format: "%d %@ %.0f %.0f", round, arm, ms(hfStart, hfEnd), llEnd == 0 ? -1 : ms(t0, llEnd)))
    }
}
extension Array { func rotated(by n: Int) -> [Element] { isEmpty ? self : Array(self[(n % count)...] + self[..<(n % count)]) } }

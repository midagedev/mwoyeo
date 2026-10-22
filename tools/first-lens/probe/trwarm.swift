// first117: does warming the ja->ko session help the first en->ko batch of a lens? One fresh process per run (the app's own sessions:
// TranslationService.makeSession). usage: trwarm <ja-first|en-first|none> <hf|ll>. Prints: warm_ms batch_ms
import Foundation
import Translation
func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
let a = CommandLine.arguments
let mode = a[1], hf = a[2] == "hf"
let ko = Locale.Language(identifier: "ko"), en = Locale.Language(identifier: "en"), ja = Locale.Language(identifier: "ja")
func make(_ s: Locale.Language) -> TranslationSession { TranslationSession(installedSource: s, target: ko, preferredStrategy: hf ? .highFidelity : .lowLatency) }
let lines = ["is a keep when the mathematics of the LaTeX file or the typewriter fonts of the PDF say so.",
             "A word that the source does not mark but that a reader would still keep as written gets the label translate.",
             "We have not measured how often this happens, so the precision in Table 5 is to be read with that in mind."]
var warm = 0.0
let s = make(en)
if mode != "none" {
    let t = now()
    _ = try? await (mode == "ja-first" ? make(ja) : s).translate(mode == "ja-first" ? "。" : "Hello.")
    warm = Double(now() - t) / 1e6
}
let t = now()
let reqs = lines.enumerated().map { TranslationSession.Request(sourceText: $1, clientIdentifier: String($0)) }
var n = 0
do { for try await _ in s.translate(batch: reqs) { n += 1 } } catch { print("ERR \(error)") }
print(String(format: "%.0f %.0f n=%d", warm, Double(now() - t) / 1e6, n))

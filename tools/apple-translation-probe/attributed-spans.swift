import Foundation
import Translation
// Does skipsTranslation keep spans, and do the span attributes (skip + a link marker) come back on the target text?
let session = TranslationSession(installedSource: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "ko"),
                                 preferredStrategy: CommandLine.arguments.count > 1 ? .highFidelity : .lowLatency)
let cases: [(String, [String])] = [
  ("We compute the dot products of the query with all keys, divide each by √dk, and apply a softmax function.", ["√dk"]),
  ("The input consists of queries and keys of dimension dk, and values of dimension dv.", ["dk", "dv"]),
  ("Where the projections are parameter matrices W_i^Q ∈ R^{dmodel×dk} and W^O ∈ R^{hdv×dmodel}.", ["W_i^Q ∈ R^{dmodel×dk}", "W^O ∈ R^{hdv×dmodel}"]),
  ("In this work we employ h = 8 parallel attention layers, or heads.", ["h = 8"]),
  ("Then their dot product, q · k, has mean 0 and variance dk.", ["q · k", "dk"]),
  ("Each layer has two sub-layers, and the output is LayerNorm(x + Sublayer(x)).", ["LayerNorm(x + Sublayer(x))"]),
]
for (text, spans) in cases {
  var a = AttributedString(text)
  for (n, s) in spans.enumerated() {
    guard let r = a.range(of: s) else { print("no span", s); continue }
    a[r].translation.skipsTranslation = true
    a[r].link = URL(string: "math:\(n + 1)")
  }
  do {
    let resp = try await session.translate(a)
    print("SRC", text)
    print("TGT", resp.targetText)
    if let t = resp.attributedTargetText {
      for run in t.runs {
        let s = String(t[run.range].characters)
        let skip = run.translation.skipsTranslation.map { "skip=\($0)" } ?? ""
        let link = run.link.map { "link=\($0)" } ?? ""
        if !skip.isEmpty || !link.isEmpty { print("  RUN [\(s)] \(skip) \(link)") }
      }
    } else { print("  (no attributedTargetText)") }
  } catch { print("ERR", error) }
}

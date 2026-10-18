import Foundation
import Translation
let strat: TranslationSession.Strategy = CommandLine.arguments[1] == "hf" ? .highFidelity : .lowLatency
func mk(_ l: String) -> TranslationSession { TranslationSession(installedSource: Locale.Language(identifier: l), target: Locale.Language(identifier: "ko"), preferredStrategy: strat) }
func tr(_ s: TranslationSession, _ t: String) async -> (String, Int) {
  let t0 = Date(); let r = (try? await s.translate(t))?.targetText.replacingOccurrences(of: "\n", with: "⏎") ?? "ERR"
  return (r, Int(Date().timeIntervalSince(t0)*1000))
}
let en = mk("en"), ja = mk("ja")
// noise floor: same line twice
for l in ["Said he was sick.","Wants to visit next week.","Fixes the crash on startup.","Asked everyone to sit down.","Hits hard for mages."] {
  let a = await tr(en,l), b = await tr(en,l); print("NOISE", a.0 == b.0 ? "same" : "DIFF", a.0, "|", b.0)
}
let wrapped: [(TranslationSession, [String])] = [
 (en, ["The model is trained on a large","corpus of text and then fine-tuned","for a specific downstream task."]),
 (en, ["Click the button in the upper right","corner of the window to open the","settings panel."]),
 (en, ["If you do not want to receive these","emails, you can unsubscribe at any time."]),
 (ja, ["この機能を使用するには、事前に","アカウントの登録が必要です。"]),
 (ja, ["サーバーのメンテナンスのため、明日の","午前二時から午前五時まで、サービスを","一時停止いたします。"]),
]
for (s, lines) in wrapped {
  var per = [String](); var pm = 0
  for l in lines { let r = await tr(s,l); per.append(r.0); pm += r.1 }
  let j = await tr(s, lines.joined(separator: lines[0].first!.isASCII ? " " : ""))
  let nl = await tr(s, lines.joined(separator: "\n"))
  print("S1 src:", lines.joined(separator: " / "))
  print("   per-line (\(pm)ms):", per.joined(separator: " / "))
  print("   joined   (\(j.1)ms):", j.0)
  print("   newline  (\(nl.1)ms):", nl.0)
}
for (raw, fix) in [("We use trans-\nlation models to eval-\nuate the quality of the output.","We use translation models to evaluate the quality of the output."),
                   ("The atten-\ntion mechanism allows the net-\nwork to focus on rele-\nvant tokens.","The attention mechanism allows the network to focus on relevant tokens."),
                   ("Pre-\ntrained models are widely used.","Pretrained models are widely used."),
                   ("The self-\nattention layer is shown below.","The self-attention layer is shown below.")] {
  let a = await tr(en, raw), b = await tr(en, raw.replacingOccurrences(of: "\n", with: " ")), c = await tr(en, fix)
  print("S2 raw:", a.0); print("   hyphen+space:", b.0); print("   repaired:", c.0)
}
let para = ["The attention mechanism computes a weighted sum of the values.","The weights come from a softmax over the scaled dot products.","This lets each position attend to every other position.","Multiple heads run in parallel and their outputs are concatenated.","The result is projected back to the model dimension.","Residual connections and layer normalization follow each sub-layer."]
var tot = 0; var parts = [String]()
for p in para { let r = await tr(en,p); tot += r.1; parts.append(r.0) }
let whole = await tr(en, para.joined(separator: " "))
print("S4 per-sentence (\(tot)ms):", parts.joined(separator: " "))
print("   whole       (\(whole.1)ms):", whole.0)
// batch vs sequential
let t0 = Date(); let rs = try? await en.translations(from: para.map { .init(sourceText: $0) }); print("   batch ms:", Int(Date().timeIntervalSince(t0)*1000), rs?.count ?? -1)

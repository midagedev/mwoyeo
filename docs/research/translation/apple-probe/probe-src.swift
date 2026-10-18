import Foundation
import Translation
let strat: TranslationSession.Strategy = CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "hf" ? .highFidelity : .lowLatency
let cases: [(String, String, String)] = [
("ja","田中さんは昨日会議に遅れた。","謝りに来た。"),
("ja","新しい上司が来た。","厳しそうな人だ。"),
("ja","母から電話があった。","来週帰ると言っていた。"),
("ja","先生に質問した。","丁寧に答えてくれた。"),
("ja","私はこのゲームを三年やっている。","でもまだクリアできない。"),
("ja","社長が到着しました。","すぐに会議室へお通ししてください。"),
("ja","彼女に告白した。","断られた。"),
("ja","ボスを倒した。","報酬はレアだった。"),
("ja","部長が出張から戻った。","明日お土産を配るそうだ。"),
("ja","弟がゲームを買った。","まだ開けていない。"),
("zh","老板昨天来了。","说要开会。"),
("zh","我买了一台新电脑。","速度很快。"),
("zh","妈妈打电话来了。","问你什么时候回家。"),
("zh","老师讲了新课。","讲得很清楚。"),
("zh","他输了比赛。","很难过。"),
("zh","这个手机很贵。","但是质量很好。"),
("zh","我们到了机场。","航班已经取消了。"),
("zh","小王辞职了。","听说要去美国。"),
("zh","客服回复了。","请稍等。"),
("zh","我养了一只猫。","它很可爱。"),
("en","Tom missed the meeting.","Said he was sick."),
("en","My sister called yesterday.","Wants to visit next week."),
("en","The new update is out.","Fixes the crash on startup."),
("en","I asked the teacher a question.","She answered patiently."),
("en","The boss arrived.","Asked everyone to sit down."),
("en","Is the bar open?","I need a cold drink."),
("en","Where is Mina?","Haven't seen her since lunch."),
("en","The patch notes mention a nerf.","Hits hard for mages."),
("en","The kids are asleep.","Don't wake them."),
("en","I love this song.","Played it all day."),
]
func sessionFor(_ src: String) -> TranslationSession {
  TranslationSession(installedSource: Locale.Language(identifier: src), target: Locale.Language(identifier: "ko"), preferredStrategy: strat)
}
func extract(_ t: AttributedString) -> String? {
  var out = ""
  for run in t.runs where run.link != nil { out += String(t[run.range].characters) }
  return out.isEmpty ? nil : out.trimmingCharacters(in: .whitespacesAndNewlines)
}
func variant(_ s: TranslationSession, prev: String, cur: String, skipPrev: Bool) async -> (String?, String, Double) {
  var a = AttributedString(prev + "\n")
  if skipPrev, let r = a.range(of: prev) { a[r].translation.skipsTranslation = true }
  var c = AttributedString(cur); c.link = URL(string: "ctx:cur")
  a.append(c)
  let t0 = Date()
  do {
    let r = try await s.translate(a)
    let ms = Date().timeIntervalSince(t0) * 1000
    return (r.attributedTargetText.flatMap(extract), r.targetText.replacingOccurrences(of: "\n", with: "⏎"), ms)
  } catch { return (nil, "ERR \(error)", 0) }
}
var sessions: [String: TranslationSession] = [:]
for (i, (lang, prev, cur)) in cases.enumerated() {
  let s = sessions[lang] ?? sessionFor(lang); sessions[lang] = s
  let t0 = Date()
  let a = (try? await s.translate(cur))?.targetText ?? "ERR"
  let aMs = Date().timeIntervalSince(t0) * 1000
  let b = await variant(s, prev: prev, cur: cur, skipPrev: false)
  let c = await variant(s, prev: prev, cur: cur, skipPrev: true)
  print("#\(i) \(lang) | \(prev) / \(cur)")
  print("  A  \(Int(aMs))ms  \(a)")
  print("  B  \(Int(b.2))ms  ext=\(b.0 ?? "NIL")  full=\(b.1)")
  print("  C  \(Int(c.2))ms  ext=\(c.0 ?? "NIL")  full=\(c.1)")
}

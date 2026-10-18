import Foundation
import Translation
// Glossary terms through Apple Translation (en>ko by default), per sentence:
//   old  a plain request, then the glossary replaces the term where it came back untranslated (what the app did before 1.1.2);
//   new  each term marked with a marker (`marker`, the default) or marker + skipsTranslation (`skip`), one `translate(_:)` per
//        sentence because a batch response has no attributedTargetText, the run of each term replaced by the glossary target
//        (`ProtectedSpans.resolve`), its particle fitted to the target (`KoreanParticle`).
// Prints per sentence the old and new text, the engine's raw text and its marked runs, then SUMMARY lines: terms honoured (old,
// new), unresolved spans, particles the engine put after a term in the wrong form for the target (before and after the rule), and
// the time of a plain batch against the attributed requests one after another and at once (two rounds each).
//
// Sets (argument):
//   (none)   the 20 sentences of the 1.1.2 measurement, 12 terms
//   words    40 sentences for 20 terms whose usual Korean rendering ends in a particle-looking syllable (평가 결과 효과 회의 카메라
//            고양이 …), each term once before a particle and once with none after it. Each span is classed against the renderings
//            written down for it below (`gold`): right (the cut is the word), short (cut inside it: 평|가), long (the word and more),
//            other (the engine used a word not in the list, shown for the eye), unresolved.
//   tgt=ja | tgt=zh-Hans   the first 12 sentences with ja / zh-Hans glossary targets: what the marked path does outside Korean.
// Build with -DRENDERINGS once `resolve(renderings:)` exists: the engine's own rendering of each term, asked alone (timed), is
// handed to `resolve`, and a SUMMARY line says how many runs started with it. Without the flag the probe is the pre-fix probe.
// Build with the Core sources it uses, run in a shell with the sandbox off:
//   C=Core/Sources/MwoyeoCore
//   swiftc -O -parse-as-library -enable-bare-slash-regex -DRENDERINGS -o /tmp/glossary-spans tools/apple-translation-probe/glossary-spans.swift \
//     App/Pipeline/ProtectedRequest.swift $C/ProtectedSpans.swift $C/KoreanParticle.swift $C/Text.swift
//   /tmp/glossary-spans [hf] [skip] [words | tgt=ja | tgt=zh-Hans]      (hf: high fidelity, else low latency)
// Outputs (2026-10-18): docs/research/apple-glossary-spans-{lowlatency,highfidelity}-{marker,skip}.txt,
//   apple-glossary-words-{before,after}-{lowlatency,highfidelity}.txt, apple-glossary-{ja,zh}-{before,after}-{lowlatency,highfidelity}.txt
//   (before: built without -DRENDERINGS against the sources of f762194; zh low latency: pack not installed on the machine).
struct CaseSet {
  let glossary: [(String, String)]
  /// kind, sentence
  let cases: [(String, String)]
  /// term (as in the glossary) → the Korean words it is rendered as, written down before the engine was asked
  var gold: [String: [String]] = [:]
}

let koGlossary: [(String, String)] = [
  ("token", "토큰"), ("model", "모델"), ("loss", "손실"), ("layer", "계층"), ("encoder", "인코더"), ("gradient", "그래디언트"),
  ("dataset", "데이터셋"), ("attention head", "어텐션 헤드"), ("Aldric", "알드릭"), ("Eldoria", "엘도리아"),
  ("embedding", "임베딩"), ("softmax", "소프트맥스"),
]
let koCases: [(String, String)] = [
  ("mid+2", "We split the text into tokens before feeding it to the model."),
  ("mid", "The loss drops quickly during the first epoch."),
  ("mid", "Each layer normalizes its input."),
  ("mid", "We freeze the encoder and train only the decoder."),
  ("mid", "Clip the gradient before the update step."),
  ("mid", "The dataset contains ten thousand images."),
  ("mid", "Aldric walked into the hall and greeted the queen."),
  ("mid", "Many travelers have heard of Eldoria."),
  ("initial", "Tokens are mapped to vectors by a lookup table."),
  ("initial", "Loss is computed over the whole batch."),
  ("initial+2", "Model size grows with the number of layers."),
  ("initial", "Aldric said nothing for a long while."),
  ("initial+2", "Embedding vectors are shared between the encoder and the decoder."),
  ("plural", "These layers share the same weights as the encoders."),
  ("plural+2", "All datasets were shuffled, and the gradients were averaged."),
  ("plural+2", "Both models use softmax over the logits."),
  ("two+3", "The model assigns a loss to every token."),
  ("two", "Aldric rode from Eldoria to the northern keep."),
  ("two+3", "After the encoder, each attention head reads the embedding."),
  ("two+3", "We apply softmax to the attention head scores, and the loss follows."),
]

// Targets differ from every rendering the engine is likely to give, so "applied" cannot be a coincidence.
let wordGlossary: [(String, String)] = [
  ("assessment", "검증"), ("result", "산출물"), ("effect", "영향"), ("meeting", "미팅"), ("camera", "캠"), ("cat", "냥이"),
  ("child", "꼬마"), ("expert", "달인"), ("speed", "스피드"), ("temperature", "기온"), ("accuracy", "정밀도"), ("route", "루트"),
  ("country", "지역"), ("definition", "뜻풀이"), ("department", "부문"), ("map", "맵"), ("idea", "발상"), ("writer", "저자"),
  ("apple", "애플"), ("density", "농도"),
]
let wordGold: [String: [String]] = [
  "assessment": ["평가"], "result": ["결과"], "effect": ["효과"], "meeting": ["회의"], "camera": ["카메라"], "cat": ["고양이"],
  "child": ["아이", "어린이"], // 어린이 added after the first low latency run: "child lock" came back as 어린이 and was cut 어린|이
  "expert": ["전문가"], "speed": ["속도"], "temperature": ["온도"], "accuracy": ["정확도", "정확성"], "route": ["경로"],
  "country": ["나라", "국가"], "definition": ["정의"], "department": ["학과", "부서"], "map": ["지도"], "idea": ["아이디어", "생각"],
  "writer": ["작가", "저자"], "apple": ["사과"], "density": ["밀도"],
]
// "P": the term takes a particle in Korean ("평가는"); "B": nothing follows it but a space, a noun or a full stop.
let wordCases: [(String, String)] = [
  ("P", "The assessment was clear and fair."), ("B", "Read the assessment report."),
  ("P", "The result matches our expectation."), ("B", "Save the result table."),
  ("P", "The effect lasts for several hours."), ("B", "We measured the effect size."),
  ("P", "The meeting starts at nine."), ("B", "Open the meeting notes."),
  ("P", "The camera supports night mode."), ("B", "Open the camera app."),
  ("P", "The cat sleeps on the sofa."), ("B", "Visit the cat cafe."),
  ("P", "The child plays in the garden."), ("B", "Turn on the child lock."),
  ("P", "The expert reviewed the draft."), ("B", "Ask the expert panel."),
  ("P", "The speed of the train is constant."), ("B", "Check the speed limit."),
  ("P", "The temperature drops at night."), ("B", "Set the temperature sensor."),
  ("P", "The accuracy improves with more data."), ("B", "Report the accuracy score."),
  ("P", "The route goes along the river."), ("B", "Plan the route map."),
  ("P", "The country joined the union in 1995."), ("B", "Pick the country code."),
  ("P", "The definition is too broad."), ("B", "Update the definition list."),
  ("P", "The department hired three engineers."), ("B", "Open the department page."),
  ("P", "The map shows every trail."), ("B", "Open the map view."),
  ("P", "The idea came from a customer."), ("B", "Pin it to the idea board."),
  ("P", "The writer thanked her editor."), ("B", "Contact the writer team."),
  ("P", "The apple fell from the tree."), ("B", "Bake the apple pie."),
  ("P", "The density increases with pressure."), ("B", "Plot the density curve."),
]

let jaGlossary: [(String, String)] = [
  ("token", "記号"), ("model", "型式"), ("loss", "ロス"), ("layer", "層"), ("encoder", "符号器"), ("gradient", "傾き"),
  ("dataset", "データ集"), ("attention head", "注意ヘッド"), ("Aldric", "アルドリク"), ("Eldoria", "エルドリア"),
  ("embedding", "埋め込み表現"), ("softmax", "ソフト最大"),
]
let zhGlossary: [(String, String)] = [
  ("token", "词元"), ("model", "范式"), ("loss", "损耗"), ("layer", "阶层"), ("encoder", "编码机"), ("gradient", "斜率"),
  ("dataset", "数据组"), ("attention head", "注意头"), ("Aldric", "奥尔德里克"), ("Eldoria", "埃尔多里亚"),
  ("embedding", "嵌入表示"), ("softmax", "软最大"),
]

func glossaryTarget(_ kind: ProtectedSpans.Kind) -> String? {
  #if RENDERINGS
  if case let .glossary(t, _) = kind { return t }
  #else
  if case let .glossary(t) = kind { return t }
  #endif
  return nil
}

func glossaryTerm(_ kind: ProtectedSpans.Kind, in glossary: [(String, String)]) -> String? {
  #if RENDERINGS
  if case let .glossary(_, term) = kind { return term }
  #endif
  return nil
}

func classify(_ was: String, gold: [String]) -> String {
  if gold.contains(was) { return "right" }
  if gold.contains(where: { $0.hasPrefix(was) }) { return "short" }
  if gold.contains(where: { was.hasPrefix($0) }) { return "long" }
  return "other"
}

@main struct Probe {
  static func main() async {
    let args = CommandLine.arguments
    let hf = args.contains("hf")
    let skips = args.contains("skip")
    let tgt = args.first { $0.hasPrefix("tgt=") }.map { String($0.dropFirst(4)) } ?? "ko"
    let set: CaseSet
    if args.contains("words") { set = CaseSet(glossary: wordGlossary, cases: wordCases, gold: wordGold) }
    else if tgt == "ja" { set = CaseSet(glossary: jaGlossary, cases: Array(koCases.prefix(12))) }
    else if tgt == "zh-Hans" { set = CaseSet(glossary: zhGlossary, cases: Array(koCases.prefix(12))) }
    else { set = CaseSet(glossary: koGlossary, cases: koCases) }
    let glossary = set.glossary, cases = set.cases
    let session = TranslationSession(installedSource: Locale.Language(identifier: "en"), target: Locale.Language(identifier: tgt),
                                     preferredStrategy: hf ? .highFidelity : .lowLatency)
    let plans = cases.map { ProtectedSpans(source: $0.1, spans: ProtectedSpans.glossarySpans(in: $0.1, pairs: glossary)) }
    func timed(_ body: () async -> [Int: TranslationSession.Response]) async -> ([Int: TranslationSession.Response], Double) {
      let t0 = Date()
      let out = await body()
      return (out, Date().timeIntervalSince(t0))
    }
    // A batch response carries no attributedTargetText (measured), so a marked source goes as a single `translate(_:)`.
    let plain = cases.enumerated().map { (i, c) in TranslationSession.Request(sourceText: c.1, clientIdentifier: String(i)) }
    func batch() async -> [Int: TranslationSession.Response] {
      var out: [Int: TranslationSession.Response] = [:]
      do { for try await r in session.translate(batch: plain) { if let id = r.clientIdentifier, let i = Int(id) { out[i] = r } } } catch { print("ERR", error) }
      return out
    }
    func singles() async -> [Int: TranslationSession.Response] {
      var out: [Int: TranslationSession.Response] = [:]
      for (i, p) in plans.enumerated() { do { out[i] = try await session.translate(p.attributedSource(skipsGlossary: skips)) } catch { print("ERR", error) } }
      return out
    }
    func concurrent() async -> [Int: TranslationSession.Response] {
      await withTaskGroup(of: (Int, TranslationSession.Response?).self) { group in
        for (i, p) in plans.enumerated() {
          let a = p.attributedSource(skipsGlossary: skips)
          group.addTask { (i, try? await session.translate(a)) }
        }
        var out: [Int: TranslationSession.Response] = [:]
        for await (i, r) in group { if let r { out[i] = r } }
        return out
      }
    }
    _ = try? await session.translate("warm up") // warm up
    var plainTimes: [Double] = [], markedTimes: [Double] = [], concTimes: [Double] = []
    var plainOut: [Int: TranslationSession.Response] = [:], markedOut: [Int: TranslationSession.Response] = [:]
    let full = set.gold.isEmpty && tgt == "ko" // the timing table is the 20-sentence set's: P S C, twice; the others once, P S
    for _ in 0..<(full ? 2 : 1) {
      let (p, tp) = await timed(batch); plainTimes.append(tp); plainOut = p
      let (m, tm) = await timed(singles); markedTimes.append(tm); markedOut = m
      if full { let (_, tc) = await timed(concurrent); concTimes.append(tc) }
    }

    // The engine's own rendering of each term, asked alone: what the cut looks for at the start of a run.
    var renderings: [String: String] = [:]
    var lookupMs: [Double] = []
    #if RENDERINGS
    print("strategy=\(hf ? "highFidelity" : "lowLatency") target=\(tgt) renderings of each term asked alone:")
    for (term, _) in glossary {
      let t0 = Date()
      let answer = try? await session.translate(term).targetText
      let ms = Date().timeIntervalSince(t0) * 1000
      lookupMs.append(ms)
      let usable = answer.flatMap { ProtectedSpans.usableRendering($0, ofTerm: term) }
      if let usable { renderings[term] = usable }
      print("LOOKUP \(term) → \(answer.map { "[\($0)]" } ?? "ERR") usable=\(usable ?? "-") \(String(format: "%.0f", ms)) ms")
    }
    #endif

    var survived = 0, coincided = 0
    var spans = 0, oldOK = 0, newOK = 0, unresolved = 0, checked = 0, wrongBefore = 0, wrongAfter = 0, sentencesOld = 0, sentencesNew = 0
    var classes: [String: Int] = [:], byKind: [String: [String: Int]] = [:], rendered = 0, particleWrongAfterCut = 0
    print("strategy=\(hf ? "highFidelity" : "lowLatency") target=\(tgt) glossary spans \(skips ? "skip translation + marker" : "marker only")")
    for (i, (kind, src)) in cases.enumerated() {
      let p = plans[i]
      // old path: glossary after the fact, only where the source term survived
      let rawPlain = plainOut[i]?.targetText ?? ""
      var old = TranslationCleanup.restoreSourceTokens(rawPlain, source: src)
      for (s, d) in glossary where src.contains(s) { old = old.replacingOccurrences(of: s, with: d) }
      // new path
      var new = markedOut[i]?.targetText ?? ""
      var note = ""
      var classNote = ""
      if let a = markedOut[i]?.attributedTargetText {
        let (text, runs) = ProtectedSpans.answer(a)
        #if RENDERINGS
        let r = p.resolve(target: text, runs: runs, renderings: renderings)
        let raw = p.resolve(target: text, runs: runs, fixParticles: false, renderings: renderings)
        #else
        let r = p.resolve(target: text, runs: runs)
        let raw = p.resolve(target: text, runs: runs, fixParticles: false)
        #endif
        new = r.text
        note += " RUNS=\(runs.map { "\($0.marker):\($0.text)" })\n  RAW \(text)"
        unresolved += r.unresolved.count
        if !r.unresolved.isEmpty { note += " UNRESOLVED=\(r.unresolved.map(\.text))" }
        for x in raw.resolved {
          let chars = Array(raw.text)
          let rest = String(chars[x.range.upperBound...].prefix(12))
          if let ok = KoreanParticle.agrees(rest, with: x.text) { checked += 1; if !ok { wrongBefore += 1; note += " PARTICLE[\(x.text)+\(rest.prefix(2))]" } }
        }
        for x in r.resolved {
          let chars = Array(r.text)
          if let ok = KoreanParticle.agrees(String(chars[x.range.upperBound...].prefix(12)), with: x.text), !ok { wrongAfter += 1 }
        }
        // class of each span against the renderings written down for it (words set), or what was cut (other sets)
        for x in r.resolved {
          let term = glossaryTerm(x.span.kind, in: glossary) ?? glossary.first { $0.1 == glossaryTarget(x.span.kind) }?.0 ?? ""
          let rest = String(Array(r.text)[x.range.upperBound...].prefix(12))
          var c = "cut"
          if let gold = set.gold[term] { c = classify(x.was, gold: gold) }
          classes[c, default: 0] += 1
          byKind[kind, default: [:]][c, default: 0] += 1
          if let ok = KoreanParticle.agrees(rest, with: x.text), !ok, c != "right" { particleWrongAfterCut += 1 }
          if let asked = renderings[term], x.was.filter({ !$0.isWhitespace }) == asked.filter({ !$0.isWhitespace }) { rendered += 1 }
          classNote += " CUT[\(x.was)→\(x.text)|\(c)]"
        }
        for x in r.unresolved { classes["unresolved", default: 0] += 1; byKind[kind, default: [:]]["unresolved", default: 0] += 1; classNote += " UNRESOLVED[\(x.text)]" }
      } else { note += " NO-ATTRIBUTED-ANSWER" }
      let targets = p.spans.compactMap { glossaryTarget($0.kind) }
      // how the old path got there: the term survived (applyGlossary can replace it), the engine chose the target itself, or neither
      for t in targets {
        let term = glossary.first { $0.1 == t }!.0
        if rawPlain.contains(term) { survived += 1 } else if rawPlain.contains(t) { coincided += 1 }
      }
      let o = targets.filter { old.contains($0) }.count, n = targets.filter { new.contains($0) }.count
      spans += targets.count; oldOK += o; newOK += n
      sentencesOld += o == targets.count ? 1 : 0; sentencesNew += n == targets.count ? 1 : 0
      print("[\(i + 1)] \(kind) spans=\(p.spans.map(\.text))")
      print("  SRC \(src)")
      print("  OLD \(old)  (\(o)/\(targets.count))")
      print("  NEW \(new)  (\(n)/\(targets.count))\(note)\n  \(classNote)")
    }
    func ms(_ t: [Double]) -> String { t.map { String(format: "%.2f", $0) }.joined(separator: ",") }
    print("SUMMARY strategy=\(hf ? "hf" : "ll") target=\(tgt) sentences=\(cases.count) spans=\(spans)")
    print("SUMMARY old: glossary target present \(oldOK)/\(spans) (term survived untranslated \(survived), engine chose the target itself \(coincided)), sentences fully honoured \(sentencesOld)/\(cases.count)")
    print("SUMMARY new: glossary target present \(newOK)/\(spans), sentences fully honoured \(sentencesNew)/\(cases.count), unresolved spans \(unresolved)")
    print("SUMMARY particle: engine particles after replaced term \(checked), wrong form before the rule \(wrongBefore), after \(wrongAfter)")
    let order = ["right", "short", "long", "other", "cut", "unresolved"]
    print("SUMMARY classes: " + order.compactMap { c in classes[c].map { "\(c)=\($0)" } }.joined(separator: " ")
          + (set.gold.isEmpty ? "" : "  (garbled = short+long = \((classes["short"] ?? 0) + (classes["long"] ?? 0)), wrong particle after a wrong cut \(particleWrongAfterCut))"))
    for k in byKind.keys.sorted() { print("SUMMARY classes[\(k)]: " + order.compactMap { c in byKind[k]![c].map { "\(c)=\($0)" } }.joined(separator: " ")) }
    #if RENDERINGS
    print("SUMMARY renderings: terms asked \(lookupMs.count), usable \(renderings.count), spans whose cut word is the rendering asked alone \(rendered)/\(spans), lookup ms mean \(String(format: "%.0f", lookupMs.reduce(0, +) / Double(max(1, lookupMs.count)))) max \(String(format: "%.0f", lookupMs.max() ?? 0))")
    #endif
    print("SUMMARY time (s for the \(cases.count) sentences, \(full ? "two rounds" : "one round")): plain batch \(ms(plainTimes)), attributed one after another \(ms(markedTimes))\(full ? ", attributed at once \(ms(concTimes))" : "")")
  }
}

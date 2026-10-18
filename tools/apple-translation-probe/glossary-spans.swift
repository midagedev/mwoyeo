import Foundation
import Translation
// Glossary terms through Apple Translation, en>ko, 20 sentences (mid-sentence, sentence-initial, plural, two or three terms):
//   old  a plain request, then the glossary replaces the term where it came back untranslated (what the app did before 1.1.2);
//   new  each term marked with a marker (`marker`, the default) or marker + skipsTranslation (`skip`), one `translate(_:)` per
//        sentence because a batch response has no attributedTargetText, the run of each term replaced by the glossary target
//        (`ProtectedSpans.resolve`), its particle fitted to the target (`KoreanParticle`).
// Prints per sentence the old and new text, the engine's raw text and its marked runs, then SUMMARY lines: terms honoured (old,
// new), unresolved spans, particles the engine put after a term in the wrong form for the target (before and after the rule), and
// the time of a plain batch against the attributed requests one after another and at once (two rounds each).
// Build with the Core sources it uses, run in a shell with the sandbox off:
//   C=Core/Sources/MwoyeoCore
//   swiftc -O -parse-as-library -enable-bare-slash-regex -o /tmp/glossary-spans tools/apple-translation-probe/glossary-spans.swift \
//     App/Pipeline/ProtectedRequest.swift $C/ProtectedSpans.swift $C/KoreanParticle.swift $C/Text.swift
//   /tmp/glossary-spans [hf] [skip]      (hf: high fidelity, else low latency)
// Outputs: docs/research/apple-glossary-spans-{lowlatency,highfidelity}-{marker,skip}.txt (2026-10-18).
let glossary: [(String, String)] = [
  ("token", "토큰"), ("model", "모델"), ("loss", "손실"), ("layer", "계층"), ("encoder", "인코더"), ("gradient", "그래디언트"),
  ("dataset", "데이터셋"), ("attention head", "어텐션 헤드"), ("Aldric", "알드릭"), ("Eldoria", "엘도리아"),
  ("embedding", "임베딩"), ("softmax", "소프트맥스"),
]
// kind, sentence
let cases: [(String, String)] = [
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

@main struct Probe {
  static func main() async {
    let hf = CommandLine.arguments.contains("hf")
    let skips = CommandLine.arguments.contains("skip")
    let session = TranslationSession(installedSource: Locale.Language(identifier: "en"), target: Locale.Language(identifier: "ko"),
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
    for _ in 0..<2 { // P S C, twice
      let (p, tp) = await timed(batch); plainTimes.append(tp); plainOut = p
      let (m, tm) = await timed(singles); markedTimes.append(tm); markedOut = m
      let (_, tc) = await timed(concurrent); concTimes.append(tc)
    }

    var survived = 0, coincided = 0
    var spans = 0, oldOK = 0, newOK = 0, unresolved = 0, checked = 0, wrongBefore = 0, wrongAfter = 0, sentencesOld = 0, sentencesNew = 0
    print("strategy=\(hf ? "highFidelity" : "lowLatency") glossary spans \(skips ? "skip translation + marker" : "marker only")")
    for (i, (kind, src)) in cases.enumerated() {
      let p = plans[i]
      // old path: glossary after the fact, only where the source term survived
      let rawPlain = plainOut[i]?.targetText ?? ""
      var old = TranslationCleanup.restoreSourceTokens(rawPlain, source: src)
      for (s, d) in glossary where src.contains(s) { old = old.replacingOccurrences(of: s, with: d) }
      // new path
      var new = markedOut[i]?.targetText ?? ""
      var note = ""
      if let a = markedOut[i]?.attributedTargetText {
        let (text, runs) = ProtectedSpans.answer(a)
        let r = p.resolve(target: text, runs: runs)
        let raw = p.resolve(target: text, runs: runs, fixParticles: false)
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
      } else { note += " NO-ATTRIBUTED-ANSWER" }
      let targets = p.spans.compactMap { s -> String? in if case let .glossary(t) = s.kind { t } else { nil } }
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
      print("  NEW \(new)  (\(n)/\(targets.count))\(note)")
    }
    func ms(_ t: [Double]) -> String { t.map { String(format: "%.2f", $0) }.joined(separator: ",") }
    print("SUMMARY strategy=\(hf ? "hf" : "ll") sentences=\(cases.count) spans=\(spans)")
    print("SUMMARY old: glossary target present \(oldOK)/\(spans) (term survived untranslated \(survived), engine chose the target itself \(coincided)), sentences fully honoured \(sentencesOld)/\(cases.count)")
    print("SUMMARY new: glossary target present \(newOK)/\(spans), sentences fully honoured \(sentencesNew)/\(cases.count), unresolved spans \(unresolved)")
    print("SUMMARY particle: engine particles after replaced term \(checked), wrong form before the rule \(wrongBefore), after \(wrongAfter)")
    print("SUMMARY time (s for the 20 sentences, two rounds): plain batch \(ms(plainTimes)), attributed one after another \(ms(markedTimes)), attributed at once \(ms(concTimes))")
  }
}

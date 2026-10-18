import Foundation
import Testing
@testable import MwoyeoCore

/// Spans carried through Apple Translation (macOS 26.4 `skipsTranslation`). The runs of the math tests are what the engine
/// returned in `docs/research/apple-attributed-spans-{highfidelity,lowlatency}.txt` (2026-10-18, en>ko).
@Suite struct ProtectedSpansTests {
    private func math(_ source: String, _ spans: [String]) -> ProtectedSpans {
        let chars = Array(source)
        var found: [(range: Range<Int>, kind: ProtectedSpans.Kind)] = []
        for (n, s) in spans.enumerated() {
            let w = Array(s)
            let at = (0...(chars.count - w.count)).first { Array(chars[$0..<$0 + w.count]) == w }!
            found.append((at..<at + w.count, .math(id: n)))
        }
        return ProtectedSpans(source: source, spans: found)
    }

    private func runs(_ texts: [String]) -> [ProtectedSpans.Run] {
        texts.enumerated().map { ProtectedSpans.Run(marker: $0, text: $1) }
    }

    private func slice(_ s: String, _ r: Range<Int>) -> String { String(Array(s)[r]) }

    // MARK: building

    @Test func spansAreOrderedNumberedAndNeverOverlap() {
        let p = ProtectedSpans(source: "abcdefghij", spans: [
            (6..<9, .math(id: 1)), (0..<3, .glossary(target: "x")), (2..<5, .math(id: 0)), // overlaps the first: dropped
            (4..<4, .math(id: 2)), (8..<20, .math(id: 3)),                                  // empty, out of range: dropped
        ])
        #expect(p.spans.map(\.text) == ["abc", "ghi"])
        #expect(p.spans.map(\.marker) == [0, 1])
        // at one start the longer span wins
        let q = ProtectedSpans(source: "abcdef", spans: [(0..<2, .math(id: 0)), (0..<5, .math(id: 1))])
        #expect(q.spans.map(\.text) == ["abcde"])
        #expect(ProtectedSpans(source: "a  b", spans: [(1..<3, .math(id: 0))]).isEmpty)
    }

    @Test func markerSurvivesAsAnAttributeValue() throws {
        let p = math("a = b", ["a = b"])
        let url = try #require(p.markerURL(p.spans[0]))
        #expect(ProtectedSpans.marker(of: url) == 0)
        #expect(ProtectedSpans.marker(of: URL(string: "https://example.com/7")!) == nil)
    }

    // MARK: glossary terms in a source

    private func terms(_ source: String, _ pairs: [(String, String)]) -> [String] {
        ProtectedSpans(source: source, spans: ProtectedSpans.glossarySpans(in: source, pairs: pairs)).spans.map(\.text)
    }

    @Test func glossaryTermsAreFoundMidSentenceAtTheStartAndInThePlural() {
        let g = [("token", "토큰"), ("model", "모델")]
        #expect(terms("We split the text into token and feed the model.", g) == ["token", "model"])
        #expect(terms("Token ids are looked up first.", g) == ["Token"])
        #expect(terms("Tokens are looked up, and the tokens are fed to models.", g) == ["Tokens", "tokens", "models"])
        #expect(terms("The boxes", [("box", "상자")]) == ["boxes"])
    }

    @Test func aLatinTermIsAWholeWordAndDoesNotSwallowLongerWords() {
        let g = [("token", "토큰")]
        #expect(terms("tokenizing detokenize tokenizer", g).isEmpty)
        #expect(terms("a token-level loss and the token's id", g) == ["token", "token"])
        // a name keeps its case: "Will" is a person, "will" is a verb
        #expect(terms("Will you go? I will.", [("Will", "윌")]) == ["Will"])
    }

    @Test func theLongestTermWinsWhereTwoOverlap() {
        let g = [("network", "네트워크"), ("neural network", "신경망")]
        #expect(terms("A neural network is a network.", g) == ["neural network", "network"])
        let spans = ProtectedSpans.glossarySpans(in: "A neural network", pairs: g)
        #expect(spans.count == 1 && spans[0].kind == .glossary(target: "신경망"))
    }

    @Test func aTermInAScriptWithoutSpacesMatchesWhereverItStands() {
        #expect(terms("今日はタロウさんと行く。タロウは速い。", [("タロウ", "타로")]) == ["タロウ", "タロウ"])
        #expect(terms("a term that is its own translation", [("term", "term")]).isEmpty)
    }

    // MARK: resolving: math spans, from the probe

    @Test func highFidelityRunsAreExactlyTheSpans() {
        let cases: [(String, [String], String)] = [
            ("We compute the dot products of the query with all keys, divide each by √dk, and apply a softmax function.", ["√dk"],
             "우리는 쿼리와 모든 키의 점곱을 계산하고, 각 것을 √dk로 나눈 뒤, 소프트맥스 함수를 적용한다."),
            ("The input consists of queries and keys of dimension dk, and values of dimension dv.", ["dk", "dv"],
             "입력은 dk 차원의 쿼리와 키와 dv 차원의 값으로 구성되어 있습니다."),
            ("Where the projections are parameter matrices W_i^Q ∈ R^{dmodel×dk} and W^O ∈ R^{hdv×dmodel}.",
             ["W_i^Q ∈ R^{dmodel×dk}", "W^O ∈ R^{hdv×dmodel}"], "추론은 매개변수 행렬 W_i^Q ∈ R^{dmodel×dk} 및 W^O ∈ R^{hdv×dmodel}"),
            ("In this work we employ h = 8 parallel attention layers, or heads.", ["h = 8"], "이 작업에서는 h = 8개의 병렬 주의 레이어, 또는 헤드를 사용합니다."),
            ("Then their dot product, q · k, has mean 0 and variance dk.", ["q · k", "dk"], "그러면 그들의 점곱, q · k는 평균이 0이고 분산이 dk."),
            ("Each layer has two sub-layers, and the output is LayerNorm(x + Sublayer(x)).", ["LayerNorm(x + Sublayer(x))"],
             "각 레이어에는 두 개의 하위 레이어가 있으며, 출력은 LayerNorm(x + Sublayer(x))입니다."),
        ]
        for (source, spans, target) in cases {
            let p = math(source, spans)
            let r = p.resolve(target: target, runs: runs(spans))
            #expect(r.unresolved.isEmpty, "\(spans)")
            #expect(r.text == target)
            #expect(r.math.map(\.text) == spans, "\(spans)")
            for m in r.math { #expect(slice(r.text, m.range) == m.text) }
        }
    }

    @Test func lowLatencyRunsCarryTheParticleAfterTheSpan() {
        let cases: [(String, [String], [String], String)] = [
            ("We compute the dot products of the query with all keys, divide each by √dk, and apply a softmax function.", ["√dk"], ["√dk로 "],
             "우리는 모든 키를 사용하여 쿼리의 도트 곱을 계산하고, 각각을 √dk로 나눈 뒤, 소프트맥스 함수를 적용합니다."),
            ("The input consists of queries and keys of dimension dk, and values of dimension dv.", ["dk", "dv"], ["dk의", "dv의"],
             "입력은 차원 dk의 쿼리와 키, 그리고 차원 dv의 값으로 구성됩니다."),
            ("Where the projections are parameter matrices W_i^Q ∈ R^{dmodel×dk} and W^O ∈ R^{hdv×dmodel}.",
             ["W_i^Q ∈ R^{dmodel×dk}", "W^O ∈ R^{hdv×dmodel}"], ["W_i^Q ∈ R^{dmodel×dk} ", "W^O ∈ R^{hdv×dmodel}"],
             "여기서 투영은 파라미터 행렬 W_i^Q ∈ R^{dmodel×dk} 및 W^O ∈ R^{hdv×dmodel}입니다."),
            ("In this work we employ h = 8 parallel attention layers, or heads.", ["h = 8"], ["h = 8개의 "], "본 연구에서는 h = 8개의 평행 주의층, 즉 헤드를 사용합니다."),
            ("Each layer has two sub-layers, and the output is LayerNorm(x + Sublayer(x)).", ["LayerNorm(x + Sublayer(x))"],
             ["LayerNorm(x + Sublayer(x))입니다."], "각 레이어는 두 개의 서브 레이어를 가지고 있으며, 출력은 LayerNorm(x + Sublayer(x))입니다."),
        ]
        for (source, spans, runTexts, target) in cases {
            let r = math(source, spans).resolve(target: target, runs: runs(runTexts))
            #expect(r.unresolved.isEmpty, "\(spans)")
            #expect(r.text == target)
            #expect(r.math.map(\.text) == spans, "\(spans)")
        }
    }

    @Test func aRespacedSpanIsStillTheStartOfItsRun() {
        // lowLatency wrote "q·k" for "q · k"
        let p = math("Then their dot product, q · k, has mean 0 and variance dk.", ["q · k", "dk"])
        let target = "그렇다면 그들의 점곱인 q·k는 평균이 0이고 분산은 dk입니다."
        let r = p.resolve(target: target, runs: runs(["q·k는", "dk입니다"]))
        #expect(r.unresolved.isEmpty)
        #expect(r.math.map(\.text) == ["q·k", "dk"])
        #expect(slice(r.text, r.math[0].range) == "q·k" && slice(r.text, r.math[1].range) == "dk")
    }

    // MARK: resolving: what makes a span unresolved

    @Test func aSpanWithNoRunOrMoreThanOneRunIsUnresolved() {
        let p = math("Set h = 8 and dk = 64.", ["h = 8", "dk = 64"])
        let target = "h = 8과 dk = 64를 정한다."
        let missing = p.resolve(target: target, runs: [ProtectedSpans.Run(marker: 0, text: "h = 8과")])
        #expect(missing.unresolved.map(\.text) == ["dk = 64"] && missing.math.map(\.text) == ["h = 8"])
        let twice = p.resolve(target: target, runs: [.init(marker: 0, text: "h = 8과"), .init(marker: 1, text: "dk = 64를"), .init(marker: 0, text: "h = 8")])
        #expect(twice.unresolved.map(\.text) == ["h = 8"] && twice.math.map(\.text) == ["dk = 64"])
        #expect(p.resolve(target: target, runs: []).unresolved.count == 2)
        // a marker the source never had is ignored
        #expect(p.resolve(target: target, runs: [.init(marker: 9, text: "h = 8")]).unresolved.count == 2)
    }

    @Test func aRunThatDoesNotStartWithTheSpanOrIsNotInTheTargetIsUnresolved() {
        let p = math("The output is Dk here.", ["Dk"])
        // the engine rewrote the span
        #expect(p.resolve(target: "출력은 디케이입니다.", runs: runs(["디케이입니다"])).unresolved.count == 1)
        // text that is not the start of the run
        #expect(p.resolve(target: "출력은 Dk입니다.", runs: runs(["값은 Dk"])).unresolved.count == 1)
        // a run the target does not hold
        #expect(p.resolve(target: "출력은 Dk입니다.", runs: runs(["Dk를"])).unresolved.count == 1)
    }

    @Test func twoRunsWithTheSameTextAreTwoPlaces() {
        // the same text twice in one source: both marked, found in order
        let two = ProtectedSpans(source: "Both dk and dk are set.", spans: [(5..<7, .math(id: 0)), (12..<14, .math(id: 1))])
        let r = two.resolve(target: "dk 와 dk 가 정해진다.", runs: runs(["dk", "dk"]))
        #expect(r.unresolved.isEmpty)
        #expect(r.math.map(\.range) == [0..<2, 5..<7])
    }

    // MARK: resolving: glossary targets

    private func glossary(_ source: String, _ pairs: [(String, String)]) -> ProtectedSpans {
        ProtectedSpans(source: source, spans: ProtectedSpans.glossarySpans(in: source, pairs: pairs))
    }

    @Test func aGlossaryTargetTakesTheSpansPlaceAndKeepsWhatFollows() {
        let p = glossary("We feed the tokens into the model.", [("token", "토큰"), ("model", "모델")])
        // lowLatency: the particle sits in the run
        let ll = p.resolve(target: "우리는 tokens를 model에 입력합니다.", runs: runs(["tokens를 ", "model에"]))
        #expect(ll.unresolved.isEmpty)
        #expect(ll.text == "우리는 토큰을 모델에 입력합니다.")
        // highFidelity: the run is the span, the particle follows it
        let hf = p.resolve(target: "우리는 tokens를 model에 입력한다.", runs: runs(["tokens", "model"]))
        #expect(hf.text == "우리는 토큰을 모델에 입력한다.")
        #expect(hf.resolved.map(\.text) == ["토큰", "모델"])
        for x in hf.resolved { #expect(slice(hf.text, x.range) == x.text) }
    }

    @Test func theParticleFollowsTheTargetsLastSound() {
        let g = [("loss", "손실"), ("encoder", "인코더"), ("model", "모델")]
        let cases: [(String, String, [String], String)] = [
            ("The loss falls.", "loss는 떨어진다.", ["loss"], "손실은 떨어진다."),          // ㄹ-final target, engine heard "로스"
            ("The encoder falls.", "encoder은 떨어진다.", ["encoder"], "인코더는 떨어진다."), // vowel-final target
            ("Use the model.", "model으로 사용한다.", ["model"], "모델로 사용한다."),        // ㄹ takes 로, not 으로
            ("Use the loss.", "loss로 사용한다.", ["loss"], "손실로 사용한다."),             // ㄹ again
            ("The encoder is.", "encoder이다.", ["encoder"], "인코더이다."),              // 이다 does not change
        ]
        for (source, target, runTexts, want) in cases {
            let r = glossary(source, g).resolve(target: target, runs: runs(runTexts))
            #expect(r.text == want, "\(target)")
        }
    }

    @Test func mathAfterAGlossaryTermIsPlacedInTheFinalText() {
        let source = "The loss is set by h = 8."
        let p = ProtectedSpans(source: source, spans: [(4..<8, .glossary(target: "손실")), (19..<24, .math(id: 0))])
        let r = p.resolve(target: "loss는 h = 8로 정해진다.", runs: runs(["loss는", "h = 8로"]))
        #expect(r.text == "손실은 h = 8로 정해진다.")
        #expect(r.math.count == 1 && slice(r.text, r.math[0].range) == "h = 8")
    }

    // What the engines wrote for glossary terms marked without `skipsTranslation` (tools/apple-translation-probe/glossary-spans.swift,
    // docs/research/apple-glossary-spans-*.txt, 2026-10-18, en>ko): the run is the engine's rendering plus its particle.
    @Test func theRunOfAGlossaryTermIsTheEnginesRenderingAndItsParticle() {
        let g = [("layer", "계층"), ("dataset", "데이터셋"), ("Aldric", "알드릭"), ("token", "토큰"), ("model", "모델")]
        // (source, engine's target, its marked runs as (marker, text) in target order, wanted)
        let cases: [(String, String, [(Int, String)], String)] = [
            // lowLatency
            ("Each layer normalizes its input.", "각 레이어는 입력을 정규화합니다.", [(0, "레이어는")], "각 계층은 입력을 정규화합니다."),
            ("The dataset contains ten thousand images.", "데이터 세트에는 만 개의 이미지가 포함되어 있습니다.", [(0, "데이터 세트에는")],
             "데이터셋에는 만 개의 이미지가 포함되어 있습니다."),
            ("Aldric rode to the northern keep.", "알드리크는 북쪽 성으로 말을 탔습니다.", [(0, "알드리크는")], "알드릭은 북쪽 성으로 말을 탔습니다."),
            ("Model size grows with the number of layers.", "모델 크기는 레이어 수에 따라 증가합니다.", [(0, "모델 "), (1, "레이어 ")], "모델 크기는 계층 수에 따라 증가합니다."),
            ("These layers share the weights.", "이 레이어들은 가중치를 공유합니다.", [(0, "레이어들은")], "이 계층들은 가중치를 공유합니다."),
            // the engine kept the name
            ("Aldric said nothing.", "Aldric은 아무 말도 하지 않았습니다.", [(0, "Aldric은")], "알드릭은 아무 말도 하지 않았습니다."),
            // highFidelity: runs come in target order, not the source's
            ("We split the text into tokens before feeding it to the model.", "우리는 모델에 입력하기 전에 텍스트를 토큰으로 분할합니다.",
             [(1, "모델에"), (0, "토큰으로")], "우리는 모델에 입력하기 전에 텍스트를 토큰으로 분할합니다."),
            ("These layers share the weights.", "이러한 층들은 가중치를 공유합니다.", [(0, "층들은 ")], "이러한 계층들은 가중치를 공유합니다."),
        ]
        for (source, target, marked, want) in cases {
            let r = glossary(source, g).resolve(target: target, runs: marked.map { .init(marker: $0.0, text: $0.1) })
            #expect(r.text == want, "\(source)")
            #expect(r.unresolved.isEmpty, "\(source)")
        }
        // what the engine had written is kept for whoever draws over it
        let one = glossary("Each layer normalizes its input.", g).resolve(target: "각 레이어는 입력을 정규화합니다.", runs: runs(["레이어는"]))
        #expect(one.resolved.map(\.was) == ["레이어"] && one.resolved.map(\.text) == ["계층"])
    }

    @Test func aRunWithOnlyOneWordOfTheTargetIsLeftAlone() {
        // lowLatency put "어텐션" outside the run of "attention head": replacing "헤드" would say it twice
        let p = glossary("We apply softmax to the attention head scores.", [("attention head", "어텐션 헤드")])
        let target = "우리는 어텐션 헤드 점수에 소프트맥스를 적용합니다."
        let r = p.resolve(target: target, runs: runs([" 헤드 "]))
        #expect(r.text == target && r.unresolved.map(\.text) == ["attention head"])
        // a word that only contains a piece of the target is a word of its own: 층 for 계층
        let q = glossary("These layers share weights.", [("layer", "계층")])
        #expect(q.resolve(target: "이러한 층들은 가중치를 공유합니다.", runs: runs(["층들은 "])).text == "이러한 계층들은 가중치를 공유합니다.")
    }

    @Test func onlyKoreanRunsAreCutAtTheirParticle() {
        // a Japanese run "トークンを" would lose its を: the term stays as the engine wrote it
        let p = glossary("We split the text into tokens.", [("token", "トークン")])
        let r = p.resolve(target: "テキストを記号を分割します。", runs: runs(["記号を"]))
        #expect(r.text == "テキストを記号を分割します。" && r.unresolved.count == 1)
        // a kept term is replaced whatever the language
        let q = glossary("Aldric left.", [("Aldric", "アルドリック")])
        #expect(q.resolve(target: "Aldricは去った。", runs: runs(["Aldricは"])).text == "アルドリックは去った。")
        // a Korean target over a run the engine left in another script
        #expect(glossary("We split the text into tokens.", [("token", "토큰")]).resolve(target: "テキストを記号に分割します。", runs: runs(["記号に"])).unresolved.count == 1)
    }

    @Test func aRunWithNoWordOrNoRunLeavesTheTermUnresolved() {
        let p = glossary("The encoder reads.", [("encoder", "인코더")])
        #expect(p.resolve(target: "인코더가 읽는다.", runs: runs([" "])).unresolved.count == 1)
        #expect(p.resolve(target: "인코더가 읽는다.", runs: []).unresolved.count == 1)
    }

    @Test func anUnresolvedGlossaryTermLeavesTheTargetAsItCame() {
        let p = glossary("We feed the tokens.", [("token", "토큰")])
        let r = p.resolve(target: "우리는 토큰을 먹입니다.", runs: [])
        #expect(r.text == "우리는 토큰을 먹입니다." && r.unresolved.map(\.text) == ["tokens"])
    }
}

@Suite struct KoreanParticleTests {
    @Test func finalConsonantIsReadFromTheLastSyllable() {
        #expect(KoreanParticle.finalConsonant(of: "토큰") == 4)  // ㄴ
        #expect(KoreanParticle.finalConsonant(of: "모델") == 8)  // ㄹ
        #expect(KoreanParticle.finalConsonant(of: "인코더") == 0)
        #expect(KoreanParticle.finalConsonant(of: "GPU") == nil)
        #expect(KoreanParticle.finalConsonant(of: "") == nil)
    }

    @Test func aParticleTakesTheFormTheWordAsks() {
        let cases: [(String, String, String)] = [
            ("토큰", "를 쓴다", "을 쓴다"), ("인코더", "을 쓴다", "를 쓴다"),
            ("토큰", "는 크다", "은 크다"), ("인코더", "은 크다", "는 크다"),
            ("계층", "가 있다", "이 있다"), ("손실", "가 있다", "이 있다"), ("인코더", "이 있다", "가 있다"),
            ("토큰", "와 모델", "과 모델"), ("인코더", "과 모델", "와 모델"),
            ("토큰", "로 나눈다", "으로 나눈다"), ("인코더", "으로 나눈다", "로 나눈다"), ("모델", "으로 나눈다", "로 나눈다"), ("모델", "로 나눈다", "로 나눈다"),
            ("토큰", "나 모델", "이나 모델"), ("인코더", "이나 모델", "나 모델"),
            ("토큰", "라고 한다", "이라고 한다"), ("인코더", "이라고 한다", "라고 한다"),
            ("인코더", "이에요", "예요"), ("토큰", "예요", "이에요"),
            ("토큰", "로서 쓴다", "으로서 쓴다"), ("토큰", "가도 된다", "이도 된다"),
        ]
        for (word, rest, want) in cases {
            #expect(KoreanParticle.agree(rest, with: word) == want, "\(word)+\(rest)")
        }
    }

    @Test func nothingChangesWhenTheFormIsRightOrNoParticleIsThere() {
        for (word, rest) in [("토큰", "은 크다"), ("인코더", "는 크다"), ("토큰", "입니다"), ("인코더", "입니다."), ("토큰", " 를 쓴다"), ("토큰", "에서 쓴다"),
                             ("토큰", ""), ("GPU", "를 쓴다"), ("GPU", "가 있다"), ("", "를 쓴다"),
                             // 이다 and its endings, and a word that starts like a particle, are not particles
                             ("인코더", "이다"), ("인코더", "이고 크다"), ("인코더", "이며"), ("토큰", "나눈 뒤"), ("토큰", "가능하다"), ("토큰", "라이브러리")] {
            #expect(KoreanParticle.agree(rest, with: word) == rest, "\(word)+\(rest)")
        }
    }

    @Test func theWordEndsBeforeItsParticleAndPluralAndSpace() {
        // what lowLatency and highFidelity wrote for glossary terms (en>ko, 2026-10-18)
        let cases: [(String, String)] = [
            ("토큰으로", "토큰"), ("모델에 ", "모델"), ("손실은", "손실"), ("레이어는", "레이어"), ("데이터 세트에는", "데이터 세트"), ("엘도리아에서 ", "엘도리아"),
            ("레이어들은", "레이어"), ("층들은 ", "층"), ("모델 ", "모델"), ("임베딩 ", "임베딩"), ("알드릭은", "알드릭"), ("인코더와", "인코더"),
            ("어텐션 헤드가", "어텐션 헤드"), ("소프트맥스를 ", "소프트맥스"), ("토큰.", "토큰"), ("Aldric은", "Aldric"), ("토큰", "토큰"),
        ]
        for (run, word) in cases {
            let end = KoreanParticle.wordEnd(in: run)
            #expect(String(Array(run)[..<end]) == word, "\(run)")
        }
        // never empty: a lone particle-looking syllable is the word
        #expect(KoreanParticle.wordEnd(in: "이") == 1 && KoreanParticle.wordEnd(in: "") == 0)
    }

    @Test func agreesTellsWhetherTheParticleFits() {
        #expect(KoreanParticle.agrees("을 쓴다", with: "토큰") == true)
        #expect(KoreanParticle.agrees("를 쓴다", with: "토큰") == false)
        #expect(KoreanParticle.agrees("으로", with: "모델") == false)
        #expect(KoreanParticle.agrees("에서", with: "모델") == nil)
        #expect(KoreanParticle.agrees("를", with: "GPU") == nil)
    }
}

@Suite struct InlineMathTests {
    private func found(_ s: String) -> [String] {
        let chars = Array(s)
        return InlineMath.spans(in: s).map { String(chars[$0.range]) }
    }

    @Test func theProbeSentencesGiveTheirFormulas() {
        #expect(found("We compute the dot products of the query with all keys, divide each by √dk, and apply a softmax function.") == ["√dk"])
        #expect(found("Where the projections are parameter matrices W_i^Q ∈ R^{dmodel×dk} and W^O ∈ R^{hdv×dmodel}.")
                == ["W_i^Q ∈ R^{dmodel×dk}", "W^O ∈ R^{hdv×dmodel}"])
        #expect(found("In this work we employ h = 8 parallel attention layers, or heads.") == ["h = 8"])
        #expect(found("Then their dot product, q · k, has mean 0 and variance dk.") == ["q · k"])
        #expect(found("Each layer has two sub-layers, and the output is LayerNorm(x + Sublayer(x)).") == ["LayerNorm(x + Sublayer(x))"])
    }

    @Test func spansGetIdsInOrder() {
        let ids = InlineMath.spans(in: "Let x = 1 and y = 2.").map { r -> Int in if case let .math(id) = r.kind { id } else { -1 } }
        #expect(ids == [0, 1])
    }

    @Test func proseAndLookalikesAreNotFormulas() {
        for s in ["We compute the dot products of the query with all keys.", "(where we use h parallel heads)", "(where x = 1)",
                  "see https://example.com/a_b for more", "mail me at a@b.com", "C++ is fast and <3 is love", "It costs 10% less in 2017.",
                  "all tokens(s) are shown", "Section 3.2.1 shows the design, see Figure 2.", "A state-of-the-art x-axis n-gram model",
                  "I am a person - not a bot"] {
            #expect(found(s).isEmpty, "\(s)")
        }
    }

    @Test func aCallNeedsVariablesAsArguments() {
        #expect(found("The result is Attention(Q, K, V) here") == ["Attention(Q, K, V)"])
        #expect(found("a call such as save(file, name) is not math") .isEmpty)
    }
}

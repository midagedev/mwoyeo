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
            (6..<9, .math(id: 1)), (0..<3, .math(id: 4)), (2..<5, .math(id: 0)), // overlaps the first: dropped
            (4..<4, .math(id: 2)), (8..<20, .math(id: 3)),                       // empty, out of range: dropped
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
            #expect(r.resolved.map(\.text) == spans, "\(spans)")
            for m in r.resolved { #expect(slice(target, m.range) == m.text) }
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
            #expect(r.resolved.map(\.text) == spans, "\(spans)")
        }
    }

    @Test func aRespacedSpanIsStillTheStartOfItsRun() {
        // lowLatency wrote "q·k" for "q · k"
        let p = math("Then their dot product, q · k, has mean 0 and variance dk.", ["q · k", "dk"])
        let target = "그렇다면 그들의 점곱인 q·k는 평균이 0이고 분산은 dk입니다."
        let r = p.resolve(target: target, runs: runs(["q·k는", "dk입니다"]))
        #expect(r.unresolved.isEmpty)
        #expect(r.resolved.map(\.text) == ["q·k", "dk"])
        #expect(slice(target, r.resolved[0].range) == "q·k" && slice(target, r.resolved[1].range) == "dk")
    }

    // MARK: resolving: what makes a span unresolved

    @Test func aSpanWithNoRunOrMoreThanOneRunIsUnresolved() {
        let p = math("Set h = 8 and dk = 64.", ["h = 8", "dk = 64"])
        let target = "h = 8과 dk = 64를 정한다."
        let missing = p.resolve(target: target, runs: [ProtectedSpans.Run(marker: 0, text: "h = 8과")])
        #expect(missing.unresolved.map(\.text) == ["dk = 64"] && missing.resolved.map(\.text) == ["h = 8"])
        let twice = p.resolve(target: target, runs: [.init(marker: 0, text: "h = 8과"), .init(marker: 1, text: "dk = 64를"), .init(marker: 0, text: "h = 8")])
        #expect(twice.unresolved.map(\.text) == ["h = 8"] && twice.resolved.map(\.text) == ["dk = 64"])
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
        #expect(r.resolved.map(\.range) == [0..<2, 5..<7])
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

    /// H2 (round k3b, 2026-10-20): a Japanese sentence has no spaces, so "TOKEN_ATに作った時刻を…" was one token and the `_` made it a
    /// formula: one span covered the sentence around the identifier and the engine never saw it (gitdiff-ja md-light, yaml-ja md-dark). A CJK
    /// letter ends a token, and a token of CJK letters is prose, not an operand ("설정 > 일반의" read as a < b).
    @Test func aCJKLetterEndsAnIdentifierAndTheTextAroundItIsProse() {
        #expect(found("トークンの有効期限は15分です。TOKEN_ATに作った時刻を残して、10分たったら作り直します。") == ["TOKEN_AT"])
        #expect(found("バージョンは MARKETING_VERSION】の一か所だけで決めます。") == ["MARKETING_VERSION"])
        #expect(found("파일 위치는 settings.json 이고, 설정 > 일반의 열기 버튼으로 열 수 있어요.").isEmpty)
        #expect(found("行列 W_i^Q ∈ R^{dmodel×dk}は大きい") == ["W_i^Q ∈ R^{dmodel×dk}"])
    }

    @Test func aCallNeedsVariablesAsArguments() {
        #expect(found("The result is Attention(Q, K, V) here") == ["Attention(Q, K, V)"])
        #expect(found("a call such as save(file, name) is not math") .isEmpty)
    }
}

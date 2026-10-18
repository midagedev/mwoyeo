import Foundation
import Testing
@testable import MwoyeoCore

/// Formulas, figure labels and identifiers read off a paper page stay as written (page 4 of arXiv 1706.03762, en>ko,
/// 2026-10-18: "K" became "1천", "E" "음", "SoftMax" "소프트맥스"). One bare letter or one sum sign carries no sentence the engine
/// could translate; it only invents one.
@Suite struct FormulaLiteralTests {
    private func kept(_ t: String) -> Bool {
        TranslationFilter.isLiteral(t) && !TranslationFilter.needsTranslation(t, cjkSource: false)
    }

    // MARK: what page 4 sent to the engine and must not have

    @Test func fragmentsOfPage4StayAsWritten() {
        for t in ["K", "E", "Q", "QKT", "-)V", "/ак", "_inea", "Attention(Q, K,V) = softmax", "MatMul", "SoftMax"] {
            #expect(kept(t), "\(t)")
        }
    }

    @Test func everyBodyLineOfPage4IsStillTranslated() {
        for t in [
            #"Scaled Dot-Product Attention"#,
            #"Multi-Head Attention"#,
            #"Figure 2: (left) Scaled Dot-Product Attention. (right) Multi-Head Attention consists of several attention layers running in parallel."#,
            #"of the values, where the weight assigned to each value is computed by a compatibility function of the query with the corresponding key."#,
            #"3.2.1 Scaled Dot-Product Attention"#,
            #"We call our particular attention "Scaled Dot-Product Attention" (Figure 2). The input consists of queries and keys of dimension dk, and values of dimension do. We compute the dot products of the query with all keys, divide each by Vdk, and apply a softmax function to obtain the weights on the"#,
            #"In practice, we compute the attention function on a set of queries simultaneously, packed together into a matrix Q. The keys and values are also packed together into matrices K and V. We compute the matrix of outputs as:"#,
            #"The two most commonly used attention functions are additive attention [2], and dot-product (multi-plicative) attention. Dot-product attention is identical to our algorithm, except for the scaling factor"#,
            #"of Vd Additive attention computes the compatibility function using a feed-forward network with a single hidden layer. While the two are similar in theoretical complexity, dot-product attention is much faster and more space-efficient in practice, since it can be implemented using highly optimized matrix multiplication code. While for small values of dk the two mechanisms perform similarly, additive attention outperforms dot product attention without scaling for larger values of dk [3]. We suspect that for large values of dk, the dot products grow large in magnitude, pushing the softmax function into regions where it has extremely small gradients 4. To counteract this effect, we scale the dot products by"#,
            #"3.2.2 Multi-Head Attention"#,
            #"Instead of pertormıng a sıngle attention tunction with dmodel-dımensional keys, values and queries, we tound it beneficial to linearly project the queries, keys and values h times with different, learned linear projections to dk, ok and d, dimensions, respectively. On each of these projected versions of queries, keys and values we then perform the attention function in parallel, yielding do-dimensional"#,
            #""To illustrate why the dot products get large, assume that the components of q and k are independent random variables with mean 0 and variance 1. Then their dot product, q • k = ak"#,
            #"i=1 9iki, has mean 0 and variance dk."#,
        ] {
            #expect(!TranslationFilter.isLiteral(t), "\(t.prefix(60))")
        }
    }

    /// A lone plain word cannot be told from a figure label: out of scope, still translated.
    @Test func plainWordsOfFigureLabelsAreOutOfScope() {
        for t in ["Vaki", "Linea", "Scale", "Linear", "Concat", "Softmax", "Mask (opt.)", "Add & Norm", "Positional Encoding"] {
            #expect(!TranslationFilter.isLiteral(t), "\(t)")
        }
    }

    // MARK: the same shapes on the other pages of the paper (read off the page pictures; not OCR output)

    @Test func formulaShapesOfPages3To6StayAsWritten() {
        for t in ["N×", "Nx", "N = 6", "h = 8", "dff = 2048.", "dmodel = 512", "Vd", "Vdk", "9iki", "(x1, ..., xn)", "(a)",
                  "O(1)", "O(n)", "O(n² · d)", "O(log k(n))", "O(n/r)", "FFN(x) = max(0, xW1 + b1)W2 + b2 (2)",
                  "MultiHead(Q, K, V) = Concat(head1, ..., headh)WO", "where headi = Attention(QWQ i , KWK i , VWV i )",
                  "PE(pos,2i) = sin(pos/100002i/dmodel)", "LayerNorm(x + Sublayer(x))", "ReLU", "LayerNorm", "MultiHead",
                  "L = Σi d(li, li+1) + λ |G| (1)", "σ²", "α", "x1 x2"] {
            #expect(kept(t), "\(t)")
        }
    }

    // MARK: text that merely looks short or symbolic is still text

    @Test func chatAndLabelsAreStillTranslated() {
        for t in ["ok", "OK", "no", "lol", "Hi!", "hmm", "Hmm...", "WTF", "BRB", "C# is great", "50% off today", "x2 faster?", "Go to 3D",
                  "Is it OK?", "Q&A", "R&D", "N/A", "A/B test", "Home → Settings", "Name(optional)", "Price(KRW)", "layer(s)", "Mode = Fast",
                  "Total = 5 USD", "HP 120", "HP 482/600", "Lv 5", "10 PM", "Step 1 → Step 2", "I'm here", "where x = 5",
                  "Self-Attention O(n² · d) O(1) O(1)", "Table 1: Maximum path lengths", "Eq. (1)", "Fig. 3"] {
            #expect(!TranslationFilter.isLiteral(t), "\(t)")
        }
    }

    // MARK: two rules with two meanings

    @Test func formulaAndIdentifierAreTwoRules() {
        #expect(TranslationFilter.isFormula("QKT") && !TranslationFilter.isIdentifier("QKT"))
        #expect(TranslationFilter.isIdentifier("MatMul") && !TranslationFilter.isFormula("MatMul"))
        #expect(TranslationFilter.isIdentifier("(SoftMax)") && TranslationFilter.isIdentifier("ReLU,"))
        #expect(!TranslationFilter.isIdentifier("Scale") && !TranslationFilter.isIdentifier("NASA") && !TranslationFilter.isIdentifier("Mat Mul"))
    }

    /// Japanese and Chinese run Latin words into the sentence without a space; the sentence is text.
    @Test func latinRunIntoCJKIsStillTranslated() {
        for t in ["YouTubeで見る", "iPhoneを買う", "GitHubのIssue一覧", "Kは変数", "Q&Aコーナー", "x = 5 を代入する", "한국어 iPhone 앱"] {
            #expect(!TranslationFilter.isLiteral(t), "\(t)")
        }
    }

    // MARK: no regression over the use-case bench

    /// The units of one `expected.txt`, as tools/usecase-bench/score.py `units()` reads them: a trailing note in
    /// brackets is dropped, and a `|` separates the cells of a row (not in a shell line or the "Feature" header).
    private func units(_ path: String) throws -> [String] {
        let note = try NSRegularExpression(pattern: #"\s*\((?:[^()]*(?:optional|header|row|merged|vertical|each|one sentence|figure labels|controls|timestamps|columns|table)[^()]*)\)\s*$"#)
        var units: [String] = []
        for var line in try String(contentsOfFile: path, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            line = note.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
            let cells = line.contains("|") && !line.hasPrefix("$") && !line.hasPrefix("Feature") ? line.split(separator: "|", omittingEmptySubsequences: false).map(String.init) : [line]
            units += cells.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return units
    }

    /// Everything the bench says is on its pictures stays translatable but for the equations of the paper pictures
    /// (p01, p05, p06: "L = Σi d(li, li+1) + λ |G| (1)", which score.py itself cuts at the `|` into three units, one of
    /// them the lone letter "G") and one masthead brand (d06): "TechDaily" is camelCase, and a brand is left on screen as
    /// written (Text.swift `TranslationFilter`).
    @Test func benchTruthIsNotNewlyLiteral() throws {
        let set = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/usecase-bench/set")
        let files = try FileManager.default.contentsOfDirectory(atPath: set.path).filter { $0.hasSuffix(".expected.txt") }.sorted()
        #expect(files.count >= 40)
        var all = 0
        var newly: [String] = []
        for f in files {
            for u in try units(set.appendingPathComponent(f).path) {
                all += 1
                if TranslationFilter.isLiteral(u), !TranslationFilter.matchesLiteralPattern(u) { newly.append(u) }
            }
        }
        #expect(all >= 200, "\(all) units")
        #expect(Set(newly) == ["L = Σi d(li, li+1) + λ", "G", "d(li, li+1) < τ (1)", "g = mini d(li, li+1) (1)", "TechDaily"], "\(newly)")
    }
}

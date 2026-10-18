import Foundation
import Testing
@testable import MwoyeoCore

/// A block of prose that is mostly inline mathematics stays as written (page 5 of arXiv 1706.03762, v1.1.1 RC, live, 2026-10-18:
/// "W ∈ R dmodel × dk" came back as "WO € R dmod × dx"). Apple Translation copies symbols as they come (26 sentences, none
/// changed), so the garbling is the recognizer's; the original has the symbols typeset.
@Suite struct MathHeavyTests {
    private func kept(_ t: String) -> Bool {
        TranslationFilter.isLiteral(t) && !TranslationFilter.needsTranslation(t, cjkSource: false)
    }

    // MARK: what the paper bench read (v1.1.1 + the paper rules, 2x screen, page ~ 820 pt wide)

    @Test func theGarbledMatricesOfPage5StayAsWritten() {
        for t in [
            // Two lines of the paragraph, as the document reader cut them (share 0.38, four signs).
            "Where the projections are parameter matrices W° € Be xx, WK € Raux, WY € Eden xed and WO E RhdXdm",
            // The same two lines read by another run (0.47, six signs).
            "Where the projections are parameter matrices WO € IR model × dx, WK EIR model × dx, WY € IR modes × do and Wo € Rhdo x dmodel,",
            // Read cleanly (0.56).
            "Where the projections are parameter matrices WQ ∈ R dmodel × dk, WK ∈ R dmodel × dk, WV ∈ R dmodel × dv and WO ∈ R hdv × dmodel.",
        ] {
            #expect(TranslationFilter.isMathHeavy(t), "\(t.prefix(60)) \(TranslationFilter.mathShare(of: t))")
            #expect(kept(t), "\(t.prefix(60))")
        }
    }

    /// Sentences that hold a formula and are mostly words: the translation of the words is wanted, the engine keeps the symbols.
    @Test func sentencesWithAFormulaInThemAreStillTranslated() {
        for t in [
            "dk = do = dmodel/h = 64. Due to the reduced dimension of each head, the total computational cost",     // 0.23
            "dropout rate Pdrop = 0.1, instead of 0.3.",                                                             // 0.28, one sign
            "of continuous representations z = (z1,..., zn). Given z, the decoder then generates an output",         // 0.11
            "We used the Adam optimizer [20] with ß1 = 0.9, ß2 = 0.98 and € = 10-9. We varied the learning rate over the course of training", // 0.19
            "Then their dot product, q • k = ak",
            "In this work we employ h = 8 parallel attention layers, or heads.",
            "We used values of 2.8, 3.7, 6.0 and 9.5 TFLOPS for K80, K40, M40 and P100, respectively.",
            // The whole paragraph, when the reader returns it as one block: the formulas are a fifth of it (0.19).
            "Where the projections are parameter matrices We € IR mod × dk, WK € IR mod × dk, WY € IR mod × do and Wo ERdo x dmodel. In this work we employ h = 8 parallel attention layers, or heads. For each of these we use dk = do = dmodel /h = 64. Due to the reduced dimension of each head, the total computational cost is similar to that of single-head attention with full dimensionality.",
        ] {
            #expect(!TranslationFilter.isMathHeavy(t), "\(t.prefix(60)) \(TranslationFilter.mathShare(of: t))")
            #expect(!TranslationFilter.isLiteral(t), "\(t.prefix(60))")
        }
    }

    // MARK: marks that look like signs and are not

    @Test func pricesDegreesArrowsSeparatorsAndFootnoteMarksAreNotMathematics() {
        for t in ["Total: €45 + €12 shipping", "Total: € 45 + € 12 shipping", "It was 20° outside and 30° inside", "Price: €5 or €10 or €12 per month",
                  "Settings → Privacy → Location services → Photos", "Posted by Anna · 5 min read · Public",
                  "Illia Polosukhin*‡ Niki Parmar† Jakob Uszkoreit‡ Noam Shazeer® Llion Jones©"] {
            #expect(!TranslationFilter.isMathHeavy(t), "\(t) \(TranslationFilter.mathShare(of: t))")
        }
    }

    // MARK: only Latin, Greek and Cyrillic are read

    @Test func otherScriptsAndShortWordsOfOtherLanguagesAreNotRead() {
        for t in ["x = 5 を代入する", "한국어 문장에서 x = 5 그리고 y = 6 그리고 z = 7 을 대입합니다", "Пусть x = 5 и y = 7, тогда сумма равна 12",
                  "Sei x = 5 und y = 7, dann ist die Summe 12 und nicht mehr"] {
            #expect(!TranslationFilter.isMathHeavy(t), "\(t) \(TranslationFilter.mathShare(of: t))")
        }
    }

    // MARK: the two parts of the rule

    @Test func aShareWithoutTwoSignsIsNotEnough() {
        // Mostly symbols, one sign: not a formula the rule is for (a label, an id).
        let t = "WQ WK WV hdv dmodel = 64 dk dv"
        #expect(TranslationFilter.mathShare(of: t).signs == 1 && TranslationFilter.mathShare(of: t).share > TranslationFilter.mathShareLimit)
        #expect(!TranslationFilter.isMathHeavy(t))
    }

    @Test func twoSignsInProseAreNotEnoughEither() {
        let t = "We then set x = 5 and y = 7 before running the experiment on every available machine in the cluster"
        #expect(TranslationFilter.mathShare(of: t).signs == 2 && TranslationFilter.mathShare(of: t).share < TranslationFilter.mathShareLimit)
        #expect(!TranslationFilter.isMathHeavy(t))
    }
}

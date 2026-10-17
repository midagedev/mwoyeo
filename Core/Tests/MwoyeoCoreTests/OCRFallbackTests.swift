import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct OCRFallbackTests {
    // What this Mac reports (macOS 27): the Objective-C request at revision 3 and 2, and `.fast`.
    private let vn3 = ["en-US", "fr-FR", "it-IT", "de-DE", "es-ES", "pt-BR", "zh-Hans", "zh-Hant", "yue-Hans", "yue-Hant", "ko-KR", "ja-JP",
                       "ru-RU", "uk-UA", "th-TH", "vi-VT"]
    private let rev2 = ["en-US", "fr-FR", "it-IT", "de-DE", "es-ES", "pt-BR", "zh-Hans", "zh-Hant"]
    private let fast = ["en-US", "fr-FR", "it-IT", "de-DE", "es-ES", "pt-BR"]

    private func ladder(_ requested: [String], vn3 v: [String]? = nil, rev2 r: [String]? = nil, fast f: [String]? = nil) -> [OCRFallback] {
        OCRFallback.ladder(requested: requested, vision3: v ?? vn3, revision2: r ?? rev2, fast: f ?? fast)
    }

    @Test func japaneseAndKoreanAreReadByRevision3Alone() {
        #expect(ladder(["ja"]) == [.vision3(["ja-JP"])])
        #expect(ladder(["ko"]) == [.vision3(["ko-KR"])])
        #expect(ladder(["ko", "en"]) == [.vision3(["ko-KR", "en-US"])])
    }

    @Test func englishHasEveryRungInOrderWithItsIdentifier() {
        #expect(ladder(["en"]) == [.vision3(["en-US"]), .revision2(["en-US"]), .fast(["en-US"])])
        #expect(ladder(["en-GB"]) == [.vision3(["en-US"]), .revision2(["en-US"]), .fast(["en-US"])])
        #expect(ladder(["pt-BR"]).first == .vision3(["pt-BR"]))
    }

    @Test func chineseKeepsItsScript() {
        #expect(ladder(["zh-Hans"]) == [.vision3(["zh-Hans"]), .revision2(["zh-Hans"])])
        #expect(ladder(["zh-Hant"]) == [.vision3(["zh-Hant"]), .revision2(["zh-Hant"])])
        // A script a rung does not have is not read as the other one.
        #expect(ladder(["zh-Hans"], vn3: ["zh-Hant"], rev2: ["zh-Hant"]) == [])
        // No script asked for: any Chinese will do.
        #expect(ladder(["zh"]).first == .vision3(["zh-Hans"]))
    }

    @Test func aRungThatMissesOneLanguageIsLeftOut() {
        // Revision 2 and fast read English but not Korean: only revision 3 reads both.
        #expect(ladder(["ko", "en"]) == [.vision3(["ko-KR", "en-US"])])
        #expect(ladder(["en", "en-GB"]).first == .vision3(["en-US"]))
        #expect(ladder(["en", "fr"]).last == .fast(["en-US", "fr-FR"]))
    }

    @Test func noRequestedLanguageDetectsOnEveryRung() {
        #expect(ladder([]) == [.vision3([]), .revision2([]), .fast([])])
    }

    @Test func aLanguageNoRungReadsHasNoFallback() {
        #expect(ladder(["xx"]) == [])
        #expect(ladder(["ja"], vn3: [], rev2: rev2) == [])
    }

    @Test func aLanguageOnlyTheFastRecognizerReadsFallsToFast() {
        #expect(ladder(["en"], vn3: [], rev2: ["fr-FR"], fast: ["en-US", "fr-FR"]) == [.fast(["en-US"])])
    }

    @Test func missingRungsAreSkipped() {
        // Revision 3 and 2 unavailable on this system: any language goes to fast, and so does "detect".
        #expect(ladder([], vn3: [], rev2: []) == [.fast([])])
        #expect(ladder([], vn3: [], rev2: [], fast: []) == [])
        #expect(ladder(["en"], vn3: []) == [.revision2(["en-US"]), .fast(["en-US"])])
    }
}

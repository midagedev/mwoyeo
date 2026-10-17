import Testing
@testable import MwoyeoCore

@Suite struct TranslationCheckTests {
    private func flagged(_ s: String, _ t: String, _ target: String = "ko") -> Bool {
        TranslationCheck.isUntranslated(source: s, translation: t, target: target)
    }

    @Test func echoedLinesAreFlagged() {
        #expect(flagged("哈哈哈笑死我了😂", "哈哈哈笑死我了😂"))
        #expect(flagged("I'll send it tomorrow", "I'll send it tomorrow"))
        // gpt-5-nano handed a Japanese line back for a Korean target
        #expect(flagged("今日の会議は延期になりました", "今日の会議は延期になりました"))
        #expect(flagged("Thanks for the update", "Thanks for the update!", "ko"))
        #expect(flagged("今日は晴れです", "今日は晴れです。", "ko"))
    }

    @Test func keptNamesNumbersAndRealTranslationsAreNot() {
        #expect(!flagged("iPhone 17 Pro", "iPhone 17 Pro"))
        #expect(!flagged("I bought an iPhone 17 Pro", "iPhone 17 Pro를 샀어"))
        #expect(!flagged("12:30", "12:30"))
        // channel names, handles and one or two plain words are names an engine may keep (live Gemini, GPT)
        #expect(!flagged("# general", "# general"))
        #expect(!flagged("@mina", "@mina"))
        #expect(!flagged("Starfall", "Starfall"))
        #expect(!flagged("😂😂", "😂😂"))
        #expect(!flagged("See you tomorrow", "내일 봐요"))
        #expect(!flagged("今日の会議は延期になりました", "오늘 회의는 연기되었습니다"))
        #expect(!flagged("Good morning", "おはようございます", "ja"))
        #expect(!flagged("Good morning", "早上好", "zh"))
    }

    @Test func displayFormTurnsStandaloneJamoIntoCompatibilityJamo() {
        #expect(TranslationCheck.displayForm("\u{110F}\u{110F} 그 회의") == "ㅋㅋ 그 회의")
        #expect(TranslationCheck.displayForm("안녕하세요 meeting 12:30 😂") == "안녕하세요 meeting 12:30 😂")
        // a choseong that starts a decomposed syllable is composed by NFC, not replaced
        #expect(TranslationCheck.displayForm("\u{1112}\u{1161}\u{11AB}") == "한")
    }
}

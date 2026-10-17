import Foundation
import Testing
@testable import MwoyeoCore

/// Twenty lines of a visual novel, ja -> ko. アリス is 앨리스 three times and 엘리스 twice, ルーク is left as is
/// twice, ゲーム is 게임/놀이 (inconsistent, but a stop-word).
private let jaKoLines: [(String, String)] = [
    ("アリスは剣を抜いた。", "앨리스는 검을 뽑았다."),
    ("森の奥に古い塔がある。", "숲 깊은 곳에 오래된 탑이 있다."),
    ("「急ごう」とルークは言った。", "\"서두르자\"라고 ルーク가 말했다."),
    ("アリス、待って！", "앨리스, 기다려!"),
    ("ゲームを始めよう。", "게임을 시작하자."),
    ("アリスは静かに笑った。", "엘리스가 조용히 웃었다."),
    ("ルークが門の前で待っている。", "ルーク가 문 앞에서 기다리고 있다."),
    ("夜が明けるまで歩き続けた。", "날이 밝을 때까지 계속 걸었다."),
    ("このゲームは難しい。", "이 놀이는 어렵다."),
    ("アリスの杖が青く光る。", "엘리스의 지팡이가 푸르게 빛난다."),
    ("ゲームオーバーだ。", "게임 오버다."),
    ("ルークは何も言わなかった。", "루크는 아무 말도 하지 않았다."),
    ("風が冷たくなってきた。", "바람이 차가워지기 시작했다."),
    ("アリスを助けなきゃ！", "앨리스를 구해야 해!"),
    ("ゲームはまだ終わらない。", "놀이는 아직 끝나지 않는다."),
    ("王都までは三日かかる。", "왕도까지는 사흘이 걸린다."),
    ("ゲームを再開しますか？", "게임을 재개하시겠습니까?"),
    ("村は静まり返っていた。", "마을은 고요해져 있었다."),
    ("橋を渡れば国境だ。", "다리를 건너면 국경이다."),
    ("誰もいない広場だった。", "아무도 없는 광장이었다."),
]

private func observed(_ lines: [(String, String)], from: String? = "ja", to: String = "ko") -> GlossarySuggester {
    var g = GlossarySuggester()
    for (s, t) in lines { g.observe(source: s, translation: t, sourceLanguage: from, targetLanguage: to) }
    return g
}

@Suite struct GlossarySuggesterTests {
    @Test func japaneseNamesInconsistentAndUntranslated() {
        let found = observed(jaKoLines).suggestions(existing: [], limit: 10)
        let alice = found.first { $0.term == "アリス" }
        #expect(alice?.reason == .inconsistent)
        #expect(alice?.occurrences == 5)
        #expect(alice?.renderings.map(\.0) == ["앨리스", "엘리스"])
        #expect(alice?.renderings.map(\.1) == [3, 2])
        let luke = found.first { $0.term == "ルーク" }
        #expect(luke?.reason == .leftUntranslated)
        #expect(luke?.renderings.first?.0 == "ルーク" && luke?.renderings.first?.1 == 2)
        #expect(luke?.renderings.contains { $0.0 == "루크" && $0.1 == 1 } == true)
        #expect(found.first?.term == "アリス")   // inconsistent ranks before untranslated
    }

    @Test func commonLoanwordIsNeverSuggested() {
        #expect(!observed(jaKoLines).suggestions(existing: [], limit: 10).contains { $0.term == "ゲーム" })
        #expect(!GlossarySuggester.candidates(in: "ゲームをしよう", language: "ja").contains("ゲーム"))
    }

    @Test func existingGlossaryEntrySuppressesTheTerm() {
        let found = observed(jaKoLines).suggestions(existing: [("アリス", "앨리스")], limit: 10)
        #expect(!found.contains { $0.term == "アリス" })
        #expect(found.contains { $0.term == "ルーク" })
    }

    @Test func termNeedsThreeOccurrences() {
        // ルーク appears in two lines, both left untranslated: not yet.
        let two = Array(jaKoLines.filter { !$0.0.contains("ルーク") || $0.0.contains("急ごう") || $0.0.contains("門") })
        #expect(!observed(two).suggestions(existing: [], limit: 10).contains { $0.term == "ルーク" })
        #expect(observed(jaKoLines).suggestions(existing: [], limit: 10).contains { $0.term == "ルーク" })
    }

    @Test func limitKeepsTheBest() {
        let one = observed(jaKoLines).suggestions(existing: [], limit: 1)
        #expect(one.map(\.term) == ["アリス"])
        #expect(observed(jaKoLines).suggestions(existing: [], limit: 0).isEmpty)
    }

    @Test func englishNameRenderedTwoWays() {
        let lines: [(String, String)] = [
            ("We should ask Captain Mira first.", "먼저 미라 선장에게 물어봐야 해."),
            ("Captain Mira laughed.", "미라 선장은 웃었다."),
            ("The ship belongs to Captain Mira.", "그 배는 미라 선장의 것이다."),
            ("Then Captain Mira drew her sword.", "그때 캡틴 미라가 검을 뽑았다."),
            ("Not now, Captain Mira said.", "지금은 안 돼, 캡틴 미라가 말했다."),
            ("Mira nodded slowly.", "미라는 천천히 고개를 끄덕였다."),
            ("Mira, wait for me!", "미라, 나를 기다려!"),
            ("Is that you, Mira?", "미라, 너니?"),
            ("The harbor was quiet tonight.", "항구는 오늘 밤 조용했다."),
            ("Nobody answered the door.", "아무도 문에 답하지 않았다."),
            ("Rain began to fall.", "비가 내리기 시작했다."),
        ]
        let found = observed(lines, from: "en").suggestions(existing: [], limit: 10)
        let captain = found.first { $0.term == "Captain" }
        #expect(captain?.reason == .inconsistent)
        #expect(captain?.renderings.map(\.0) == ["선장", "캡틴"])
        #expect(captain?.renderings.map(\.1) == [3, 2])
        // 미라 every time. It also co-occurs with Captain, but it is common in lines without Captain,
        // so it is not taken as the rendering of Captain.
        #expect(!found.contains { $0.term == "Mira" })
    }

    @Test func latinNameLeftInLatinInKoreanIsFlagged() {
        let lines: [(String, String)] = [
            ("Where is Lyra?", "Lyra는 어디 있지?"),
            ("Lyra has the key.", "Lyra가 열쇠를 가지고 있다."),
            ("Follow Lyra.", "Lyra를 따라가."),
            ("The door is locked.", "문이 잠겨 있다."),
        ]
        let found = observed(lines, from: "en").suggestions(existing: [], limit: 5)
        #expect(found.first?.term == "Lyra" && found.first?.reason == .leftUntranslated)
    }

    @Test func sameScriptTargetsKeepNamesWithoutComplaint() {
        let lines: [(String, String)] = [
            ("Where is Lyra?", "Où est Lyra ?"), ("Lyra has the key.", "Lyra a la clé."),
            ("Follow Lyra.", "Suis Lyra."), ("The door is locked.", "La porte est fermée."),
        ]
        #expect(observed(lines, from: "en", to: "fr").suggestions(existing: [], limit: 5).isEmpty)
    }

    @Test func sentenceInitialCapitalsAreNotNames() {
        #expect(GlossarySuggester.candidates(in: "Then we left. Maybe Tomorrow, Mira said.", language: "en")
            .filter { $0 == "Then" || $0 == "Maybe" || $0 == "Mira" || $0 == "Tomorrow" }
            .sorted() == ["Mira", "Tomorrow"])
        #expect(GlossarySuggester.candidates(in: "HP 100 Lv UP", language: "en").isEmpty)
    }

    @Test func containsRespectsWordEdges() {
        #expect(GlossarySuggester.contains("Mira smiled", "Mira"))
        #expect(!GlossarySuggester.contains("Miranda smiled", "Mira"))
        #expect(GlossarySuggester.contains("Mira가 웃었다", "Mira"))
        #expect(!GlossarySuggester.contains("ルークスが来た", "ルーク"))
        #expect(GlossarySuggester.contains("ルークが来た", "ルーク"))
    }

    @Test func koreanParticlesAreStripped() {
        let t = GlossarySuggester.tokens("미라에게는 말했다", target: "ko")
        #expect(t["미라"] == "미라" && t["미라에게"] != nil && t["말했다"] != nil)
    }

    @Test func kanaToHangulTable() {
        #expect(KanaHangul.transliterate("アリス") == "아리스")
        #expect(KanaHangul.transliterate("ルーク") == "루크")
        #expect(KanaHangul.transliterate("シャーロット") == "샤롯토")   // ッ closes the syllable (롯), ト keeps its o
        #expect(KanaHangul.transliterate("カイト") == "가이토")           // word-initial カ is voiced, later ト is not
        #expect(KanaHangul.transliterate("ランス") == "란스")             // ン is a final
        #expect(KanaHangul.transliterate("ジャック") == "잣크")           // ジャ is 자 (palatal, no ㅑ), ッ gives it a ㅅ final
        #expect(KanaHangul.transliterate("フィオナ") == "피오나")
        #expect(KanaHangul.variants("エルフィーナ") == ["에루피나", "엘피나"])
        #expect(KanaHangul.variants("アリス").count == 1)
    }

    @Test func katakanaMatchesAcrossSpellingsWithinTolerance() {
        // 에루피나/엘피나: the lateral-final variant catches the usual spelling, particles are stripped.
        let lines: [(String, String)] = [
            ("エルフィーナは微笑んだ。", "엘피나는 미소 지었다."), ("エルフィーナを探そう。", "엘피나를 찾자."),
            ("エルフィーナの声が聞こえる。", "엘피나의 목소리가 들린다."), ("エルフィーナが来た。", "엘피 나가 왔다."),
            ("空が暗い。", "하늘이 어둡다."),
        ]
        let g = observed(lines)
        let all = g.suggestions(existing: [], limit: 5)
        // Spelled one way three times: consistent, so nothing to suggest. The point is that nothing crashes
        // and the fourth, split spelling does not create a bogus second rendering of weight 2.
        #expect(all.isEmpty)
    }
}

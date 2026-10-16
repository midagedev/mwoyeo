import Foundation
import Testing
@testable import MwoyeoCore

private typealias Seg = Readings.RubySegment

private func joined(_ segs: [Seg]) -> String { segs.map(\.base).joined() }

/// Reading-bearing segments with adjacent ones merged, so a different token split
/// (東京|駅 vs 東京駅) does not count as a wrong reading.
private func readingPairs(_ segs: [Seg]) -> [String] {
    var out: [String] = []
    var prevHad = false
    for s in segs {
        if let r = s.reading {
            if prevHad, let last = out.popLast() {
                let parts = last.split(separator: "|", maxSplits: 1).map(String.init)
                out.append("\(parts[0])\(s.base)|\(parts[1])\(r)")
            } else {
                out.append("\(s.base)|\(r)")
            }
            prevHad = true
        } else {
            prevHad = false
        }
    }
    return out
}

/// Expected kanji segments, as the reading a Japanese reader would write over each kanji run.
private let japaneseFixtures: [(text: String, expected: [String])] = [
    ("今日は雨が降っている", ["今日|きょう", "雨|あめ", "降|ふ"]),
    ("食べる", ["食|た"]),
    ("一緒に遊ぼう", ["一緒|いっしょ", "遊|あそ"]),
    ("東京駅", ["東京駅|とうきょうえき"]),
    ("大丈夫", ["大丈夫|だいじょうぶ"]),
    ("行ってきます", ["行|い"]),
    ("魔法使い", ["魔法使|まほうつか"]),
    ("勇者", ["勇者|ゆうしゃ"]),
    ("私は学生です", ["私|わたし", "学生|がくせい"]),
    ("彼女は先生です", ["彼女|かのじょ", "先生|せんせい"]),
    ("何を言っているの", ["何|なに", "言|い"]),
    ("見て、この景色", ["見|み", "景色|けしき"]),
    ("早く逃げろ", ["早|はや", "逃|に"]),
    ("時間がない", ["時間|じかん"]),
    ("ありがとう、友達", ["友達|ともだち"]),
    ("日本語を勉強しています", ["日本語|にほんご", "勉強|べんきょう"]),
    ("お願いします", ["願|ねが"]),
    ("書き込み", ["書|か", "込|こ"]),
    ("魔王を倒せ", ["魔王|まおう", "倒|たお"]),
    ("新しい武器を手に入れた", ["新|あたら", "武器|ぶき", "手|て", "入|い"]),
    ("この先は危険だ", ["先|さき", "危険|きけん"]),
    ("仲間を助ける", ["仲間|なかま", "助|たす"]),
    ("明日会おう", ["明日|あした", "会|あ"]),
    ("電車に乗る", ["電車|でんしゃ", "乗|の"]),
    ("美味しいご飯", ["美味|おい", "飯|はん"]),
    ("本当にごめんなさい", ["本当|ほんとう"]),
    ("音楽が好きです", ["音楽|おんがく", "好|す"]),
    ("天気がいいですね", ["天気|てんき"]),
    ("質問があります", ["質問|しつもん"]),
    ("戦いが始まる", ["戦|たたか", "始|はじ"]),
]

/// Pinyin syllables with tone marks, neutral tones unmarked, as a dictionary writes them.
private let chineseFixtures: [(text: String, expected: [String])] = [
    ("你好", ["nǐ", "hǎo"]),
    ("中国人", ["zhōng", "guó", "rén"]),
    ("谢谢", ["xiè", "xie"]),
    ("我爱你", ["wǒ", "ài", "nǐ"]),
    ("今天天气很好", ["jīn", "tiān", "tiān", "qì", "hěn", "hǎo"]),
    ("对不起", ["duì", "bu", "qǐ"]),
    ("再见", ["zài", "jiàn"]),
    ("朋友", ["péng", "you"]),
    ("学习汉语", ["xué", "xí", "hàn", "yǔ"]),
    ("什么", ["shén", "me"]),
    ("没关系", ["méi", "guān", "xi"]),
    ("吃饭了吗", ["chī", "fàn", "le", "ma"]),
    ("北京", ["běi", "jīng"]),
    ("我是学生", ["wǒ", "shì", "xué", "shēng"]),
    ("很高兴认识你", ["hěn", "gāo", "xìng", "rèn", "shi", "nǐ"]),
]

/// Revised Romanization, the scheme learners meet on signs and in textbooks.
private let koreanFixtures: [(text: String, expected: String)] = [
    ("안녕하세요", "annyeonghaseyo"),
    ("감사합니다", "gamsahamnida"),
    ("한국어", "hangugeo"),
    ("사랑해요", "saranghaeyo"),
    ("고마워요", "gomawoyo"),
    ("학교", "hakgyo"),
    ("맛있어요", "masisseoyo"),
    ("먹었어요", "meogeosseoyo"),
    ("좋아요", "johayo"),
    ("대한민국", "daehanminguk"),
]

@Suite struct ReadingsTests {
    @Test func basesAlwaysConcatenateToTheInput() {
        for f in japaneseFixtures { #expect(joined(Readings.furigana(f.text)) == f.text, "\(f.text)") }
        for f in chineseFixtures { #expect(joined(Readings.pinyin(f.text)) == f.text, "\(f.text)") }
        for s in ["", "  ", "Hello, world", "今日 is 雨 😀 です!", "ひらがなだけ", "カタカナ", "１２３", "\n今日\n"] {
            #expect(joined(Readings.furigana(s)) == s, "\(s)")
            #expect(joined(Readings.pinyin(s)) == s, "\(s)")
        }
    }

    @Test func okuriganaIsSplitOff() {
        #expect(Readings.furigana("食べる") == [Seg(base: "食", reading: "た"), Seg(base: "べる")])
        #expect(Readings.furigana("行って") == [Seg(base: "行", reading: "い"), Seg(base: "って")])
        #expect(Readings.furigana("書き込み") == [
            Seg(base: "書", reading: "か"), Seg(base: "き"), Seg(base: "込", reading: "こ"), Seg(base: "み"),
        ])
        #expect(Readings.furigana("お願いします") == [
            Seg(base: "お"), Seg(base: "願", reading: "ねが"), Seg(base: "いします"),
        ])
    }

    @Test func textWithoutKanjiHasNoReadings() {
        for s in ["ひらがな", "カタカナ", "Hello world", "１２３ !?", "", "😀"] {
            #expect(Readings.furigana(s).allSatisfy { $0.reading == nil }, "\(s)")
        }
        #expect(Readings.furigana("").isEmpty)
        #expect(Readings.pinyin("").isEmpty)
        #expect(Readings.pinyin("Hello 123").allSatisfy { $0.reading == nil })
        #expect(Readings.romanizedKorean("") == "")
    }

    @Test func mixedScriptsKeepTheirPlaceAndOnlyKanjiGetReadings() {
        let segs = Readings.furigana("今日はGitHubで😀勉強")
        #expect(joined(segs) == "今日はGitHubで😀勉強")
        #expect(segs.filter { $0.reading != nil }.map(\.base) == ["今日", "勉強"])
        #expect(segs.first { $0.base.contains("😀") }?.reading == nil)
    }

    @Test func romajiIsLowercaseAndSpaced() {
        let r = Readings.romaji("今日は雨")
        #expect(r == r.lowercased())
        #expect(r.contains("kyou"))
        #expect(Readings.romaji("").isEmpty)
    }

    @Test func pinyinTones() {
        #expect(Readings.pinyin("你好").map(\.reading) == ["nǐ", "hǎo"])
        #expect(Readings.pinyin("中国人").map(\.reading) == ["zhōng", "guó", "rén"])
    }

    @Test func koreanIsLatinAndKeepsPunctuation() {
        let r = Readings.romanizedKorean("안녕하세요")
        #expect(r == "annyeonghaseyo")
        #expect(Readings.romanizedKorean("안녕!").hasSuffix("!"))
    }

    /// Measured 2026-10-17 on macOS 26 (Darwin 27): Japanese 46/51 kanji segments, Chinese 43/48
    /// syllables, Korean 2/10 phrases. Floors, not targets.
    /// Japanese misses: 私 わたくし (want わたし), 何 なん (なに), 日本語 にっぽんご (にほんご), and
    /// 明日会おう tokenized as 明日会 (あすあ), which loses 明日|あした and 会|あ.
    /// Chinese misses are all neutral tones (谢谢, 对不起, 朋友, 没关系, 认识), which MandarinLatin marks.
    /// Korean: Hangul-Latin is jamo-by-jamo (haggyo, hangug-eo, salanghaeyo), not Revised Romanization.
    @Test func fixtureAccuracyHoldsItsMeasuredFloor() {
        var jaOK = 0, jaTotal = 0, misses: [String] = []
        for f in japaneseFixtures {
            let got = readingPairs(Readings.furigana(f.text))
            for e in f.expected {
                jaTotal += 1
                if got.contains(e) { jaOK += 1 } else { misses.append("ja \(f.text): want \(e), got \(got)") }
            }
        }
        var zhOK = 0, zhTotal = 0
        for f in chineseFixtures {
            let got = Readings.pinyin(f.text).compactMap(\.reading).flatMap { $0.split(separator: " ").map(String.init) }
            for (i, e) in f.expected.enumerated() {
                zhTotal += 1
                if i < got.count, got[i] == e { zhOK += 1 } else { misses.append("zh \(f.text): want \(e), got \(got)") }
            }
        }
        var koOK = 0
        for f in koreanFixtures {
            if Readings.romanizedKorean(f.text) == f.expected { koOK += 1 } else {
                misses.append("ko \(f.text): want \(f.expected), got \(Readings.romanizedKorean(f.text))")
            }
        }
        if ProcessInfo.processInfo.environment["READINGS_DUMP"] != nil {
            print("READINGS ja \(jaOK)/\(jaTotal) zh \(zhOK)/\(zhTotal) ko \(koOK)/\(koreanFixtures.count)")
            for m in misses { print("MISS \(m)") }
        }
        #expect(jaTotal == 51 && jaOK >= 46)
        #expect(zhTotal == 48 && zhOK >= 43)
        #expect(koOK >= 2)
    }
}

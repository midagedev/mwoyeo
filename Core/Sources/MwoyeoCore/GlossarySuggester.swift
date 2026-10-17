import Foundation
import NaturalLanguage

/// Watches translated lines and notices names (characters, places, skills) that come out inconsistently
/// or are left untranslated, so the app can offer "Add 'アリス = 앨리스' to the glossary?".
///
/// Everything is heuristic and lexical; it never calls a translator. Lines are kept in memory only
/// (the latest `maxLines`), and only lines of the most recent target language are compared.
public struct GlossarySuggester: Sendable {
    public struct Suggestion: Sendable {
        public enum Reason: Sendable { case inconsistent, leftUntranslated }
        public var term: String
        /// How the term came out in the translations, most frequent first. The term itself means "left as is".
        public var renderings: [(String, Int)]
        /// Observed lines whose source contains the term.
        public var occurrences: Int
        public var reason: Reason

        public init(term: String, renderings: [(String, Int)], occurrences: Int, reason: Reason) {
            self.term = term; self.renderings = renderings; self.occurrences = occurrences; self.reason = reason
        }
    }

    /// A term is never suggested before it has been seen in this many lines.
    public static let minOccurrences = 3
    public static let maxLines = 800

    private struct Line: Sendable {
        let source: String
        let translation: String
        let target: String
        let terms: [String]
    }

    private var lines: [Line] = []

    public init() {}

    /// Call once per translated line (the caller de-duplicates repeats).
    public mutating func observe(source: String, translation: String, sourceLanguage: String?, targetLanguage: String) {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !t.isEmpty else { return }
        lines.append(Line(source: s, translation: t, target: targetLanguage,
                          terms: Self.candidates(in: s, language: sourceLanguage)))
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
    }

    /// Terms worth a glossary entry: inconsistent ones first, then by how often they occurred.
    /// A term that is translated the same way every time is not suggested; it needs no help.
    public func suggestions(existing: [(String, String)], limit: Int) -> [Suggestion] {
        guard limit > 0, let target = lines.last?.target else { return [] }
        let pool = lines.filter { $0.target == target }
        let known = existing.map { $0.0.trimmingCharacters(in: .whitespaces).lowercased() }
        var terms = Set<String>()
        for line in pool { terms.formUnion(line.terms) }

        var result: [Suggestion] = []
        for term in terms.sorted() {
            let lower = term.lowercased()
            if known.contains(where: { $0 == lower || $0.contains(lower) }) { continue }
            let hits = pool.filter { Self.contains($0.source, term) }
            guard hits.count >= Self.minOccurrences else { continue }
            let others = pool.filter { !Self.contains($0.source, term) }
            if let s = Self.evaluate(term: term, hits: hits, others: others, target: target) { result.append(s) }
        }
        result.sort {
            if ($0.reason == .inconsistent) != ($1.reason == .inconsistent) { return $0.reason == .inconsistent }
            if $0.occurrences != $1.occurrences { return $0.occurrences > $1.occurrences }
            return $0.term < $1.term
        }
        return Array(result.prefix(limit))
    }

    // MARK: Rendering detection

    /// Per hit line the rendering is, in order of preference:
    /// (a) the term itself, when the translation contains it (left untranslated);
    /// (b) katakana into a Hangul target: a Hangul word within edit distance max(1, n/3) of the
    ///     transliterated term (n syllables), see `KanaHangul`;
    /// (c) otherwise the translation word that co-occurs with the term: present in >= 60 % of the
    ///     remaining term lines (>= 2 of them) and in <= 25 % of the lines without the term. Up to three
    ///     rounds, each on the lines the earlier words did not explain, so a second spelling can surface.
    /// Words are split on spaces and punctuation, Korean particles are stripped from the end.
    private static func evaluate(term: String, hits: [Line], others: [Line], target: String) -> Suggestion? {
        let hitTokens = hits.map { tokens($0.translation, target: target) }
        let verbatim = hits.map { contains($0.translation, term) }
        var assigned: [String?] = verbatim.map { $0 ? term : nil }

        if languageCode(target) == "ko", isKatakana(term) {
            let variants = KanaHangul.variants(term)
            for i in hits.indices where assigned[i] == nil {
                assigned[i] = nearestHangul(variants, in: hitTokens[i])
            }
        } else {
            let otherTokens = others.suffix(200).map { tokens($0.translation, target: target) }
            let picked = pickCooccurring(term: term, hitTokens: hitTokens, skip: verbatim, otherTokens: otherTokens)
            for i in hits.indices where assigned[i] == nil {
                for key in picked { if let shown = hitTokens[i][key] { assigned[i] = shown; break } }
            }
        }

        var counts: [String: Int] = [:]
        for case let r? in assigned { counts[r, default: 0] += 1 }
        let renderings = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { ($0.key, $0.value) }

        let verbatimCount = verbatim.filter { $0 }.count
        let reason: Suggestion.Reason
        if counts.values.filter({ $0 >= 2 }).count >= 2 {
            reason = .inconsistent
        } else if verbatimCount >= 2, scriptDiffers(term, from: target) {
            reason = .leftUntranslated
        } else {
            return nil
        }
        return Suggestion(term: term, renderings: renderings, occurrences: hits.count, reason: reason)
    }

    private static func pickCooccurring(term: String, hitTokens: [[String: String]], skip: [Bool],
                                        otherTokens: [[String: String]]) -> [String] {
        let termKey = term.lowercased()
        var remaining = hitTokens.indices.filter { !skip[$0] }
        var picked: [String] = []
        for _ in 0..<3 {
            guard remaining.count >= 2 else { break }
            var counts: [String: Int] = [:]
            for i in remaining { for k in hitTokens[i].keys where k != termKey { counts[k, default: 0] += 1 } }
            var best: (key: String, ratio: Double, lift: Double)?
            var common = Set<String>()   // frequent words in lines without the term too: 미라 for Captain
            var scored: [(key: String, ratio: Double, otherRatio: Double)] = []
            for (k, c) in counts where c >= 2 && k.count >= 2 && !picked.contains(k) {
                let ratio = Double(c) / Double(remaining.count)
                guard ratio >= 0.6 else { continue }
                let otherRatio = otherTokens.isEmpty ? 0
                    : Double(otherTokens.filter { $0[k] != nil }.count) / Double(otherTokens.count)
                if otherTokens.count >= 3 && otherRatio > 0.25 { common.insert(k) } else { scored.append((k, ratio, otherRatio)) }
            }
            for (k, ratio, otherRatio) in scored {
                // 미라가 is just 미라 with a particle: as common as 미라.
                if common.contains(where: { k.count > $0.count && k.hasPrefix($0) }) { continue }
                let cand = (key: k, ratio: ratio, lift: ratio - otherRatio)
                if let b = best {
                    let better = cand.ratio != b.ratio ? cand.ratio > b.ratio
                        : cand.lift != b.lift ? cand.lift > b.lift
                        : cand.key.count != b.key.count ? cand.key.count > b.key.count
                        : cand.key < b.key
                    if !better { continue }
                }
                best = cand
            }
            guard let b = best else { break }
            picked.append(b.key)
            remaining.removeAll { hitTokens[$0][b.key] != nil }
        }
        return picked
    }

    private static func nearestHangul(_ variants: [String], in tokens: [String: String]) -> String? {
        var best: (shown: String, dist: Int, gap: Int)?
        for (key, shown) in tokens.sorted(by: { $0.key < $1.key }) where key.count >= 2 && isHangul(key) {
            for v in variants {
                let gap = abs(v.count - key.count)
                let d = TextSimilarity.editDistance(v, key)
                guard gap <= 1, d <= max(1, v.count / 3) else { continue }
                if best == nil || (d, gap) < (best!.dist, best!.gap) { best = (shown, d, gap) }
            }
        }
        return best?.shown
    }

    // MARK: Translation words

    private static let koreanParticles = ["에게", "에서", "으로", "은", "는", "이", "가", "을", "를", "의", "에", "와", "과", "도", "로"]

    /// Lowercased word -> word as written. Korean words also appear with up to two particles stripped
    /// (미라가 -> 미라), since a particle-like last syllable (카이) cannot be told apart in advance.
    static func tokens(_ text: String, target: String) -> [String: String] {
        var words: [String] = []
        let code = languageCode(target)
        if ["ja", "zh", "th"].contains(code) {
            let tk = NLTokenizer(unit: .word)
            tk.string = text
            tk.setLanguage(NLLanguage(rawValue: code))
            tk.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in words.append(String(text[r])); return true }
        } else {
            let separators = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols)
            words = text.components(separatedBy: separators).filter { !$0.isEmpty }
        }
        var out: [String: String] = [:]
        for w in words {
            out[w.lowercased()] = out[w.lowercased()] ?? w
            guard code == "ko" else { continue }
            var cur = w
            for _ in 0..<2 {
                guard let p = koreanParticles.first(where: { cur.hasSuffix($0) && cur.count - $0.count >= 2 }) else { break }
                cur = String(cur.dropLast(p.count))
                out[cur] = out[cur] ?? cur
            }
        }
        return out
    }

    // MARK: Candidate terms

    /// Katakana loanwords that are common nouns in game and app text; they would otherwise flood the
    /// suggestions with words every translator already renders well.
    static let katakanaStopWords: Set<String> = [
        "ゲーム", "メッセージ", "サーバー", "ユーザー", "アイテム", "スキル", "レベル", "ステータス", "アプリ", "ボタン",
        "メニュー", "データ", "ネットワーク", "アカウント", "パスワード", "ファイル", "フォルダ", "システム", "プレイヤー",
        "キャラクター", "ダメージ", "クエスト", "ボス", "モード", "オプション", "ログイン", "ホーム", "ページ", "ニュース",
        "テレビ", "ビデオ", "カメラ", "コンピューター", "インターネット", "ミッション", "ストーリー", "チーム", "パーティ",
        "ポイント", "スタート", "ルール", "ゲームオーバー",
    ]

    private static let latinStopWords: Set<String> = [
        "the", "and", "but", "mr", "mrs", "ms", "dr", "monday", "tuesday", "wednesday", "thursday", "friday",
        "saturday", "sunday", "january", "february", "march", "april", "june", "july", "august", "september",
        "october", "november", "december", "ok", "yes", "no", "lv", "exp",
    ]

    /// Source terms that could be names, deduplicated, in order of appearance:
    /// katakana runs of >= 3 characters; capitalized Latin words that are not at a sentence start (skipped
    /// for ja/ko/zh, where Latin is mostly UI text); and NLTagger person/place/organization names for any
    /// language, which is what finds kanji and Hangul names. All-caps words and a stop-word list are dropped.
    static func candidates(in text: String, language: String?) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        func add(_ t: String) {
            guard t.count >= 2, !t.allSatisfy(\.isNumber), seen.insert(t).inserted else { return }
            if katakanaStopWords.contains(t) || latinStopWords.contains(t.lowercased()) { return }
            found.append(t)
        }
        for run in katakanaRuns(text) where run.count >= 3 && !isRepeatedHalf(run) { add(run) }
        if !["ja", "ko", "zh"].contains(language.map(languageCode) ?? "") {
            for w in capitalizedWords(text) { add(w) }
        }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let all = text.startIndex..<text.endIndex
        if let language { tagger.setLanguage(NLLanguage(rawValue: language), range: all) }
        tagger.enumerateTags(in: all, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .omitOther]) { tag, r in
            if let tag, tag == .personalName || tag == .placeName || tag == .organizationName { add(String(text[r])) }
            return true
        }
        return found
    }

    private static func katakanaRuns(_ text: String) -> [String] {
        var runs: [String] = [], cur = String.UnicodeScalarView()
        func flush() { if !cur.isEmpty { runs.append(String(cur)) }; cur = String.UnicodeScalarView() }
        for u in text.unicodeScalars {
            if isKatakana(u), !(cur.isEmpty && u.value == 0x30FC) { cur.append(u) } else { flush() }
        }
        flush()
        return runs
    }

    /// ドキドキ, ワクワク: onomatopoeia, translated differently every time.
    private static func isRepeatedHalf(_ s: String) -> Bool {
        let c = Array(s)
        return c.count % 2 == 0 && c[..<(c.count / 2)] == c[(c.count / 2)...]
    }

    private static func capitalizedWords(_ text: String) -> [String] {
        var out: [String] = []
        var atStart = true
        var word = ""
        func flush() {
            defer { word = "" }
            guard let f = word.first else { return }
            if f.isUppercase, word.count >= 2, word.contains(where: \.isLowercase), !atStart { out.append(word) }
            atStart = false
        }
        for ch in text {
            if ch.unicodeScalars.allSatisfy({ isLatinLetter($0) }) {
                word.append(ch)
            } else {
                flush()
                if ch.isNewline || ".!?…。！？".contains(ch) { atStart = true }
                else if !ch.isWhitespace, !"\"'“”‘’(「『".contains(ch) { atStart = false }
            }
        }
        flush()
        return out
    }

    // MARK: Scripts

    private enum Script { case kana, han, hangul, latin, cyrillic, other }

    static func languageCode(_ id: String) -> String {
        String(id.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
    }

    private static func isKatakana(_ u: Unicode.Scalar) -> Bool { (0x30A1...0x30FA).contains(u.value) || u.value == 0x30FC }
    private static func isKatakana(_ s: String) -> Bool { !s.isEmpty && s.unicodeScalars.allSatisfy { isKatakana($0) } }
    private static func isHangul(_ s: String) -> Bool { s.unicodeScalars.allSatisfy { (0xAC00...0xD7A3).contains($0.value) } }
    private static func isLatinLetter(_ u: Unicode.Scalar) -> Bool { u.value < 0x250 && u.properties.isAlphabetic }

    private static func script(of u: Unicode.Scalar) -> Script {
        switch u.value {
        case 0x3040...0x30FF: .kana
        case 0x4E00...0x9FFF, 0x3400...0x4DBF: .han
        case 0xAC00...0xD7A3, 0x1100...0x11FF: .hangul
        case 0x0400...0x04FF: .cyrillic
        default: isLatinLetter(u) ? .latin : .other
        }
    }

    /// Script of a term, by majority of its characters.
    private static func script(of term: String) -> Script {
        var counts: [Script: Int] = [:]
        for u in term.unicodeScalars { counts[script(of: u), default: 0] += 1 }
        return counts.filter { $0.key != .other }.max { $0.value < $1.value }?.key ?? .other
    }

    /// Whether a term written in its own script would look foreign in this target language. Unknown targets
    /// answer false: leaving a name as is is only a defect when the scripts clearly differ.
    private static func scriptDiffers(_ term: String, from target: String) -> Bool {
        let own = script(of: term)
        guard own != .other else { return false }
        let allowed: Set<Script>
        switch languageCode(target) {
        case "ko": allowed = [.hangul]
        case "ja": allowed = [.kana, .han]
        case "zh": allowed = [.han]
        case "ru", "uk", "bg", "sr": allowed = [.cyrillic]
        case "en", "fr", "de", "es", "it", "pt", "nl", "id", "ms", "vi", "tr", "pl", "sv", "da", "nb", "fi", "cs", "ro", "hu":
            allowed = [.latin]
        default: return false
        }
        return !allowed.contains(own)
    }

    private enum EdgeClass { case katakana, latin, other }
    private static func edgeClass(_ u: Unicode.Scalar) -> EdgeClass {
        isKatakana(u) ? .katakana : isLatinLetter(u) || u.properties.numericType != nil && u.value < 0x250 ? .latin : .other
    }

    /// Substring match that does not cut into a longer katakana run or Latin word (ルーク in ルークス, Mira in Miranda).
    static func contains(_ text: String, _ term: String) -> Bool {
        guard let first = term.unicodeScalars.first, let last = term.unicodeScalars.last else { return false }
        let scalars = text.unicodeScalars
        var from = text.startIndex
        while from < text.endIndex, let r = text.range(of: term, options: .literal, range: from..<text.endIndex) {
            let c0 = edgeClass(first), c1 = edgeClass(last)
            let beforeOK = r.lowerBound == text.startIndex || c0 == .other
                || edgeClass(scalars[scalars.index(before: r.lowerBound)]) != c0
            let afterOK = r.upperBound == text.endIndex || c1 == .other || edgeClass(scalars[r.upperBound]) != c1
            if beforeOK && afterOK { return true }
            from = r.lowerBound < text.endIndex ? text.index(after: r.lowerBound) : text.endIndex
        }
        return false
    }
}

/// Katakana to Hangul by the usual Korean convention for Japanese loanword names, enough to recognise
/// a translated name. Per kana a word-initial and a later form: カ행/タ행 voiced at the start
/// (カ가 タ다 チ지 ツ쓰) and aspirated after it (카 타 치 츠, ト토, ク크); the u-row of stops takes ㅡ (グ그 ブ브 プ프 ズ즈 ク크).
/// ー is dropped, ッ becomes a ㅅ final and ン a ㄴ final of the syllable before. ャュョ turn the syllable
/// into ㅑㅠㅛ (シャ샤, but ジャ자 チャ차), small ァィゥェォ replace its vowel (フィ피 ティ티 ウィ위).
/// So シャーロット -> 샤롯토 (not 샤로트): ッ always closes the syllable before it, and ト keeps its o.
public enum KanaHangul {
    public static func transliterate(_ katakana: String) -> String { render(katakana, lateralFinal: false) }

    /// The strict form plus one loanword variant in which ル before a consonant kana is a ㄹ final
    /// (エルフィーナ -> 엘피나; strictly 에루피나), which is how translators usually write such names.
    public static func variants(_ katakana: String) -> [String] {
        let a = render(katakana, lateralFinal: false), b = render(katakana, lateralFinal: true)
        return a == b ? [a] : [a, b]
    }

    private typealias Jamo = (l: Int, v: Int, t: Int)

    private static let table: [Character: (initial: Jamo, medial: Jamo)] = {
        let spec = """
        ア 아,イ 이,ウ 우,エ 에,オ 오,カ 가/카,キ 기/키,ク 구/크,ケ 게/케,コ 고/코,ガ 가,ギ 기,グ 그,ゲ 게,ゴ 고,\
        サ 사,シ 시,ス 스,セ 세,ソ 소,ザ 자,ジ 지,ズ 즈,ゼ 제,ゾ 조,タ 다/타,チ 지/치,ツ 쓰/츠,テ 데/테,ト 도/토,\
        ダ 다,ヂ 지,ヅ 즈,デ 데,ド 도,ナ 나,ニ 니,ヌ 누,ネ 네,ノ 노,ハ 하,ヒ 히,フ 후,ヘ 헤,ホ 호,\
        バ 바,ビ 비,ブ 브,ベ 베,ボ 보,パ 파,ピ 피,プ 프,ペ 페,ポ 포,マ 마,ミ 미,ム 무,メ 메,モ 모,\
        ヤ 야,ユ 유,ヨ 요,ラ 라,リ 리,ル 루,レ 레,ロ 로,ワ 와,ヲ 오,ヴ 브
        """
        var t: [Character: (Jamo, Jamo)] = [:]
        for entry in spec.split(separator: ",") {
            let kv = entry.split(separator: " ")
            let forms = kv[1].split(separator: "/").map { decompose($0.unicodeScalars.first!) }
            t[kv[0].first!] = (forms[0], forms.count > 1 ? forms[1] : forms[0])
        }
        return t
    }()

    private static func decompose(_ u: Unicode.Scalar) -> Jamo {
        let n = Int(u.value) - 0xAC00
        return (n / 588, n / 28 % 21, n % 28)
    }

    private static func compose(_ j: Jamo) -> Character {
        Character(Unicode.Scalar(UInt32(0xAC00 + (j.l * 21 + j.v) * 28 + j.t))!)
    }

    // L: ㄴ2 ㅅ9 ㅈ12 ㅊ14 ㅍ17 ㅎ18; V: ㅏ0 ㅔ5 ㅗ8 ㅛ12 ㅜ13 ㅠ17 ㅣ20 ㅑ2; T: ㄹ8 ㄴ4 ㅅ19.
    private static let yVowel: [Character: (plain: Int, y: Int)] = ["ャ": (0, 2), "ュ": (13, 17), "ョ": (8, 12)]
    private static let smallVowel: [Character: Int] = ["ァ": 0, "ィ": 20, "ゥ": 13, "ェ": 5, "ォ": 8]

    private static func render(_ s: String, lateralFinal: Bool) -> String {
        let chars = Array(s)
        var out: [Jamo] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            i += 1
            switch c {
            case "ー": continue
            case "ッ": if let last = out.indices.last, out[last].t == 0 { out[last].t = 19 }; continue
            case "ン":
                if let last = out.indices.last, out[last].t == 0 { out[last].t = 4 } else { out.append((11, 18, 4)) }
                continue
            default: break
            }
            guard let forms = table[c] else { continue }
            var j = out.isEmpty ? forms.initial : forms.medial
            if i < chars.count, let y = yVowel[chars[i]] {
                j.v = [12, 14].contains(j.l) ? y.plain : y.y
                i += 1
            } else if i < chars.count, let v = smallVowel[chars[i]] {
                if c == "フ" { j.l = 17 }
                j.v = c == "ウ" ? (v == 20 ? 16 : v == 5 ? 15 : v == 8 ? 14 : v) : v
                i += 1
            } else if lateralFinal, c == "ル", !out.isEmpty, out[out.count - 1].t == 0, i < chars.count,
                      table[chars[i]] != nil, !"アイウエオ".contains(chars[i]) {
                out[out.count - 1].t = 8
                continue
            }
            out.append(j)
        }
        return String(out.map(compose))
    }
}

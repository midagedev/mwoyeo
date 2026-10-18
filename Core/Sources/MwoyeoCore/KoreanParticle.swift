import Foundation

/// Korean particles take their form from the last sound of the word in front of them: 은/는, 이/가, 을/를, 과/와, (으)로.
/// A glossary target put in place of an English term needs the form of its own last syllable, not of the term it replaced.
public enum KoreanParticle {
    /// (after a final consonant, after a vowel). Longer forms come first so "이에요" is not read as "이".
    private static let pairs: [(consonant: String, vowel: String)] = [
        ("이라고", "라고"), ("이라는", "라는"), ("이에요", "예요"), ("이었", "였"),
        ("이랑", "랑"), ("이란", "란"), ("이나", "나"), ("이라", "라"),
        ("으로", "로"), ("은", "는"), ("이", "가"), ("을", "를"), ("과", "와"),
    ]

    private static let rieul = 8

    /// The final consonant (0 for none, 8 for ㄹ) of the last Hangul syllable of `word`; nil when `word` ends in anything else.
    public static func finalConsonant(of word: String) -> Int? {
        guard let last = word.unicodeScalars.last, (0xAC00...0xD7A3).contains(last.value) else { return nil }
        return Int(last.value - 0xAC00) % 28
    }

    /// Whether the particle that starts `rest` (written right after the word, no space between) is the form the word's last
    /// sound asks for. nil when `rest` starts with no particle, or `word` does not end in a Hangul syllable.
    public static func agrees(_ rest: String, with word: String) -> Bool? {
        guard let jong = finalConsonant(of: word), let (index, isConsonantForm) = leading(in: rest) else { return nil }
        return isConsonantForm == asksConsonantForm(pairs[index], jong)
    }

    /// `rest` with the particle at its start (if any) in the form `word` asks for.
    public static func agree(_ rest: String, with word: String) -> String {
        guard let jong = finalConsonant(of: word), let (index, isConsonantForm) = leading(in: rest) else { return rest }
        let pair = pairs[index]
        let wantConsonant = asksConsonantForm(pair, jong)
        guard wantConsonant != isConsonantForm else { return rest }
        let old = isConsonantForm ? pair.consonant : pair.vowel
        return (wantConsonant ? pair.consonant : pair.vowel) + rest.dropFirst(old.count)
    }

    /// 으로 becomes 로 after ㄹ as well as after a vowel; every other particle only after a vowel.
    private static func asksConsonantForm(_ pair: (consonant: String, vowel: String), _ jong: Int) -> Bool {
        pair.consonant == "으로" ? jong != 0 && jong != rieul : jong != 0
    }

    /// What may follow a particle that is not the end of a word: "로서", "이도", "를만".
    private static let continuations = ["는", "도", "만", "의", "서", "써", "부터", "까지", "조차", "마저", "보다", "처럼", "에서", "에게"]

    /// The pair `rest` starts with, and whether it starts with the consonant form. The longest form wins, and it must end the
    /// word: "이다" and "나눈" start with 이 and 나 without holding a particle.
    private static func leading(in rest: String) -> (Int, Bool)? {
        var candidates: [(index: Int, consonant: Bool, form: String)] = []
        for (i, p) in pairs.enumerated() {
            if rest.hasPrefix(p.consonant) { candidates.append((i, true, p.consonant)) }
            if rest.hasPrefix(p.vowel) { candidates.append((i, false, p.vowel)) }
        }
        for c in candidates.sorted(by: { $0.form.count > $1.form.count }) {
            let after = rest.dropFirst(c.form.count)
            guard let next = after.unicodeScalars.first, (0xAC00...0xD7A3).contains(next.value) else { return (c.index, c.consonant) }
            if continuations.contains(where: { after.hasPrefix($0) }) { return (c.index, c.consonant) }
        }
        return nil
    }

    /// What may stand after a word besides the pairs above ("서울에서는", "모델의", "토큰들은").
    private static let trailing: [String] = {
        var all = pairs.flatMap { [$0.consonant, $0.vowel] }
        all += ["에서는", "에서도", "에서", "에는", "에도", "에게는", "에게", "에", "의", "도", "만", "까지", "부터", "보다", "처럼", "조차", "마저",
                "로서", "으로서", "로써", "으로써", "와의", "과의", "로의", "으로의"]
        return all.sorted { $0.count > $1.count }
    }()

    /// Where the word ends in `text` when the engine's rendering of a term and the particle it attached ("토큰으로", "모델에 ",
    /// "레이어들은") stand together: the offset (in Characters) before the trailing space, punctuation, particle and plural 들.
    /// The whole text when it holds no particle. Never 0 for a non-empty text: the word keeps at least one Character.
    public static func wordEnd(in text: String) -> Int {
        let t = Array(text)
        var end = t.count
        while end > 1, t[end - 1].isWhitespace || ".,!?;:".contains(t[end - 1]) { end -= 1 }
        let word = String(t[..<end])
        for p in trailing where word.hasSuffix(p) && end - p.count >= 1 {
            end -= p.count
            break
        }
        if end > 1, t[end - 1] == "들" { end -= 1 }
        return end
    }
}

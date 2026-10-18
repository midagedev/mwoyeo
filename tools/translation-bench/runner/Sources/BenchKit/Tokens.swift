import Foundation

/// A script-aware token estimate, within about 30 % of a real tokenizer; `score.est_tokens` is the same rule.
/// One token per Hangul, kana or Han character, a quarter per ASCII letter or digit, none for whitespace, a half
/// for other marks. The run calibrates it per request against the usage the engine reports.
public enum Tokens {
    public static func estimate(_ text: String) -> Double {
        var t = 0.0
        for u in text.unicodeScalars {
            let o = u.value
            if u.properties.isWhitespace { continue }
            if (0xAC00...0xD7A3).contains(o) || (0x3040...0x30FF).contains(o) || (0x3400...0x9FFF).contains(o)
                || (0xF900...0xFAFF).contains(o) || (0x3131...0x318E).contains(o) {
                t += 1
            } else if o < 128 && ((o >= 48 && o <= 57) || (o >= 65 && o <= 90) || (o >= 97 && o <= 122)) {
                t += 0.27
            } else {
                t += 0.5
            }
        }
        return t
    }
}

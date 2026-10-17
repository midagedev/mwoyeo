import Foundation

/// Checks on a finished translation, shared by every engine (Apple included).
public enum TranslationCheck {
    /// True when the engine handed the line back instead of translating it: the translation equals the source, or
    /// the target is Korean, Japanese or Chinese, the source's script dominates it (under half of its letters are
    /// target-script) and the translation's target-script share is no higher than the source's. A line with no
    /// letters (numbers, emoji) is never flagged. A name kept on purpose is not flagged either: a Latin line with a
    /// digit or an inner capital (`iPhone 17 Pro`) is a brand, and a brand inside a longer ko line raises the share.
    /// Limits: Japanese and Chinese share Han, so an unchanged ja to zh line shows only as an equal string; a plain
    /// capitalised name echoed unchanged (`Hello World`) is flagged, a one-word brand without digit or inner capital is too.
    public static func isUntranslated(source: String, translation: String, target: String) -> Bool {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.contains(where: \.isLetter) else { return false }
        if s == t { return !looksLikeBrand(s) }
        guard let script = Script(target: target) else { return false }
        let sourceShare = share(of: s, in: script)
        return sourceShare < 0.5 && share(of: t, in: script) <= sourceShare + 0.0001
    }

    private static func looksLikeBrand(_ s: String) -> Bool {
        guard s.unicodeScalars.allSatisfy({ $0.isASCII }) else { return false }
        let words = s.split(separator: " ")
        guard words.count <= 4 else { return false }
        return s.contains(where: \.isNumber) || words.contains { $0.dropFirst().contains(where: \.isUppercase) }
    }

    /// Hangul conjoining jamo that stand alone become compatibility jamo (`ᄏᄏ` to `ㅋㅋ`); a jamo inside a
    /// syllable block, and everything else, is unchanged. The text is NFC first.
    public static func displayForm(_ text: String) -> String {
        let scalars = Array(text.precomposedStringWithCanonicalMapping.unicodeScalars)
        var out = String.UnicodeScalarView()
        for (i, u) in scalars.enumerated() {
            if (0x1100...0x1112).contains(u.value) {
                let next = i + 1 < scalars.count ? scalars[i + 1].value : 0
                if !(0x1161...0x1175).contains(next), let c = compatibility[u.value] { out.append(c); continue }
            }
            out.append(u)
        }
        return String(out)
    }

    /// U+1100...U+1112 (choseong) to U+3131... in the order Unicode lists the compatibility letters.
    private static let compatibility: [UInt32: Unicode.Scalar] = {
        let compat: [UInt32] = [0x3131, 0x3132, 0x3134, 0x3137, 0x3138, 0x3139, 0x3141, 0x3142, 0x3143, 0x3145,
                                0x3146, 0x3147, 0x3148, 0x3149, 0x314A, 0x314B, 0x314C, 0x314D, 0x314E]
        return Dictionary(uniqueKeysWithValues: zip(0x1100...0x1112, compat).compactMap { k, v in
            Unicode.Scalar(v).map { (k, $0) }
        })
    }()

    private enum Script {
        case hangul, kana, han
        init?(target: String) {
            switch target.lowercased().prefix(2) {
            case "ko": self = .hangul
            case "ja": self = .kana
            case "zh": self = .han
            default: return nil
            }
        }
        func contains(_ v: UInt32) -> Bool {
            let han = (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
            switch self {
            case .hangul: return (0xAC00...0xD7A3).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v)
            case .kana: return (0x3040...0x30FF).contains(v) || han
            case .han: return han
            }
        }
    }

    private static func share(of text: String, in script: Script) -> Double {
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return 1 }
        return Double(letters.filter { script.contains($0.value) }.count) / Double(letters.count)
    }
}

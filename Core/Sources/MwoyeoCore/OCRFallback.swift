import Foundation

/// The recognizers the app reads with, through the Objective-C `VNRecognizeTextRequest` (the Swift requests are not used:
/// they can stall the whole process, see tools/ocr-probe). On macOS 27 its newest model, accurate revision 3, can stall
/// (its compile hangs or crawls) while the older ones still answer: revision 3 reads everything the app needs, revision 2 a
/// handful of languages, `.fast` a few Latin ones. The ladder lists the rungs that read the languages, best first.
public enum OCRFallback: Equatable, Sendable {
    /// Accurate revision 3 through the Objective-C request, restricted to these of its own identifiers. Empty: let it
    /// detect the language.
    case vision3([String])
    /// Accurate revision 2, likewise.
    case revision2([String])
    /// The fast recognizer, likewise.
    case fast([String])

    /// `requested` are the app's language identifiers ("ja", "zh-Hans", "pt-BR"; empty means any language); the rest are
    /// what each recognizer's `supportedRecognitionLanguages()` returns ("en-US", "zh-Hans"). A rung is on the ladder
    /// only if it reads every requested language: reading one of two would silently drop the other's text. Empty result:
    /// nothing else reads them.
    public static func ladder(requested: [String], vision3: [String], revision2: [String], fast: [String]) -> [OCRFallback] {
        let rungs: [(([String]) -> OCRFallback, [String])] = [(OCRFallback.vision3, vision3), (OCRFallback.revision2, revision2), (OCRFallback.fast, fast)]
        return rungs.compactMap { make, supported in
            if requested.isEmpty { return supported.isEmpty ? nil : make([]) }
            return identifiers(for: requested, in: supported).map(make)
        }
    }

    /// The `supported` identifier for each requested language (duplicates dropped), or nil if one has none.
    static func identifiers(for requested: [String], in supported: [String]) -> [String]? {
        var out: [String] = []
        for want in requested {
            guard let id = supported.first(where: { matches(want, $0) }) else { return nil }
            if !out.contains(id) { out.append(id) }
        }
        return out
    }

    /// Same language; the region never matters ("en" reads "en-US"), the script does when both name one, so "zh-Hans"
    /// does not read as "zh-Hant".
    static func matches(_ requested: String, _ supported: String) -> Bool {
        let w = Locale.Language(identifier: requested), s = Locale.Language(identifier: supported)
        guard let code = w.languageCode, code == s.languageCode else { return false }
        if let ws = w.script, let ss = s.script { return ws == ss }
        return true
    }
}

import Foundation
#if canImport(MwoyeoCore)
import MwoyeoCore
#endif
import Translation

/// `ProtectedSpans` as an Apple Translation request and back. A span's range carries its marker as a link, and a formula's is
/// also marked `skipsTranslation` (a glossary term's is not, unless `skipsGlossary`: see `ProtectedSpans`); the answer's runs that
/// carry a marker are the spans the engine gave back. Only `translate(_:)` returns them: a batch response has no attributed text.
/// (The glossary probe compiles this file with the Core sources, hence the guarded import.)
@available(macOS 26.4, *)
extension ProtectedSpans {
    func attributedSource(skipsGlossary: Bool = false) -> AttributedString {
        var a = AttributedString(source)
        for span in spans {
            let lo = a.index(a.startIndex, offsetByCharacters: span.range.lowerBound)
            let hi = a.index(a.startIndex, offsetByCharacters: span.range.upperBound)
            if span.isMath || skipsGlossary { a[lo..<hi].translation.skipsTranslation = true }
            a[lo..<hi].link = markerURL(span)
        }
        return a
    }

    /// The text of an answer and its marked runs, in order.
    static func answer(_ attributed: AttributedString) -> (text: String, runs: [Run]) {
        var runs: [Run] = []
        for run in attributed.runs {
            if let url = run.link, let marker = marker(of: url) {
                runs.append(Run(marker: marker, text: String(attributed[run.range].characters)))
            }
        }
        return (String(attributed.characters), runs)
    }
}

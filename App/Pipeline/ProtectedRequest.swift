import Foundation
import MwoyeoCore
import Translation

/// `ProtectedSpans` as an Apple Translation request and back. A span's range carries its marker as a link and is marked
/// `skipsTranslation`; the answer's runs that carry a marker are the spans the engine gave back. Only `translate(_:)` returns
/// them: a batch response has no attributed text.
@available(macOS 26.4, *)
extension ProtectedSpans {
    func attributedSource() -> AttributedString {
        var a = AttributedString(source)
        for span in spans {
            let lo = a.index(a.startIndex, offsetByCharacters: span.range.lowerBound)
            let hi = a.index(a.startIndex, offsetByCharacters: span.range.upperBound)
            a[lo..<hi].translation.skipsTranslation = true
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

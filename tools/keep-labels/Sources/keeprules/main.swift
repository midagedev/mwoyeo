import Foundation
import MwoyeoCore

// usage: keeprules <labels.jsonl>...        (stdout: one JSON line per block record)
// Today's Core rules run on the text of every labelled block, exactly as the app runs them on a block (TextRecognizer.verdict,
// TranslationService.translate, ProtectedSpans): InlineMath.spans, isFormula, isMathHeavy, isIdentifier, isLiteral, needsTranslation.
// {"id","spans":[[start,end]...] (Characters, as InlineMath counts), "formula","mathHeavy","identifier","literal","needs","share","signs"}
// `needs` is TranslationFilter.needsTranslation(text, cjkSource) with cjkSource true for a block whose "lang" is ko, ja or zh*.

func json(_ s: String) -> String {
    var o = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": o += "\\\""
        case "\\": o += "\\\\"
        default: o += u.value < 32 ? String(format: "\\u%04x", u.value) : String(u)
        }
    }
    return o + "\""
}

var out = ""
for path in CommandLine.arguments.dropFirst() {
    guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
        FileHandle.standardError.write(Data("cannot read \(path)\n".utf8)); exit(1)
    }
    for line in text.split(separator: "\n") {
        guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], obj["kind"] as? String == "block",
              let id = obj["id"] as? String, let t = obj["text"] as? String else { continue }
        let lang = obj["lang"] as? String ?? "en"
        let cjk = ["ja", "ko"].contains(lang) || lang.hasPrefix("zh")
        let spans = InlineMath.spans(in: t).map { "[\($0.range.lowerBound),\($0.range.upperBound)]" }.joined(separator: ",")
        let share = TranslationFilter.mathShare(of: t)
        out += "{\"id\":\(json(id)),\"spans\":[\(spans)],\"formula\":\(TranslationFilter.isFormula(t)),\"mathHeavy\":\(TranslationFilter.isMathHeavy(t)),"
            + "\"identifier\":\(TranslationFilter.isIdentifier(t)),\"literal\":\(TranslationFilter.isLiteral(t)),"
            + "\"needs\":\(TranslationFilter.needsTranslation(t, cjkSource: cjk)),\"share\":\(String(format: "%.3f", share.share)),\"signs\":\(share.signs)}\n"
    }
}
FileHandle.standardOutput.write(Data(out.utf8))

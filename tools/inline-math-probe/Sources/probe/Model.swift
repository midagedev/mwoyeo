// The OCR answers (written by `read`), the blocks the app makes of them, and the word boxes of each InlineMath span.
import CoreGraphics
import Foundation
import MwoyeoCore

struct JWord: Codable { var x, y, w, h: Double; var s, e: Int }
struct JLine: Codable {
    var x, y, w, h: Double
    var text: String
    var words: [JWord]
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}
struct JPage: Codable { var path, page: String; var width, height: Int; var seconds: Double; var paragraphs: [[JLine]] }

func isCJK(_ c: Character) -> Bool {
    c.unicodeScalars.contains { s in
        (0x3040...0x30FF).contains(s.value) || (0x3400...0x9FFF).contains(s.value) || (0xF900...0xFAFF).contains(s.value) ||
            (0xFF00...0xFFEF).contains(s.value) || (0x3000...0x303F).contains(s.value)
    }
}

/// `TextRecognizer.makeBlock`: the lines' text joined by a space (none after a hyphen, none beside CJK); `base[i]` is the
/// Character offset of line i in `text`.
struct Block {
    var lines: [JLine]
    var text: String
    var base: [Int]

    init(_ lines: [JLine]) {
        var text = "", n = 0
        var base: [Int] = []
        for line in lines {
            if let last = text.last, let first = line.text.first, !(isCJK(last) || isCJK(first)) {
                let sep = last == "-" ? "" : " "
                text += sep
                n += sep.count
            }
            base.append(n)
            text += line.text
            n += line.text.count
        }
        self.lines = lines; self.text = text; self.base = base
    }
}

/// The blocks of a page as the app makes them: a document read is its paragraphs; lines are grouped by `ParagraphGrouper`.
func blocks(of page: JPage) -> [Block] {
    if page.path == "docs" { return page.paragraphs.map(Block.init) }
    let lines = page.paragraphs.flatMap { $0 }
    return ParagraphGrouper.groups(lines, rect: \.rect, text: \.text).map(Block.init)
}

/// A span with the boxes of the words it covers.
struct SpanWords {
    var block: Int
    var text: String
    var range: Range<Int>
    /// The line it lies on (nil: it crosses lines).
    var line: JLine?
    var words: [JWord]
    /// Trailing ".,;:!?" characters of the last word that the span leaves out.
    var trailing: [Character]
    var cross: Bool
    var noBox: Bool
}

func spans(of block: Block, index: Int) -> [SpanWords] {
    let chars = Array(block.text)
    var out: [SpanWords] = []
    for span in InlineMath.spans(in: block.text) {
        var covered: [(line: Int, word: JWord)] = []
        for (i, line) in block.lines.enumerated() {
            for w in line.words where block.base[i] + w.s < span.range.upperBound && block.base[i] + w.e > span.range.lowerBound {
                covered.append((i, w))
            }
        }
        let text = String(chars[span.range])
        let lineIdx = Set(covered.map(\.line))
        var trailing: [Character] = []
        if let last = covered.last {
            let end = block.base[last.line] + last.word.e
            if end > span.range.upperBound { trailing = Array(chars[span.range.upperBound..<min(end, chars.count)]) }
        }
        out.append(SpanWords(block: index, text: text, range: span.range, line: lineIdx.count == 1 ? block.lines[lineIdx.first!] : nil,
                             words: covered.map(\.word), trailing: trailing, cross: lineIdx.count > 1, noBox: covered.isEmpty))
    }
    return out
}

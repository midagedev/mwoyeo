import CoreGraphics
import Foundation

/// Lines of recognized text → paragraphs, by layout alone. The Objective-C `VNRecognizeTextRequest` returns lines; the Swift
/// document request that grouped them is not used any more (it can stall the whole process, see tools/ocr-probe), so the
/// grouping is done here. Rects are image pixels, top-left origin, as `OCRLine` has them.
///
/// A line continues the paragraph whose last line is `previous` when all of these hold (heights are the taller of the two):
/// - it is not a list item (a bullet or a number starts a block of its own);
/// - the line heights are alike (`maxHeightRatio`): a heading and the text under it are two blocks;
/// - it sits just below: the gap between the boxes is at most `maxGap` heights, and at least `-maxOverlap` (boxes of
///   neighbouring lines overlap a little; a line beside another overlaps it by a whole height and is not "below");
/// - it is in the same column: the left edges are within `column` heights (a hanging indent still counts), or the lines
///   are centred: their centres are within `centred` heights (subtitles).
/// When several paragraphs could take the line, the one with the smallest gap and offset takes it.
///
/// Measured on Vision's line boxes (macOS 27, accurate revision 3): a box is as tall as its glyphs, so the last line of a
/// wrapped English paragraph ("game") is up to 1.45 times shorter than the lines above it. A tolerance of ±25 % on the
/// height would cut such lines off; the height rule only has to tell a heading from text.
public enum ParagraphGrouper {
    /// Taller line / shorter line, at most.
    static let maxHeightRatio = 1.5
    /// Gap between a line's box and the next one's, in heights.
    static let maxGap = 0.6
    /// How far two boxes of neighbouring lines may overlap, in heights.
    static let maxOverlap = 0.4
    /// How far the left edges of lines of one column may differ, in heights: a list item's hanging indent is a marker and a
    /// space wide, 1.1 heights on a Japanese list.
    static let column = 1.25
    /// How far the centres of centred lines may differ, in heights.
    static let centred = 0.5

    /// The lines grouped into paragraphs, each in reading order, the paragraphs by the top of their first line.
    public static func groups<T>(_ lines: [T], rect: (T) -> CGRect, text: (T) -> String) -> [[T]] {
        let order = lines.indices.sorted {
            let a = rect(lines[$0]), b = rect(lines[$1])
            return a.minY != b.minY ? a.minY < b.minY : a.minX < b.minX
        }
        var paragraphs: [[Int]] = []
        for i in order {
            var best: (paragraph: Int, cost: Double)?
            for (p, members) in paragraphs.enumerated() {
                guard let cost = continuation(of: rect(lines[members[members.count - 1]]), by: rect(lines[i]), text: text(lines[i])),
                      best.map({ cost < $0.cost }) ?? true else { continue }
                best = (p, cost)
            }
            if let best { paragraphs[best.paragraph].append(i) } else { paragraphs.append([i]) }
        }
        return paragraphs.map { $0.map { lines[$0] } }
    }

    /// How well the line `next` (with this `text`) continues a paragraph that ends with `previous`, in heights (smaller is
    /// better); nil if it does not.
    static func continuation(of previous: CGRect, by next: CGRect, text: String) -> Double? {
        let tall = max(previous.height, next.height), short = min(previous.height, next.height)
        guard short > 0, tall / short <= maxHeightRatio, !startsListItem(text) else { return nil }
        let gap = next.minY - previous.maxY
        guard gap >= -maxOverlap * tall, gap <= maxGap * tall else { return nil }
        let left = abs(next.minX - previous.minX), centre = abs(next.midX - previous.midX)
        let offset = min(left <= column * tall ? left : .infinity, centre <= centred * tall ? centre : .infinity)
        guard offset.isFinite else { return nil }
        return (max(gap, 0) + offset) / tall
    }

    private static let bullets: Set<Character> = ["•", "·", "・", "●", "○", "◦", "▪", "▫", "■", "□", "◆", "◇", "▶", "►", "‣", "⁃", "※", "＊"]
    private static let dashes: Set<Character> = ["-", "–", "—", "*", "+"]

    /// A line that opens a list item: a bullet, a number ("1.", "2)", "(3)", circled) or a note mark. A dash or an asterisk
    /// counts only as a word of its own ("- item"; not "-1" or "*args"), and a number followed by a digit is a decimal
    /// ("3.14 million") that a paragraph wrapped in front of, not a marker.
    static func startsListItem(_ text: String) -> Bool {
        let s = text.drop(while: \.isWhitespace)
        guard let first = s.first else { return false }
        if bullets.contains(first) { return true }
        if dashes.contains(first) { return s.dropFirst().first?.isWhitespace ?? true }
        if let scalar = first.unicodeScalars.first, (0x2460...0x24FF).contains(scalar.value) || (0x3220...0x3243).contains(scalar.value) {
            return true   // ① … ⑳, ⒈, ㈠
        }
        if first == "(" || first == "（" {
            let inner = s.dropFirst().prefix { $0.isASCII && $0.isNumber }
            return (1...3).contains(inner.count) && ")）".contains(s.dropFirst(1 + inner.count).first ?? " ")
        }
        let digits = s.prefix { $0.isASCII && $0.isNumber }
        guard (1...3).contains(digits.count), let mark = s.dropFirst(digits.count).first, ".)．、）".contains(mark) else { return false }
        let after = s.dropFirst(digits.count + 1).first
        return !(after?.isASCII == true && after?.isNumber == true)
    }
}

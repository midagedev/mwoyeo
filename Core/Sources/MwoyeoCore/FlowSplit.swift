import Foundation

/// One piece of a paragraph that goes on in the next column (`ColumnBreak`). The pieces of one paragraph share its text, so the
/// paragraph is translated once; each piece draws its share (`FlowSplit.share`).
public struct FlowPart: Sendable, Equatable {
    /// The pieces of one paragraph have one group number.
    public var group: Int
    /// This piece's place among them, and how many there were when the paragraph was cut.
    public var index: Int
    public var count: Int
    /// The characters of each piece's source lines, once `FlowSplit.resolve` has seen that the paragraph is whole; empty before.
    public var weights: [Int] = []

    public init(group: Int, index: Int, count: Int, weights: [Int] = []) {
        self.group = group
        self.index = index
        self.count = count
        self.weights = weights
    }
}

/// One translation, painted in the pieces of a paragraph that continues across a column break: piece k gets the text between the
/// cut after the share `Σ w[0...k]` of the characters and the cut before it. A cut lands on the nearest space within `window`
/// characters (the cut falls after the space); text with no space near it (Han, kana, hangul without spaces) is cut at the nearest
/// character that neither starts with a closing mark nor follows an opening one. Pure: the pieces joined with a space read as the
/// translation, whitespace aside. Design: docs/design/recognition.md section 11.
public enum FlowSplit {
    static let window = 12
    static let closing: Set<Character> = ["、", "。", "，", "．", "）", "」", "』", "】", "〉", "》", "!", "?", ")", "]", "}", ",", ".", ";", ":", "！", "？", "”", "’"]
    static let opening: Set<Character> = ["（", "「", "『", "【", "〈", "《", "(", "[", "{", "“", "‘"]

    /// Which of the blocks that came out of the pipeline's chain are still the pieces of a whole paragraph. `parts[i]` is block `i`'s
    /// part as `ColumnBreak` cut it (in reading order) and `characters[i]` the length of its own text. A paragraph whose pieces
    /// were not all kept in order (one merged with a neighbour, split by style, taken for a label) is a set of paragraphs of their
    /// own: its pieces come back nil. The others come back with their weights.
    public static func resolve(_ parts: [FlowPart?], characters: [Int]) -> [FlowPart?] {
        var members: [Int: [Int]] = [:]
        for (i, part) in parts.enumerated() { if let part { members[part.group, default: []].append(i) } }
        var out = parts
        for positions in members.values {
            let count = parts[positions[0]]?.count ?? 0
            let whole = positions.count == count && positions.enumerated().allSatisfy { parts[$0.element]?.index == $0.offset }
            let weights = positions.map { max(1, characters[$0]) }
            for p in positions { out[p] = whole ? parts[p].map { FlowPart(group: $0.group, index: $0.index, count: $0.count, weights: weights) } : nil }
        }
        return out
    }

    /// The share of `text` that piece `part` draws.
    public static func share(of text: String, part: FlowPart) -> String {
        let all = slices(text, weights: part.weights)
        return all.indices.contains(part.index) ? all[part.index] : text
    }

    public static func slices(_ text: String, weights: [Int]) -> [String] {
        let chars = Array(text)
        let total = max(1, weights.reduce(0, +))
        guard weights.count > 1, !chars.isEmpty else { return weights.isEmpty ? [text] : [text] + Array(repeating: "", count: weights.count - 1) }
        var cuts: [Int] = [0]
        var acc = 0
        for w in weights.dropLast() {
            acc += w
            let target = Int((Double(chars.count) * Double(acc) / Double(total)).rounded())
            cuts.append(max(cuts.last!, nearest(chars, to: target)))
        }
        cuts.append(chars.count)
        return (0..<weights.count).map { String(chars[cuts[$0]..<cuts[$0 + 1]]).trimmingCharacters(in: .whitespaces) }
    }

    private static func nearest(_ c: [Character], to t: Int) -> Int {
        let t = min(max(t, 0), c.count)
        for d in 0...window {
            for i in [t - d, t + d] where i > 0 && i < c.count && c[i - 1] == " " { return i }
        }
        for d in 0...window {
            for i in [t - d, t + d] where i > 0 && i < c.count && !closing.contains(c[i]) && !opening.contains(c[i - 1]) { return i }
        }
        return t
    }
}

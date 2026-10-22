import CoreGraphics
import Foundation

/// Code, terminal output, logs, config and diffs are not translated: they stay on screen as written. A block of text alone often does
/// not show that it is code (the document read cuts a listing into one-line blocks, "end if" and "# ~/.ledgerrc" mean nothing by
/// themselves), so this rule works on a region: the blocks of one read that sit together in one box, one indented run or one line-number
/// gutter. It reads the text and the geometry only; no model, no per-language word list (a comment in any script is code because of
/// where it sits). Measured in tools/keep-labels (docs/design/keep-boundary.md section 9).
///
/// Evidence is of two kinds. A *container* says the blocks belong together: a tint that differs from the frame's (a code box, a
/// terminal), an indented run, a line-number gutter, a comment line against the left edge of its neighbour. *Text* features say what
/// they hold: keywords, line ends `; { } ) ]`, symbols, a comment marker, a prompt, a hash-led line, diff marks, `key = value`, a
/// typeface of fixed pitch. The container alone keeps nothing (a callout box, a bullet list and a table are containers of prose); the
/// text alone keeps only when it is strong.
///
/// A row of a displayed equation is the other thing a page sets apart (`Reason.equation`): no region of blocks, one block that stands off the
/// text of its column and holds mathematics.
public enum CodeRegion {
    /// Why a block is kept. New kinds, apart from the math kinds of `ProtectedSpans.Kind`.
    public enum Reason: String, Sendable, Equatable {
        case code, terminal, log, config, diff
        /// A row of a displayed equation that holds a word of the page's language or one the recognizer made of its symbols: set off from the
        /// text on both sides, a sign of mathematics in it and at most one word of prose (`isEquationRow`).
        case equation
    }

    /// One word of a line with its box, as the reader placed it (a script it cannot place has no words).
    public struct Word: Sendable, Equatable {
        public var text: String
        public var rect: CGRect
        public init(text: String, rect: CGRect) {
            self.text = text
            self.rect = rect
        }
    }

    public struct Line: Sendable, Equatable {
        public var text: String
        public var rect: CGRect
        public var words: [Word]
        public init(text: String, rect: CGRect, words: [Word] = []) {
            self.text = text
            self.rect = rect
            self.words = words
        }
    }

    public struct Block: Sendable, Equatable {
        public var text: String
        public var rect: CGRect
        /// The recognised lines of the block, top to bottom; empty = the block is one line.
        public var lines: [Line]
        /// The background the app computes for the block (`TextAppearance.backgroundColor`; the median over its lines).
        public var background: RGBA

        public init(text: String, rect: CGRect, lines: [Line] = [], background: RGBA) {
            self.text = text
            self.rect = rect
            self.lines = lines
            self.background = background
        }
    }

    /// The constants, fitted on the dev sets of tools/keep-labels (cases k01 k03 k05 k07 k09 k11, papers 1706.03762 and 2401.10066).
    enum K {
        /// A block is tinted when its background differs from the frame's by this many levels in some channel.
        static let tint = 6
        /// Two stacked blocks are neighbours when the gap between them is at most this many line heights.
        static let gap = 1.5
        /// Side by side on one row: at most this many line heights apart.
        static let rowGap = 3.0
        /// A block is indented when its left edge lies this many line heights right of its column's margin.
        static let indent = 0.75
        /// The margin is looked for among blocks this many line heights above or below.
        static let marginReach = 25.0
        static let keywordCount = 1.5
        static let keywordShare = 0.2
        static let symbolShare = 0.15
        static let lineEndShare = 0.4
        /// A region of this many content blocks or more needs this share of them to show some text feature on their own.
        static let denseFrom = 4
        static let denseShare = 0.3
        /// A typeface of fixed pitch: the width per character of three ASCII words or more (three characters or more each) varies by less than
        /// this share of its mean, and those words are at least this share of all the words. H2 (round k3b, doc read): the variation 0.06 fires on
        /// 2 of 146 pure-translate blocks (1.4 %), 0.07 on 5 (3.4 %); the share separates prose with inline code (9 mixed blocks, 0.17 to 0.30,
        /// the chips are set in a fixed face) from output (184 keep blocks, 179 of them 0.5 and more, none between 0.34 and 0.5).
        static let pitchWords = 3
        static let pitchVariation = 0.06
        static let pitchShare = 0.5
        /// Blocks that can be measured: fewer say nothing (a garbled displayed equation of three words once looked fixed).
        static let pitchBlocks = 2
        /// An equation row (round d8keep, 2026-10-21). A block stands off the text when the margins of the body text (blocks of `bodyWords` words of two
        /// characters or more over its middle, within `marginReach`) lie this many of its line heights beyond it on each side: the displays of the method paper's
        /// windows stand 3.3 to 6.9 off, a paragraph's first line one em (0.7 to 1.0), a heading or a caption at the margin or centred with no sign.
        static let displayGap = 1.5
        static let bodyWords = 4
        /// A row holds a sign of mathematics and at most this many words of prose.
        static let equationSigns = 1
        static let equationProse = 1
        /// Lines of one shape (`name = value`, `"key": value`) that make a listing of settings, and not a label or two.
        static let listing = 3
        /// Two lines start on one left edge when their first glyphs are this many line heights apart at most. H2: the comment lines of a code run
        /// lie within 0.26 of their neighbours; a settings box inside a paragraph's margin lies at 0.66 (k01).
        static let edge = 0.3
    }

    /// Per block of one read: the reason it is kept as written, or nil (today's rules decide). `frameBackground` is the dominant
    /// background of the frame the blocks were read from.
    public static func keep(blocks: [Block], frameBackground: RGBA) -> [Reason?] {
        let (infos, groups) = regions(of: blocks, frameBackground: frameBackground)
        var out = [Reason?](repeating: nil, count: blocks.count)
        for members in groups {
            guard let reason = verdict(members.map { infos[$0] }) else { continue }
            for i in members { out[i] = reason }
        }
        for i in infos.indices where out[i] == nil && isEquationRow(infos[i]) { out[i] = .equation }
        return out
    }

    /// A row of a displayed equation: set off from the text of its column on both sides, a sign of mathematics in it and no more than a
    /// word of prose. The text alone cannot say: "ô = 1.4826 medianpering| l(p) - l|," holds a run of letters that reads as a word and
    /// "∨ prompt ∨ S ≥ 2 ∧ D(R)," holds one, and `TranslationFilter.isFormula` takes both for prose (D8, film3's A8: 5 of the 8 windows of
    /// the method paper that show a display redrew a row of it, translated). The place says what the text cannot; the sign keeps a heading,
    /// an author line or a caption, which stand off the margins as well, out of it. The number at the margin of a numbered display ("(7)")
    /// adds nothing the place does not say: it fired on 2 of the 4 rows and on no row of the labelled papers that the place missed.
    static func isEquationRow(_ b: Info) -> Bool {
        guard (b.gapLeft ?? 0) >= K.displayGap && (b.gapRight ?? 0) >= K.displayGap else { return false }
        return holdsMathNotProse(b.lines.joined(separator: " "))
    }

    /// A sign of mathematics and at most a word of prose: what the text of a row of a display holds. The one test of `isEquationRow` (a block) and
    /// of `DisplayRow` (a line the reader put into a paragraph).
    static func holdsMathNotProse(_ text: String) -> Bool {
        let shape = TranslationFilter.shape(of: text)
        return shape.signs >= K.equationSigns && shape.proseWords <= K.equationProse
    }

    /// The blocks with their geometry, and the regions they form: indices of the blocks that sit together in one box, one indented
    /// run or one line-number gutter (`Info.linked`). Apart from `keep` so that a probe can say why a block sits where it does.
    static func regions(of blocks: [Block], frameBackground: RGBA) -> (infos: [Info], groups: [[Int]]) {
        var infos = blocks.map { Info($0, frame: frameBackground) }
        let n = infos.count
        for i in 0..<n {
            var margin = infos[i].x0
            for c in infos where c.words >= 2 {
                guard abs(c.midY - infos[i].midY) <= K.marginReach * infos[i].lineHeight,
                      min(infos[i].x1, c.x1) > max(infos[i].x0, c.x0) else { continue }
                margin = min(margin, c.x0)
            }
            infos[i].indented = infos[i].x0 - margin >= K.indent * infos[i].lineHeight

            // The margins of the body text over its middle, in line heights: how far the block stands off it.
            let middle = (infos[i].x0 + infos[i].x1) / 2
            var left: Double?, right: Double?
            for (j, c) in infos.enumerated() where j != i && c.longWords >= K.bodyWords {
                // A block whose box holds the middle of this one is not its neighbour (two columns read as one paragraph).
                guard abs(c.midY - infos[i].midY) <= K.marginReach * infos[i].lineHeight, c.x0 <= middle, middle <= c.x1,
                      !(c.y0...c.y1).contains(infos[i].midY) else { continue }
                left = min(left ?? c.x0, c.x0)
                right = max(right ?? c.x1, c.x1)
            }
            infos[i].gapLeft = left.map { (infos[i].x0 - $0) / infos[i].lineHeight }
            infos[i].gapRight = right.map { ($0 - infos[i].x1) / infos[i].lineHeight }
        }

        var parent = Array(0..<n)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in 0..<n {
            for j in (i + 1)..<max(i + 1, n) where Info.linked(infos[i], infos[j]) { parent[find(i)] = find(j) }
        }
        var groups: [Int: [Int]] = [:]
        for i in 0..<n { groups[find(i), default: []].append(i) }
        return (infos, groups.values.sorted { $0[0] < $1[0] })
    }

    // MARK: - Geometry

    struct Info {
        var lines: [String]
        /// Whether its own words are set in a typeface of fixed pitch, nil when it has too few ASCII words to say; opening with a comment marker.
        var pitch: Bool?
        var lead: Bool
        var x0, y0, x1, y1, lineHeight: Double
        var tinted: Bool
        var background: RGBA
        var words: Int
        /// The words of two characters or more: the body text has four, a cell of mathematics ("O(k · n · d^2)") has two.
        var longWords: Int
        var gutter: Bool
        var indented = false
        /// How far the block stands off the body text of its column on each side, in its line heights; nil with no body text over its middle.
        var gapLeft: Double?
        var gapRight: Double?

        var midY: Double { (y0 + y1) / 2 }

        init(_ b: Block, frame: RGBA) {
            lines = b.lines.isEmpty ? [b.text] : b.lines.map(\.text)
            pitch = fixedPitch(b.lines.flatMap(\.words))
            lead = lines.first.map { l in commentMarkers.contains { l.drop(while: \.isWhitespace).hasPrefix($0) } } ?? false
            x0 = b.rect.minX; y0 = b.rect.minY; x1 = b.rect.maxX; y1 = b.rect.maxY
            let heights = (b.lines.isEmpty ? [b.rect.height] : b.lines.map(\.rect.height)).sorted()
            lineHeight = max(1, heights[heights.count / 2])
            tinted = Info.delta(b.background, frame) >= K.tint
            background = b.background
            let tokens = b.text.split(whereSeparator: \.isWhitespace)
            words = tokens.count
            longWords = tokens.filter { $0.count >= 2 }.count
            let joined = lines.joined(separator: " ")
            gutter = joined.wholeMatch(of: /\s*\d{1,3}\s*[:.]?\s*/) != nil || (lines.first?.firstMatch(of: /^\s*\d{1,3}:\s*\S/) != nil)
        }

        static func delta(_ a: RGBA, _ b: RGBA) -> Int {
            max(abs(Int(a.r) - Int(b.r)), abs(Int(a.g) - Int(b.g)), abs(Int(a.b) - Int(b.b)))
        }

        /// Neighbours (stacked within 1.5 line heights, or side by side on one row) that share a tint, an indent or a gutter, or that start
        /// on the left edge of a comment line.
        static func linked(_ a: Info, _ c: Info) -> Bool {
            let lh = min(a.lineHeight, c.lineHeight)
            let vgap = max(c.y0 - a.y1, a.y0 - c.y1)
            let sameRow = min(a.y1, c.y1) - max(a.y0, c.y0) > 0.5 * lh
            let hgap = max(c.x0 - a.x1, a.x0 - c.x1)
            let overlapX = min(a.x1, c.x1) > max(a.x0, c.x0)
            let near = (vgap <= K.gap * lh && !sameRow && overlapX) || (sameRow && hgap <= K.rowGap * lh)
            guard near else { return false }
            let edge = abs(a.x0 - c.x0) < K.edge * lh
            return (a.tinted && c.tinted && delta(a.background, c.background) <= K.tint)    // one box
                || (a.indented && c.indented)                                               // one indented run
                || ((a.lead || c.lead) && edge)                                             // a comment against the left edge of its neighbour
                || ((a.gutter || c.gutter) && sameRow) || (a.gutter && c.gutter)           // line numbers
        }
    }

    // MARK: - Text evidence

    static let strongKeywords: Set<String> = [
        "const", "let", "var", "func", "function", "def", "elif", "else", "end", "return", "import", "class", "while", "print", "console",
        "async", "await", "struct", "enum", "fn", "lambda", "include", "void", "bool", "char", "fi", "done", "echo", "null", "nil",
        "undefined", "typeof", "instanceof", "switch", "catch", "except", "raise", "throw", "extends", "implements", "namespace",
        "typedef", "println", "printf", "fileprivate", "init", "deinit", "typealias",
    ]
    /// Words of prose as well: they count only beside a strong keyword.
    static let weakKeywords: Set<String> = ["for", "if", "in", "to", "do", "then", "from", "true", "false", "public", "private", "protected", "override",
                                            "case", "static", "final", "guard", "extension", "protocol", "interface", "defer", "yield"]

    struct Features {
        var keyword = false, lineEnd = false, symbol = false, comment = false, prompt = false
        var log = false, diff = false, assignment = false
        /// Set in a typeface of fixed pitch (`fixedPitch`); three lines or more of one `name = value` shape (`assignmentShapes`).
        var mono = false, listing = false

        /// Evidence that holds by itself in a container.
        var strong: Int { [keyword, lineEnd, comment, prompt, log, diff, mono, listing].filter { $0 }.count }
        var all: Int { strong + [symbol, assignment].filter { $0 }.count }
    }

    static func features(of lines: [String], fixedPitch: Bool, tinted: Bool) -> Features {
        var f = Features()
        f.mono = fixedPitch
        let text = lines.joined(separator: " ")
        let tokens = text.matches(of: /[A-Za-z_][A-Za-z0-9_]*/).map { $0.output.lowercased() }
        let strongCount = tokens.filter { strongKeywords.contains($0) }.count
        let weakCount = tokens.filter { weakKeywords.contains($0) }.count
        f.keyword = strongCount >= 1 && Double(strongCount) + 0.5 * Double(weakCount) >= K.keywordCount
            && Double(strongCount + weakCount) / Double(tokens.count) >= K.keywordShare

        let ends = lines.compactMap { l -> Character? in
            let t = l.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.last
        }
        if !ends.isEmpty {
            let hits = ends.filter { ";{})]".contains($0) }.count
            f.lineEnd = Double(hits) / Double(ends.count) >= K.lineEndShare && ends.contains { ";{}".contains($0) }
        }

        let ascii = text.unicodeScalars.filter { $0.value >= 33 && $0.value < 127 }
        if ascii.count >= 6 {
            let symbols = ascii.filter { "{}[]()<>=;/\\|&*+~^$#@_".unicodeScalars.contains($0) }.count
            f.symbol = Double(symbols) / Double(ascii.count) >= K.symbolShare
        }

        f.comment = lines.contains { isCommentLine($0) || hasCommentAfterCode($0) }
        f.prompt = lines.contains(where: isPrompt)
        let logLines = lines.filter(isLogLine).count
        f.log = logLines >= 1 && lines.contains(where: { isHashLine($0) }) || logLines >= 2
        let plus = lines.filter { $0.firstMatch(of: /^\s*\+\s?\S/) != nil }.count
        let minus = lines.filter { $0.firstMatch(of: /^\s*-\s?\S/) != nil }.count
        // A line starting with + or - is also a displayed equation or a list: marks count as a diff only inside a tinted view.
        f.diff = lines.contains { $0.firstMatch(of: /^\s*@@/) != nil } || (tinted && plus >= 1 && minus >= 1)
        let shaped = lines.filter { l in assignmentShapes.contains { l.range(of: $0, options: .regularExpression) != nil } }.count
        f.assignment = shaped >= 1
        f.listing = shaped >= K.listing
        return f
    }

    /// A whole line that sets a name to a value, one pattern per shape.
    static let assignmentShapes = [
        #"^\s*[\w.\-\[\]]*[A-Za-z_][\w.\-\[\]]*\s*(?:=|:=|\+=|-=)\s*(?:"[^"]*"|'[^']*'|\S+)\s*[;,]?\s*$"#,                  // total = 2;  round_to = 2
        #"^\s*["'“”‘’][\w.\-]+["'“”‘’]\s*:\s*\S.*$"#,                                                                 // "key": value  (JSON; the reader's quotes drift)
        #"^\s*(?:[a-z_][\w.\-]*|[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)\s*:(?:\s+(?:"[^"]*"|'[^']*'|\[.*\]|\{.*\}|\S+))?\s*$"#,   // key: value  (YAML; a key is a name, not a label)
    ]

    /// Code, logs and terminals are set in a typeface of fixed pitch: every ASCII word is as wide as its characters times one width. nil
    /// when the block has too few such words, or too small a share of its words, to say (prose in another script, a label, a few chips).
    static func fixedPitch(_ boxes: [Word]) -> Bool? {
        let ascii = boxes.filter { $0.text.count >= 3 && $0.text.allSatisfy { $0.isASCII && $0 > " " } }
        guard ascii.count >= K.pitchWords, Double(ascii.count) >= K.pitchShare * Double(boxes.count) else { return nil }
        let widths = ascii.map { $0.rect.width / Double($0.text.count) }
        let mean = widths.reduce(0, +) / Double(widths.count)
        let spread = (widths.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(widths.count)).squareRoot()
        return spread < K.pitchVariation * mean
    }

    /// A line that opens with one of these sits against the left edge of the code it explains, in any script, with or without a space after the mark.
    static let commentMarkers = ["#", "//", "--", ";", "/*", "*"]

    static func isCommentLine(_ l: String) -> Bool {
        l.firstMatch(of: /^\s*(?:\/\/|\/\*|\*\/|--\s|#\s|#!|▶)/) != nil
    }

    /// `x = f(y) # comment`, `a;// note`, `mid ← lo ▶ note`: a marker after something that looks like code.
    static func hasCommentAfterCode(_ l: String) -> Bool {
        guard let m = l.firstMatch(of: /\s(?:#|\/\/|▶)\s*\S|[)\]}」;](?:#|\/\/|▶)\s*\S|\S▶\s*\S/) else { return false }
        let left = l[l.startIndex..<m.range.lowerBound]
        let marker = l[m.range]
        if marker.contains("▶") { return !left.trimmingCharacters(in: .whitespaces).isEmpty }
        return left.contains { "=←→(){};[]（）<>+*/".contains($0) }
    }

    static func isPrompt(_ l: String) -> Bool {
        l.firstMatch(of: /^\s*\$\s+[^\s\d]/) != nil                                          // "$ cd", not "$ 20 per month"
            || l.firstMatch(of: /^\s*\S+@\S+\s+\S+\s%\s+\S/) != nil                         // zsh's default: "dev@mbp ~ % ls"
            || l.firstMatch(of: /^\s*❯\s*\S/) != nil
            || l.firstMatch(of: /^\s*\S{0,40}[@:：~\/～]\S{0,40}[$#%]\s+\S/) != nil
            || l.firstMatch(of: /^\s*PS\s?\S*>\s*\S/) != nil
            || l.firstMatch(of: /^\s*>>>\s+\S/) != nil
    }

    static func isHashLine(_ l: String) -> Bool {
        guard let m = l.firstMatch(of: /^\s*([0-9a-f]{7,12})\s+\S/) else { return false }
        return m.output.1.contains { $0.isNumber }
    }

    /// A line of a log: a git log line, a timestamp or level prefix, a traceback frame.
    static func isLogLine(_ l: String) -> Bool {
        isHashLine(l)
            || l.firstMatch(of: /^\s*\[?\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}/) != nil
            || l.firstMatch(of: /^\s*\[?(?:INFO|WARN|WARNING|ERROR|DEBUG|TRACE|FATAL)\b/) != nil
            || l.firstMatch(of: /^\s*(?:Traceback|File\s+")/) != nil
    }

    // MARK: - The verdict of a region

    /// A long region needs text evidence (a feature, or a keyword) in a share of its blocks, so one stray `end` or `;` in a page-wide indented run keeps nothing.
    /// Gutter blocks (line numbers) carry no text and are left out of the count.
    static func hasDensity(_ members: [Info], tinted: Bool) -> Bool {
        let content = members.filter { !$0.gutter }
        guard content.count >= K.denseFrom else { return true }
        let withEvidence = content.filter { m in
            features(of: m.lines, fixedPitch: m.pitch == true, tinted: tinted).all >= 1
                || m.lines.joined(separator: " ").matches(of: /[A-Za-z_][A-Za-z0-9_]*/).contains { strongKeywords.contains($0.output.lowercased()) }
        }.count
        return Double(withEvidence) / Double(content.count) >= K.denseShare
    }

    /// What the text of a region says on its own: a terminal prompt, two strong features, or one with another beside it in a region of several blocks.
    static func textKeeps(_ f: Features, several: Bool) -> Bool {
        (several && f.strong >= 1 && f.all >= 2) || f.prompt || f.strong >= 2
    }

    /// Whether `lines`, the lines of one block of text with no boxes (typed or copied text), read as code, a log or a terminal: `verdict`'s clauses
    /// that need nothing but the text, and a log or a diff on its own (a region of boxes needs more, a block of text has nothing else to show it).
    static func readsAsCode(_ lines: [String]) -> Bool {
        let f = features(of: lines, fixedPitch: false, tinted: false)
        return textKeeps(f, several: lines.count > 1) || f.log || f.diff
    }

    static func verdict(_ members: [Info]) -> Reason? {
        let tinted = members.contains { $0.tinted }
        let measured = members.compactMap(\.pitch)       // two blocks or more can be measured, and every one of them is set in a fixed pitch
        let f = features(of: members.flatMap(\.lines), fixedPitch: measured.count >= K.pitchBlocks && !measured.contains(false), tinted: tinted)
        let container = tinted || (members.count > 1 && members.allSatisfy { $0.indented || $0.gutter })
        let weak = f.all - f.strong
        let keeps = (tinted && (f.strong >= 1 || weak >= 2))
            || (container && f.strong >= 1)
            || textKeeps(f, several: members.count > 1)
        guard keeps, hasDensity(members, tinted: tinted) else { return nil }
        if f.prompt { return .terminal }
        if f.diff { return .diff }
        if f.log { return .log }
        if f.assignment && !f.keyword && !f.lineEnd { return .config }
        return .code
    }

    // MARK: - What the app hands over

    /// The background of a block of several lines: the per-channel median of the backgrounds measured per line
    /// (`TextAppearance.backgroundColor`; the upper median of an even count). A box edge or a neighbour in the ring of one line moves
    /// that line's value, not the block's. Black when there is no line: the same value an unreadable crop gets.
    public static func background(ofLines lines: [RGBA]) -> RGBA {
        func median(_ v: [UInt8]) -> UInt8 { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        return RGBA(median(lines.map(\.r)), median(lines.map(\.g)), median(lines.map(\.b)))
    }
}

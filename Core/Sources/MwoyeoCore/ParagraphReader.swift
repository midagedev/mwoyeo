import CoreGraphics
import Foundation

/// Which recognizer turns the screen's text into paragraphs. `automatic` asks `ReaderDecider` for every lens; the other two are the
/// user's choice. A new meaning of its own, not the engine choice or the OCR path of the gates.
public enum ParagraphReader: String, Codable, CaseIterable, Sendable {
    /// Decided from the app in the lens and the layout of its text.
    case automatic
    /// The macOS document model (`RecognizeDocumentsRequest`): columns, tables, headings, short captions.
    case documentLayout
    /// The recognized lines grouped by our own rules (`ParagraphGrouper`): dialogue boxes, chat, small CJK text.
    case lineGrouping
}

/// What the decider knows about the lens apart from its text.
public struct ReaderContext: Equatable, Sendable {
    public var bundleID: String?
    /// `LSApplicationCategoryType` of the app, e.g. `public.app-category.games`.
    public var category: String?

    public init(bundleID: String? = nil, category: String? = nil) {
        self.bundleID = bundleID
        self.category = category
    }
}

/// A reader the decider settled on (never `automatic`) and why, for the trace.
public struct ReaderPick: Equatable, Sendable {
    public var reader: ParagraphReader
    public var reason: String
}

/// The layout of one frame's recognized lines (rects in image pixels, top-left origin).
public struct LineLayout: Equatable, Sendable {
    public var lineCount = 0
    /// Image width over height.
    public var aspect = 1.0
    /// Columns of text side by side (a gutter wider than `gutter` line heights with three lines or more on each side).
    public var columns = 1
    /// Share of lines that have a neighbour on the same row (table cells, key-value rows, side-by-side panels).
    public var rowMates = 0.0
    /// Lines in the lower part of the image that share a left edge with another such line: a text box (dialogue, a stats panel).
    public var lowAligned = 0
    /// Lines in the lower half whose centre is the image's centre: subtitles.
    public var centredLow = 0

    static let gutter = 1.5
    /// The lower part of the image starts at this share of its height.
    static let lowFrom = 0.6
    /// Left edges within this share of the image width are one edge; centres within it of the image's centre are centred.
    static let alignTolerance = 0.02, centreTolerance = 0.03

    public init() {}

    public init(lines: [CGRect], in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        aspect = size.width / size.height
        lineCount = lines.count
        guard !lines.isEmpty else { return }
        let median = lines.map(\.height).sorted()[lines.count / 2]
        columns = Self.columns(of: lines, gutter: Self.gutter * Double(median))
        let mated = lines.indices.filter { i in
            let a = lines[i]
            return lines.indices.contains { j in
                let b = lines[j], overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
                return j != i && overlap > 0.5 * min(a.height, b.height) && (b.minX >= a.maxX || a.minX >= b.maxX)
            }
        }.count
        rowMates = Double(mated) / Double(lines.count)
        let low = lines.filter { $0.minY > size.height * Self.lowFrom }
        lowAligned = low.filter { a in low.contains { $0 != a && abs($0.minX - a.minX) < size.width * Self.alignTolerance } }.count
        centredLow = lines.filter { abs($0.midX - size.width / 2) < size.width * Self.centreTolerance && $0.midY > size.height / 2 }.count
    }

    /// Segments of the x axis covered by lines, merged across gaps narrower than `gutter`; those that carry three lines or more.
    private static func columns(of lines: [CGRect], gutter: Double) -> Int {
        var segments: [(end: Double, count: Int)] = []
        for l in lines.sorted(by: { $0.minX < $1.minX }) {
            if var last = segments.last, Double(l.minX) - last.end <= gutter {
                last.end = max(last.end, Double(l.maxX)); last.count += 1
                segments[segments.count - 1] = last
            } else {
                segments.append((Double(l.maxX), 1))
            }
        }
        return max(1, segments.filter { $0.count >= 3 }.count)
    }
}

/// Which reader suits this lens: a pure function of the app and the layout of the frame's lines, fitted to the use-case set
/// (tools/usecase-bench, tuned on its odd-numbered pictures). `ReaderSwitcher` keeps the choice calm over frames.
///
/// Measured on 40 pictures: the document model reads structure (columns, title against authors, table cells, two-sentence
/// subtitles) and wins papers, pages and subtitles; the line grouping wins where text is a box of its own, left-aligned in the
/// lower part of a screen (visual-novel dialogue, a stats panel), because the document model cuts those at sentence ends.
public enum ReaderDecider {
    /// A picture as wide as a screen with no more lines than a game shows.
    static let screenAspect = 1.4, fewLines = 10

    public static func decide(_ layout: LineLayout, context: ReaderContext) -> ReaderPick {
        let facts = "columns=\(layout.columns) mates=\(Int((layout.rowMates * 100).rounded()))% lines=\(layout.lineCount)"
            + (context.category.map { " cat=\($0.replacingOccurrences(of: "public.app-category.", with: ""))" } ?? "")
        if let category = context.category, category.hasSuffix("games") {
            return ReaderPick(reader: .lineGrouping, reason: "game app: \(facts)")
        }
        if layout.aspect >= screenAspect, layout.lineCount <= fewLines, layout.lowAligned >= 2, layout.lowAligned > layout.centredLow {
            return ReaderPick(reader: .lineGrouping, reason: "text box low on a screen (aligned=\(layout.lowAligned) centred=\(layout.centredLow)): \(facts)")
        }
        if layout.columns >= 2 || layout.rowMates >= 0.4 {
            return ReaderPick(reader: .documentLayout, reason: "structure: \(facts)")
        }
        return ReaderPick(reader: .documentLayout, reason: "default: \(facts)")
    }
}

/// Keeps the decider's choice calm for one lens. The first frame takes the pick; after that the choice stays until the lens's
/// app changes, or the decider has picked the other reader on `framesToSwitch` frames in a row, each with a text of its own
/// (the same text read again is no new evidence). A frame that agrees with the choice starts the count over.
public struct ReaderSwitcher: Equatable, Sendable {
    public static let framesToSwitch = 3

    public private(set) var current: ReaderPick?
    private var app: String?
    private var against = 0
    private var lastAgainstText: Int?

    public init() {}

    /// The reader for this frame. `text` identifies the frame's recognized text (a hash is enough); `switched` tells the trace
    /// that the choice changed on this frame.
    public mutating func settle(_ pick: ReaderPick, app: String?, text: Int) -> (pick: ReaderPick, switched: Bool) {
        guard let held = current, app == self.app else {
            let first = current == nil
            current = pick
            self.app = app
            against = 0
            lastAgainstText = nil
            return (pick, !first)
        }
        if pick.reader == held.reader {
            against = 0
            lastAgainstText = nil
            return (held, false)
        }
        if lastAgainstText != text { against += 1 }
        lastAgainstText = text
        if against >= Self.framesToSwitch {
            current = pick
            against = 0
            lastAgainstText = nil
            return (pick, true)
        }
        return (held, false)
    }
}

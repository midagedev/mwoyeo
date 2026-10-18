import CoreGraphics
import Testing
@testable import MwoyeoCore

@Suite struct ReaderDeciderTests {
    private let screen = CGSize(width: 1920, height: 1080), page = CGSize(width: 1200, height: 1400)

    private func pick(_ lines: [CGRect], _ size: CGSize, _ context: ReaderContext = ReaderContext()) -> ParagraphReader {
        ReaderDecider.decide(LineLayout(lines: lines, in: size), context: context).reader
    }

    // Measured shapes (tools/usecase-bench, g01 and s01): a name tag and two left-aligned lines low on the screen; two centred lines.
    @Test func dialogueBoxLowOnAScreenIsLineGrouping() {
        let box = [CGRect(x: 167, y: 697, width: 131, height: 44), CGRect(x: 142, y: 778, width: 1225, height: 67), CGRect(x: 169, y: 853, width: 1144, height: 70)]
        #expect(pick(box, screen) == .lineGrouping)
    }

    @Test func centredSubtitlesAreTheDocumentModel() {
        let subtitle = [CGRect(x: 546, y: 823, width: 826, height: 78), CGRect(x: 585, y: 907, width: 748, height: 84)]
        #expect(pick(subtitle, screen) == .documentLayout)
        // A karaoke pair whose lines also happen to share a left edge stays a subtitle: centred wins.
        let karaoke = [CGRect(x: 357, y: 677, width: 1205, height: 106), CGRect(x: 357, y: 819, width: 1275, height: 64)]
        #expect(pick(karaoke, screen) == .documentLayout)
    }

    @Test func columnsAndTablesAreTheDocumentModel() {
        var twoColumns: [CGRect] = []
        for row in 0..<8 {
            twoColumns.append(CGRect(x: 100, y: 100 + row * 60, width: 460, height: 30))
            twoColumns.append(CGRect(x: 640, y: 100 + row * 60, width: 460, height: 30))
        }
        let layout = LineLayout(lines: twoColumns, in: page)
        #expect(layout.columns == 2 && layout.rowMates == 1)
        #expect(pick(twoColumns, page) == .documentLayout)
    }

    @Test func leftAlignedFooterOfAPageIsNotADialogueBox() {
        // The same alignment on a page-shaped picture, or among many lines, is not a game's text box.
        let footer = [CGRect(x: 100, y: 1300, width: 500, height: 30), CGRect(x: 100, y: 1340, width: 500, height: 30)]
        #expect(pick(footer, page) == .documentLayout)
        let busy = (0..<12).map { CGRect(x: 142, y: 700 + $0 * 30, width: 900, height: 24) }
        #expect(pick(busy, screen) == .documentLayout)
    }

    @Test func gameAppsAreLineGroupingWhateverTheLayout() {
        let page = [CGRect(x: 100, y: 100, width: 900, height: 30)]
        #expect(pick(page, self.page, ReaderContext(bundleID: "com.example.rpg", category: "public.app-category.role-playing-games")) == .lineGrouping)
        #expect(pick(page, self.page, ReaderContext(bundleID: "com.apple.Safari", category: "public.app-category.productivity")) == .documentLayout)
    }

    @Test func noTextIsHarmless() {
        #expect(pick([], screen) == .documentLayout)
        #expect(!ReaderDecider.decide(LineLayout(), context: ReaderContext()).reason.isEmpty)
    }
}

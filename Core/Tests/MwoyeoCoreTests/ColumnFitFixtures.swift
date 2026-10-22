import CoreGraphics
@testable import MwoyeoCore

/// The blocks of page 10 of our own paper (tools/paper-own/mwoyeo-method), as the paper bench's build of the D14 landing (dd652f0) read them:
/// every block's `core` (the union of its lines) in screen points (bench pixels at scale 2, halved) and its line count. The page is two columns of
/// justified text (the PDF's own columns stand at x 72.09..396.50 and 420.53..744.93 on screen); 35 blocks, 12 of them of two lines or more.
/// Source of the numbers: tools/lens-fit/data/eval1.txt (`probe/run-all.sh`, `data/paper-d14/p10.out`).
enum PaperPage10 {
    static let leftColumn = (left: 72.09 as CGFloat, right: 396.50 as CGFloat)
    static let rightColumn = (left: 420.53 as CGFloat, right: 744.93 as CGFloat)

    /// x0, y0, x1, y1, lines
    static let rows: [(CGFloat, CGFloat, CGFloat, CGFloat, Int)] = [
        (72, 77, 397.5, 105.5, 2),
        (72, 107.5, 344, 120.5, 1),
        (359.5, 107.5, 397, 118.5, 1),
        (420.5, 77, 746.5, 105.5, 3),
        (420.5, 107.5, 744.5, 133.5, 2),
        (85.5, 176, 189.5, 189, 1),
        (206.5, 176, 238.5, 187, 1),
        (214, 191.5, 238.5, 202.5, 1),
        (85.5, 204.5, 166.5, 217.5, 1),
        (206.5, 204.5, 238.5, 215.5, 1),
        (214, 220, 238.5, 231, 1),
        (85.5, 233, 168, 246, 1),
        (206.5, 235.5, 238.5, 246.5, 1),
        (214, 248.5, 238.5, 259.5, 1),
        (439.5, 154, 537, 167, 1),
        (439.5, 176, 530.5, 189, 1),
        (439, 189, 527.5, 202, 1),
        (439.5, 204.5, 534.5, 217.5, 1),
        (439.5, 220, 452, 231, 1),
        (72.5, 297, 397.5, 387, 6),
        (72.5, 411.5, 398.5, 444.5, 2),
        (71.5, 458, 398, 788, 21),
        (72.5, 790.5, 398, 855, 4),
        (71.5, 856.5, 398, 966.5, 7),
        (421, 266, 744.5, 279, 1),
        (421, 281.5, 746, 327.5, 3),
        (461.5, 350, 564.5, 365, 1),
        (420, 376.5, 745.5, 532.5, 10),
        (421.5, 559, 578, 576.5, 1),
        (421, 592, 746.5, 766, 11),
        (507, 788, 744.5, 801, 1),
        (420, 803.5, 746.5, 929, 8),
        (421, 949, 644, 962, 1),
        (659, 947.5, 744.5, 965, 1),
        (421, 964.5, 744.5, 979.5, 1),
    ]

    static var blocks: [ColumnFit.Block] {
        rows.map { ColumnFit.Block(core: CGRect(x: $0.0, y: $0.1, width: $0.2 - $0.0, height: $0.3 - $0.1), lines: $0.4) }
    }
}

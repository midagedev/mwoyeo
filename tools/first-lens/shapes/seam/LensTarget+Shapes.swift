import CoreGraphics
import Foundation

/// The seam between the reading column and the content shapes (docs/design/lens-shapes.md section 6, round shapes117). `choose` above gives
/// the column's target; where it has none, `fallback` may name a shape (`LensShape.choose`). Two owners take one pointer, so each lets go of
/// it only `switchBy` beyond where it would take it: a held column stays while the column rule would still take the pointer `switchBy` away
/// (whether the pointer is then over nothing, a shape or the next column), and a held shape stays until the column rule holds the pointer
/// `switchBy` deep. Under 2 pt of jitter the choice never goes A, B, A.
extension LensTarget {
    /// The shape at a pointer, given the shape held from the last choice (`LensShape.choose` over the read's `LensShape.Map`, `bounds` the same).
    public typealias Fallback = (_ pointer: CGPoint, _ held: LensShape.Shape?) -> LensShape.Shape?

    public static func choose(_ map: Map, pointer p: CGPoint, held: Target? = nil, bounds: CGRect, scale: CGFloat = 2, fallback: Fallback) -> Target? {
        let heldShape = held?.shape, heldColumn = held.flatMap { $0.shape == nil ? $0 : nil }
        func column(_ q: CGPoint) -> Target? { choose(map, pointer: q, held: heldColumn, bounds: bounds, scale: scale) }
        // The square of `switchBy` around a point: its four sides' middles and its corners (a pointer off a column's corner is `switchBy` away
        // only along both axes).
        func around(_ q: CGPoint) -> [CGPoint] {
            [-switchBy, 0, switchBy].flatMap { dx in [-switchBy, 0, switchBy].map { dy in CGPoint(x: q.x + dx, y: q.y + dy) } }.filter { $0 != q }
        }
        let here = column(p)
        if let heldShape {
            if let here, around(p).allSatisfy({ column($0) != nil }) { return here }
            return fallback(p, heldShape).map(Target.init(shape:)) ?? here
        }
        if let heldColumn, here?.column != heldColumn.column, around(p).contains(where: { column($0)?.column == heldColumn.column }) { return heldColumn }
        return here ?? fallback(p, nil).map(Target.init(shape:))
    }
}

extension LensTarget.Target {
    /// A content shape as the picker's target: its own rect, no column, its own anchor (the next choice's held anchor).
    public init(shape s: LensShape.Shape) { self.init(rect: s.rect, column: -1, anchor: s.anchor, shape: s) }
}

extension LensShape.Block {
    /// The read's block, as the column rule has it.
    public init(_ b: ColumnFit.Block) { self.init(core: b.core, lines: b.lines) }
}

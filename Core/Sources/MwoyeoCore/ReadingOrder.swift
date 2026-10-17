import Foundation

/// Reading order of text blocks on screen: top to bottom, and left to right within a row.
public enum ReadingOrder {
    /// A block joins the row of the first block above it when their tops differ by less than half the shorter height,
    /// so two blocks side by side with slightly different tops still read left to right.
    public static func sorted<T>(_ items: [T], frame: (T) -> CGRect) -> [T] {
        var rows: [[T]] = []
        var rowTop = 0.0, rowHeight = 0.0
        for item in items.sorted(by: { frame($0).minY < frame($1).minY }) {
            let f = frame(item)
            if !rows.isEmpty, f.minY - rowTop < 0.5 * min(rowHeight, f.height) {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
                rowTop = f.minY
                rowHeight = f.height
            }
        }
        return rows.flatMap { $0.sorted { frame($0).minX < frame($1).minX } }
    }
}

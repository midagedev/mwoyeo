import CoreGraphics

/// Where in the capture a pass has read (`OverlaySnapshot.read`, capture-local points): the rect Fit to Column judges a column's edge against (`ColumnFit.marked`: an edge that
/// stands at the read's edge is where the read ended, not where the column does).
public enum ReadArea {
    /// The rect of the capture that a pass which ended read. A pass reads the frame it was given, `frame` points across: the capture as it was when the frame was taken. The
    /// capture may have moved or been resized while the pass read (the pass is rebased: its results follow the content), `moves` are the offsets of the content since, in
    /// points, in order; the result is that frame carried along and cut to the capture as it is now (`capture`). Round edges117b, film4 F5: a pass that a Reach rebased onto
    /// the wider capture was called a read of the whole wider capture, so that a column the narrow read had cut looked whole to the Fit, which took the cut edge for the column's.
    public static func read(frame: CGSize, moves: [CGVector], capture: CGSize) -> CGRect {
        moves.reduce(CGRect(origin: .zero, size: frame)) { $0.offsetBy(dx: $1.dx, dy: $1.dy) }
            .intersection(CGRect(origin: .zero, size: capture))
    }
}

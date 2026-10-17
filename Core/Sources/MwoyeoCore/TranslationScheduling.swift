import CoreGraphics

/// Which translation work still matters, as a lens and the text around it move. Pure, so it can be tested without the app.
///
/// Rects are all in one coordinate space (the capture's image pixels); `lead` is the motion direction (-1…1 per axis,
/// the side text arrives from), zero while nothing moves.
public enum TranslationScheduling {
    /// Where a piece of text stands relative to the lens.
    public enum Standing: Sendable, Equatable {
        /// No longer on the capture.
        case gone
        /// Inside the lens.
        case lens
        /// Outside the lens, on the side motion brings text from.
        case leading
        /// Anywhere else.
        case other
    }

    /// Why an in-flight batch should be cut short.
    public enum Preemption: Sendable, Equatable {
        /// Nothing left in it is still on the capture.
        case allGone
        /// None of it is in the lens or on the leading side, while lens text waits.
        case lensWaiting
    }

    public static func standing(of r: CGRect, lens: CGRect, lead: CGVector) -> Standing {
        if r.intersects(lens) { return .lens }
        let sx: CGFloat = r.midX < lens.minX ? -1 : r.midX > lens.maxX ? 1 : 0
        let sy: CGFloat = r.midY < lens.minY ? -1 : r.midY > lens.maxY ? 1 : 0
        return sx * lead.dx + sy * lead.dy > 0 ? .leading : .other
    }

    /// Whether to cancel a running batch.
    /// - Parameters:
    ///   - unfinished: the standing of each source of the batch that has no result yet.
    ///   - lensWaiting: some text in the lens is queued and not part of this batch.
    ///   - afterLensPreemption: the batch before this one was cut by `.lensWaiting`. That rule then stays quiet, or no
    ///     batch would ever finish while content moves faster than a batch runs; `.allGone` always applies.
    public static func preemption(unfinished: [Standing], lensWaiting: Bool, afterLensPreemption: Bool) -> Preemption? {
        guard !unfinished.isEmpty else { return nil }
        if unfinished.allSatisfy({ $0 == .gone }) { return .allGone }
        guard lensWaiting, !afterLensPreemption else { return nil }
        return unfinished.allSatisfy({ $0 == .gone || $0 == .other }) ? .lensWaiting : nil
    }

    /// Text that motion has left behind: while `lead` is set, a rect that lies wholly on the trailing side (by its
    /// edges) and farther from the lens than one lens extent along that axis. Lens text is never trailing.
    public static func isTrailing(_ r: CGRect, lens: CGRect, lead: CGVector) -> Bool {
        if lead.dx > 0, lens.minX - r.maxX > lens.width { return true }
        if lead.dx < 0, r.minX - lens.maxX > lens.width { return true }
        if lead.dy > 0, lens.minY - r.maxY > lens.height { return true }
        if lead.dy < 0, r.minY - lens.maxY > lens.height { return true }
        return false
    }
}

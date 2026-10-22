import AppKit

/// The trackpad's alignment tick for a lens that comes to a column's edge (`NSHapticFeedbackManager.FeedbackPattern.alignment`: "in response to the
/// alignment of an object the user is dragging around"). Beside a visible guide, never alone: a Mac with no Force Touch trackpad plays nothing, and the
/// guide is the signal.
///
/// A move is done by the window server (`RegionFrameWindow` `performDrag`): the app is told of no mouse event, so the tick is played by hand, once, as an
/// edge comes within reach. A resize is the app's own drag, with events, and goes through the system's filter, which knows when the pointer moves too
/// fast or too little for a tick to be a good one.
@MainActor
final class AlignmentHaptic {
    private let filter = NSAlignmentFeedbackFilter()

    /// An edge came within reach of a column's edge during a move.
    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Feeds the filter the drag's events (`mouseDragged`).
    func update(with event: NSEvent) { filter.update(with: event) }

    /// A resize drag's right edge went from `previousX` (where the person last saw it) to `alignedX`, and would have been at `defaultX` without the
    /// snap, in `view`'s coordinates. The tick plays when the edge moves onto or off the column's edge, as the filter judges.
    func resized(in view: NSView, previousX: CGFloat, alignedX: CGFloat, defaultX: CGFloat) {
        guard let token = filter.alignmentFeedbackTokenForHorizontalMovement(in: view, previousX: previousX, alignedX: alignedX, defaultX: defaultX) else { return }
        filter.performFeedback([token], performanceTime: .now)
    }
}

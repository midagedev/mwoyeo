#if !MAS
import CoreGraphics
import Foundation

/// How far each shown translation is from its text, in points: the `drift` of `--pan` (SelfTest).
///
/// A block is measured against where its text really is on the page: its place in the frame its snapshot follows, plus the content
/// offset when that frame was captured. It used to be measured against where it was first drawn plus the offset of that draw, so a
/// block drawn late from a frame a step old took that gap as its anchor, and the frame that finally placed it right counted as
/// drift (B16, B24 and B32 of the film's AHEAD run read 40 pt on lines that sat on their text).
struct DriftMeter {
    private var anchors: [UUID: (page: CGPoint, size: CGSize, scrolls: Bool)] = [:]
    /// The content offset of each frame handed to the pipeline, oldest first.
    private var offsets: [(time: TimeInterval, offset: CGVector)] = []

    /// A frame captured at `time` shows the page scrolled by `offset`.
    mutating func fed(at time: TimeInterval, offset: CGVector) { offsets.append((time, offset)) }

    /// The content offset of the frame captured at `time`: the newest one fed at or before it, none yet = the page at rest.
    func offset(at time: TimeInterval) -> CGVector { offsets.last { $0.time <= time }?.offset ?? .zero }

    /// The gap of one block now. `followed`: where the block sits in the frame captured at `time` (points, no prediction);
    /// `shown`: where it is drawn now (with the prediction); `now`: the content offset now; `scrolls`: whether it moves with the content.
    /// A re-read may re-lay a block out (another size): it is anchored again from there.
    mutating func gap(id: UUID, size: CGSize, followed: CGRect, shown: CGRect, time: TimeInterval, now: CGVector, scrolls: Bool) -> CGFloat {
        func page(_ r: CGRect, _ o: CGVector, _ scrolls: Bool) -> CGPoint { CGPoint(x: r.minX + (scrolls ? o.dx : 0), y: r.minY + (scrolls ? o.dy : 0)) }
        if anchors[id] == nil || anchors[id]!.size != size { anchors[id] = (page(followed, offset(at: time), scrolls), size, scrolls) }
        let a = anchors[id]!, p = page(shown, now, a.scrolls)
        return hypot(p.x - a.page.x, p.y - a.page.y)
    }
}
#endif

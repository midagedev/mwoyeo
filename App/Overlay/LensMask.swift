import QuartzCore
import MwoyeoCore

/// The lens's top and bottom edges on one block layer (round edges117, docs/design/recognition.md §16.2): the lines of the translation that
/// stand wholly in the lens are shown, the others are masked, and the mask follows the lens. The layer's image is never drawn again for it.
enum LensMask {
    /// Sets `layer`'s mask for `lens` and says whether the layer shows at all (false: no line of it stands wholly in the lens). `lines` are the
    /// translation's line boxes in points relative to the layer's top-left, `lens` is in the layer's parent's space, where the layer's `frame`
    /// is (top-left based). The host's geometry is flipped and its sublayers' spaces are too: the mask's frame is top-down like the lines (a mask
    /// laid out y up showed the mirror image of the band, `lens-window-checks`).
    @discardableResult
    static func apply(to layer: CALayer, lines: [CGRect], lens: CGRect) -> Bool {
        let shown = LensWindow.shown(lines: lines, lens: lens.offsetBy(dx: -layer.frame.minX, dy: -layer.frame.minY))
        switch shown {
        case .all:
            if layer.mask != nil { layer.mask = nil }
            return true
        case .none:
            if layer.mask != nil { layer.mask = nil }
            return false
        case let .band(top, bottom):
            let mask: CALayer
            if let m = layer.mask { mask = m } else {
                mask = CALayer()
                mask.backgroundColor = CGColor(gray: 0, alpha: 1)
                layer.mask = mask
            }
            let band = CGRect(x: 0, y: top, width: layer.bounds.width, height: bottom - top)
            if mask.frame != band {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                mask.frame = band
                CATransaction.commit()
                Trace.count("overlay.line_masked")
            }
            return true
        }
    }
}

import AppKit
import MwoyeoCore
import QuartzCore

/// Where a lens moved by hand will land (`RegionSession.landingTarget`), shown while the hand is on it: the picker's spotlight outline (accent, 3 pt,
/// 1.5 pt outside the rect) over the content under the lens's middle, so the shape the lens takes when let go is seen before it is let go. Between
/// targets the outline glides (`LensMotion.settle`, none under Reduce Motion); it fades in and out with the snap guide's fade.
///
/// One click-through window over the lens's display, just under the lens (the lens and its translations stay over the outline).
@MainActor
final class LandingPreview {
    private var window: NSPanel?
    private let shape = CAShapeLayer()
    private let fill = CAShapeLayer()
    /// The target shown (global Quartz points); nil while hidden.
    private(set) var shown: CGRect?

    /// Shows the outline at `target` (global Quartz points) on `display` (global Quartz points), gliding from the one shown.
    func show(_ target: CGRect, on display: CGRect) {
        let w = window(on: display)
        let local = ScreenGeometry.appKitRect(fromQuartz: target).offsetBy(dx: -w.frame.minX, dy: -w.frame.minY)
        let stroke = CGPath(roundedRect: local.insetBy(dx: -1.5, dy: -1.5), cornerWidth: 6, cornerHeight: 6, transform: nil)
        let area = CGPath(roundedRect: local, cornerWidth: 5, cornerHeight: 5, transform: nil)
        let glides = shown != nil && !Motion.shared.reduced
        CATransaction.begin()
        if glides {
            CATransaction.setAnimationDuration(LensMotion.settle)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            for (layer, path) in [(shape, stroke), (fill, area)] {
                let a = CABasicAnimation(keyPath: "path")
                a.fromValue = layer.presentation()?.path ?? layer.path
                a.toValue = path
                layer.add(a, forKey: "path")
            }
        } else {
            CATransaction.setDisableActions(true)
        }
        shape.path = stroke
        fill.path = area
        CATransaction.commit()
        w.effectiveAppearance.performAsCurrentDrawingAppearance {
            shape.strokeColor = NSColor.controlAccentColor.cgColor
            fill.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        }
        if shown == nil {
            w.alphaValue = 0
            w.orderFrontRegardless()
            fade(w, to: 1)
        }
        shown = target
    }

    func hide() {
        guard shown != nil, let w = window else { return }
        shown = nil
        fade(w, to: 0)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        shown = nil
    }

    private func fade(_ w: NSWindow, to alpha: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = LensMotion.seconds(LensMotion.guideFade, reduced: Motion.shared.reduced)
            w.animator().alphaValue = alpha
        }
    }

    private func window(on display: CGRect) -> NSPanel {
        let frame = ScreenGeometry.appKitRect(fromQuartz: display)
        if let window, window.frame == frame { return window }
        window?.orderOut(nil)
        shown = nil
        let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        // Just under the lens (`RegionFrameWindow`), which stays over its outline.
        w.level = .statusBar
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        shape.fillColor = nil
        shape.lineWidth = 3
        view.layer?.addSublayer(fill)
        view.layer?.addSublayer(shape)
        w.contentView = view
        window = w
        return w
    }
}

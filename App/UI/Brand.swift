import SwiftUI

/// The lens motif shared by the icon, the on-screen lens frame and the interface.
enum Brand {
    static let spectrum: [Color] = [
        Color(red: 1.00, green: 0.62, blue: 0.04), Color(red: 1.00, green: 0.22, blue: 0.37),
        Color(red: 0.75, green: 0.35, blue: 0.95), Color(red: 0.37, green: 0.36, blue: 0.90),
        Color(red: 0.39, green: 0.82, blue: 1.00), Color(red: 1.00, green: 0.62, blue: 0.04),
    ]

    static func ring(_ angle: Angle = .zero, tint: LensTint = .spectrum) -> AngularGradient {
        AngularGradient(colors: tint == .spectrum ? spectrum : tint.colors.map { Color(nsColor: $0) }, center: .center, angle: angle)
    }
}

/// A rounded lens outline in the spectrum gradient, with a soft glow. `spinning` turns the colours slowly.
struct LensRing: View {
    var cornerRadius: CGFloat = 8
    var lineWidth: CGFloat = 2
    var glow: CGFloat = 4
    var spinning = false
    var active = true
    var period: Double = 2.4
    var tint = LensTint.spectrum

    var body: some View {
        // Reduce Motion: the colours stay where a lens that is not reading has them.
        let spins = spinning && !Motion.shared.reduced
        TimelineView(.animation(paused: !spins)) { t in
            let angle = Angle.degrees(spins ? (t.date.timeIntervalSinceReferenceDate / period).truncatingRemainder(dividingBy: 1) * 360 : 45)
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            ZStack {
                if active, glow > 0 {
                    shape.stroke(Brand.ring(angle, tint: tint), lineWidth: lineWidth * 2.5).blur(radius: glow).opacity(0.7)
                }
                shape.stroke(active ? AnyShapeStyle(Brand.ring(angle, tint: tint)) : AnyShapeStyle(.tertiary), lineWidth: lineWidth)
            }
        }
    }
}

/// The app mark, drawn to match the app icon: a spectrum lens over lines of text, bright inside, faint outside.
struct AppGlyph: View {
    var size: CGFloat = 64

    var body: some View {
        let s = size
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: s * 0.226, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.21), Color(white: 0.10), Color(white: 0.06)],
                                     startPoint: .top, endPoint: .bottom))
            ForEach(Array(Self.faint.enumerated()), id: \.offset) { _, l in bar(l, s).fill(.white.opacity(0.12)) }
            RoundedRectangle(cornerRadius: s * 0.104, style: .continuous)
                .fill(Color(white: 0.06).opacity(0.92))
                .frame(width: s * 0.67, height: s * 0.515)
                .offset(x: s * 0.165, y: s * 0.243)
            ForEach(Array(Self.bright.enumerated()), id: \.offset) { _, l in bar(l, s).fill(.white.opacity(0.96)) }
            LensRing(cornerRadius: s * 0.104, lineWidth: max(1, s * 0.024), glow: s * 0.035)
                .frame(width: s * 0.67, height: s * 0.515)
                .offset(x: s * 0.165, y: s * 0.243)
        }
        .frame(width: s, height: s)
        .clipShape(RoundedRectangle(cornerRadius: s * 0.226, style: .continuous))
        .accessibilityHidden(true)
    }

    /// Text bars as (centre y, x0, x1), in fractions of the glyph.
    private static let faint: [(CGFloat, CGFloat, CGFloat)] = [(0.112, 0.117, 0.728), (0.393, 0.083, 0.917), (0.5, 0.083, 0.837),
                                                              (0.607, 0.083, 0.934), (0.888, 0.117, 0.801)]
    private static let bright: [(CGFloat, CGFloat, CGFloat)] = [(0.393, 0.243, 0.757), (0.5, 0.243, 0.716), (0.607, 0.243, 0.558)]

    private func bar(_ l: (CGFloat, CGFloat, CGFloat), _ s: CGFloat) -> some Shape {
        Capsule().path(in: CGRect(x: l.1 * s, y: (l.0 - 0.0206) * s, width: (l.2 - l.1) * s, height: 0.041 * s))
    }
}

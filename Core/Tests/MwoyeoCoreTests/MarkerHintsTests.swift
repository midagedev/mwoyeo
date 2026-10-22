import CoreGraphics
import Testing
@testable import MwoyeoCore

/// gamepill, 2026-10-22: the region marker's hint pills never overlap the lens (ring and name tag included), stay inside the visible frame
/// and keep their order and spacing (opus vision on the game117 shots: the arrow-keys pill was over the lens's top-right ring by ~9 pt).
@Suite struct MarkerHintsTests {
    /// A 1512 × 982 screen (y up) with its 38 pt menu bar excluded.
    private let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
    /// The two pills of a 13 pt label: the drag hint and the (longer) arrow-keys one.
    private let pills = [CGSize(width: 436, height: 32), CGSize(width: 560, height: 32)]
    private let clearance: CGFloat = 40

    private func place(_ lens: CGRect) -> [CGRect] { MarkerHints.place(pills: pills, lens: lens, visible: visible, clearance: clearance) }

    /// What the contract asks of a placement, as failures in words (empty: it holds). `overlapOK`: a lens that leaves no room.
    private func broken(_ frames: [CGRect], lens: CGRect, overlapOK: Bool = false) -> [String] {
        var out: [String] = []
        if frames.map(\.size) != pills { out.append("sizes changed: \(frames.map(\.size))") }
        for (i, f) in frames.enumerated() where !visible.contains(f) { out.append("pill \(i) \(f) is not inside \(visible)") }
        if !overlapOK {
            for (i, f) in frames.enumerated() where f.intersects(lens.insetBy(dx: -clearance, dy: -clearance)) {
                out.append("pill \(i) \(f) is within \(clearance) pt of the lens \(lens)")
            }
        }
        if frames.count == 2 {
            // The first is above the second (y up) and the gap between them is the spacing, whether stacked over the lens or beside it.
            let gap = frames[0].minY - frames[1].maxY
            if gap != MarkerHints.spacing { out.append("the gap between the pills is \(gap), not \(MarkerHints.spacing)") }
        }
        return out
    }

    @Test func aCentredLensHasTheHintsAboveIt() {
        let lens = CGRect(x: 456, y: 300, width: 600, height: 340)
        let f = place(lens)
        #expect(broken(f, lens: lens).isEmpty, "\(broken(f, lens: lens))")
        #expect(f.allSatisfy { $0.minY >= lens.maxY }, "above the lens: \(f)")
        #expect(f.allSatisfy { abs($0.midX - lens.midX) < 0.5 }, "centred on the lens, not on the screen: \(f)")
        #expect(f[1].minY == lens.maxY + clearance, "the second pill is the nearer one, one clearance from the lens: \(f)")
    }

    @Test func aLensNearTheTopHasThemBelow() {
        let lens = CGRect(x: 456, y: 500, width: 600, height: 420)   // 24 pt under the visible top: no room for 72 + 40
        let f = place(lens)
        #expect(broken(f, lens: lens).isEmpty, "\(broken(f, lens: lens))")
        #expect(f.allSatisfy { $0.maxY <= lens.minY }, "below the lens: \(f)")
    }

    @Test func aLensNearTheRightEdgeKeepsThemInsideTheScreen() {
        // The game117 shot: the lens's right edge was the pills' end, and the screen cut them.
        let lens = CGRect(x: 1512 - 40 - 600, y: 400, width: 600, height: 340)
        let f = place(lens)
        #expect(broken(f, lens: lens).isEmpty, "\(broken(f, lens: lens))")
        #expect(f.allSatisfy { $0.maxX <= visible.maxX }, "\(f)")
        let atTheEdge = CGRect(x: 1512 - 300, y: 700, width: 300, height: 200)
        #expect(broken(place(atTheEdge), lens: atTheEdge).isEmpty, "\(broken(place(atTheEdge), lens: atTheEdge))")
    }

    @Test func aFullHeightLensHasThemBesideIt() {
        let lens = CGRect(x: 200, y: 0, width: 420, height: 944)
        let f = place(lens)
        #expect(broken(f, lens: lens).isEmpty, "\(broken(f, lens: lens))")
        #expect(f.allSatisfy { $0.minX >= lens.maxX }, "to the right, where there is room: \(f)")
        let right = CGRect(x: 1512 - 420 - 100, y: 0, width: 420, height: 944)
        let g = place(right)
        #expect(broken(g, lens: right).isEmpty, "\(broken(g, lens: right))")
        #expect(g.allSatisfy { $0.maxX <= right.minX }, "to the left, where there is none on the right: \(g)")
    }

    @Test func aLensThatFillsTheScreenGetsThemInsideItsTop() {
        let f = place(visible)
        #expect(broken(f, lens: visible, overlapOK: true).isEmpty, "\(broken(f, lens: visible, overlapOK: true))")
        #expect(f[0].maxY == visible.maxY - MarkerHints.inset, "just inside the top: \(f)")
    }

    @Test func noSweptLensGetsAPillOnItsFrame() {
        // Every lens up to 1000 × 600 on a 1512 × 944 screen has room above, below or beside it: the contract holds for each.
        var checked = 0
        for width in stride(from: 80, through: 1000, by: 230) {
            for height in stride(from: 40, through: 600, by: 140) {
                for x in stride(from: CGFloat(0), through: visible.width - CGFloat(width), by: 97) {
                    for y in stride(from: CGFloat(0), through: visible.height - CGFloat(height), by: 83) {
                        let lens = CGRect(x: x, y: y, width: CGFloat(width), height: CGFloat(height))
                        let b = broken(place(lens), lens: lens)
                        checked += 1
                        if !b.isEmpty { Issue.record("lens \(lens): \(b.joined(separator: "; "))"); return }
                    }
                }
            }
        }
        #expect(checked > 1000, "swept \(checked) lenses")
    }

    @Test func noPillsNoFrames() {
        #expect(MarkerHints.place(pills: [], lens: CGRect(x: 456, y: 300, width: 600, height: 340), visible: visible, clearance: clearance).isEmpty)
    }
}

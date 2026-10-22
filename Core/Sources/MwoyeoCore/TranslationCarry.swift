import CoreGraphics

/// What a block that is read again shows until its own translation arrives (round hold117, docs/design/lens-hold.md).
///
/// A re-read of a page that did not change (the lens was resized and the capture read a little more of a cut paragraph; the settled
/// document reader grouped the lines the fast reader had split) makes new blocks. A new block keeps its predecessor's translation when its
/// text is the same; when it is not, it has none yet, and a block with none draws nothing: the lens would show the page's own text for as
/// long as the engine takes. The translations that stood where the new block stands are drawn instead. They are the translation of what
/// the page said there, and the page has not changed.
public enum TranslationCarry {
    public struct Old: Sendable, Equatable {
        public var rect: CGRect
        /// What the block drew: its translation, or the text it carried while it waited for one. nil: it drew nothing.
        public var shown: String?
        /// The page under it is the page it was read from (`FrameDiff.changeMap(from:to:ignoring:)` found no change).
        public var unchanged: Bool

        public init(rect: CGRect, shown: String?, unchanged: Bool) {
            self.rect = rect
            self.shown = shown
            self.unchanged = unchanged
        }
    }

    /// An old block belongs to the new block that holds at least this share of it.
    public static let share: CGFloat = 0.5

    /// What a new block draws until its own translation comes, and the old block it takes the place of.
    public struct Carry: Sendable, Equatable {
        public var text: String
        /// The old block that holds the most of the new one (index in `old`). A new block with this block's identity is shown in its place by a
        /// dissolve of one layer; with an identity of its own it would be faded in over the page while the old one fades out.
        public var primary: Int
        /// Every old block whose text it carries (indices in `old`).
        public var from: [Int]
    }

    /// For each of `new` (rects in the space of `old`), the text to draw until its own translation comes: the `shown` text of every old block
    /// that it holds half of or more, unchanged and drawn, the best-covering new block taking it; several are joined in reading order
    /// (top to bottom, then left to right). nil where there is none.
    public static func assign(old: [Old], new: [CGRect]) -> [Carry?] {
        var taken = [[Int]](repeating: [], count: new.count)
        for (oi, o) in old.enumerated() where o.unchanged && o.shown?.isEmpty == false {
            let area = o.rect.width * o.rect.height
            guard area > 0 else { continue }
            var best: (index: Int, share: CGFloat)?
            for (ni, n) in new.enumerated() {
                let i = o.rect.intersection(n)
                guard !i.isNull else { continue }
                let s = i.width * i.height / area
                if s >= share, s > (best?.share ?? 0) { best = (ni, s) }
            }
            if let best { taken[best.index].append(oi) }
        }
        return taken.map { indices in
            let ordered = indices.sorted { a, b in
                let ra = old[a].rect, rb = old[b].rect
                return ra.minY != rb.minY ? ra.minY < rb.minY : ra.minX < rb.minX
            }
            guard let largest = indices.max(by: { old[$0].rect.width * old[$0].rect.height < old[$1].rect.width * old[$1].rect.height }) else { return nil }
            return Carry(text: ordered.compactMap { old[$0].shown }.joined(separator: " "), primary: largest, from: ordered)
        }
    }

    /// A new block that is a piece of one old block's page text: this much of it lies inside that block.
    public static let fragmentShare: CGFloat = 0.8

    /// For each of `new`, the old block it is a piece of, or nil: the new block lies (`fragmentShare` or more of it) inside an old block that is
    /// drawn and unchanged, and `carry` (what `assign` found) gives neither of them to the other. The capture's edge cuts a paragraph that the
    /// lens has moved to, a reading splits one paragraph in several: what the new block holds is already drawn, with its translation, where it
    /// was read. The old block stays as it is and the new block is not made.
    public static func fragments(old: [Old], new: [CGRect], carry: [Carry?]) -> [Int?] {
        let carried = Set(carry.compactMap { $0 }.flatMap(\.from))
        return new.enumerated().map { ni, n in
            let area = n.width * n.height
            guard carry[ni] == nil, area > 0 else { return nil }
            var best: (index: Int, share: CGFloat)?
            for (oi, o) in old.enumerated() where o.unchanged && o.shown?.isEmpty == false && !carried.contains(oi) {
                let i = o.rect.intersection(n)
                guard !i.isNull else { continue }
                let s = i.width * i.height / area
                if s >= fragmentShare, s > (best?.share ?? 0) { best = (oi, s) }
            }
            return best?.index
        }
    }
}

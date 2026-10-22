import CoreGraphics

/// When the erased patches of a pass reach the screen, and in which order they are filled (round erase117, docs/design/first-lens.md §14).
///
/// Erasing a block has a cheap half, the plan (the glyph masks, the patch's rect, the text's look and size), and a slow half, the fill (the
/// flat fill or the inpainting model over the mask: a median 0.17 s a block in a debug build, up to 3 s for a long paragraph under load). A pass
/// plans every block it read side by side, then fills them one at a time, both off the pipeline's actor, so a translation that lands meanwhile is
/// drawn at once. Pure, so it is tested without the app.
public enum EraseSchedule {
    /// How the blocks of a pass take their place on the screen.
    public enum Install: Sendable, Equatable {
        /// Each block as soon as its own patch is filled: the pass replaces no block, so nothing stands where its blocks go, and the first Korean
        /// waits for its own block's fill, not for every block's (a lens's first read, a read after a reset, a strip a scroll uncovered).
        case eachWhenFilled
        /// All together when every patch is filled: the blocks take the place of blocks that may be on the screen, and the swap is one step
        /// (docs/design/lens-hold.md: nothing drawn goes blank while the page is unchanged). The old blocks take what lands meanwhile.
        case allAtOnce
    }

    /// How a pass that replaces `replacing` blocks installs the blocks it read.
    public static func install(replacing: Int) -> Install { replacing == 0 ? .eachWhenFilled : .allAtOnce }

    /// One block whose patch is not filled yet: where it is (the capture's image pixels) and whether its translation has landed.
    public struct Candidate: Sendable, Equatable {
        public var rect: CGRect
        public var translated: Bool
        public init(rect: CGRect, translated: Bool) {
            self.rect = rect
            self.translated = translated
        }
    }

    /// The candidate to fill next, or nil when there is none: what the person sees first (`TranslationScheduling.priority`: the lens in reading
    /// order, then the overscan nearest first), and within the lens, or within the overscan, a block whose translation has landed before one
    /// still waiting for it, since it is drawn the moment its patch is in. Ties keep the order given.
    public static func next(_ candidates: [Candidate], lens: CGRect, lead: CGVector) -> Int? {
        func rank(_ c: Candidate) -> (Int, Int, CGFloat) {
            let p = TranslationScheduling.priority(of: c.rect, lens: lens, lead: lead)
            return (p.0, c.translated ? 0 : 1, p.1)
        }
        return candidates.indices.min { rank(candidates[$0]) < rank(candidates[$1]) }
    }
}

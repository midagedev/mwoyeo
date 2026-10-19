import CoreGraphics
import Foundation

/// A lens placed with the keyboard instead of a drag (`RegionPicker`): arrow keys move it by `step` points, ⇧ + arrow resizes it by
/// the same, ⌥ makes either `fineStep`. It starts at the default size, centred in `bounds`, and never leaves them.
/// Coordinates are AppKit's (y up), as the picker's view has them; the resize keeps the top-left corner, as the lens's grip does.
public struct KeyboardLens: Equatable, Sendable {
    public enum Key: Equatable, Sendable { case left, right, up, down }

    public static let step: CGFloat = 10
    public static let fineStep: CGFloat = 1
    /// The size a click drops (`RegionPicker`): a typical chat or comment column.
    public static let defaultSize = CGSize(width: 560, height: 320)
    public static let minSize = CGSize(width: 80, height: 40)

    public let bounds: CGRect
    public private(set) var rect: CGRect

    /// The default lens, centred in `bounds` (shrunk to fit a smaller one).
    public init(bounds: CGRect) {
        self.bounds = bounds
        let size = CGSize(width: min(Self.defaultSize.width, bounds.width), height: min(Self.defaultSize.height, bounds.height))
        rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// A key press. `resize`: ⇧; `fine`: ⌥. Returns whether the lens changed (false at an edge or a limit).
    @discardableResult
    public mutating func press(_ key: Key, resize: Bool = false, fine: Bool = false) -> Bool {
        let d = fine ? Self.fineStep : Self.step
        var r = rect
        if resize {
            switch key {
            case .right: r.size.width += d
            case .left: r.size.width -= d
            case .down: r.origin.y -= d; r.size.height += d   // the bottom edge goes down, the top stays
            case .up: r.origin.y += d; r.size.height -= d
            }
            guard r.width >= Self.minSize.width, r.height >= Self.minSize.height,
                  r.maxX <= bounds.maxX, r.minY >= bounds.minY else { return false }
        } else {
            switch key {
            case .right: r.origin.x += d
            case .left: r.origin.x -= d
            case .up: r.origin.y += d
            case .down: r.origin.y -= d
            }
            r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
            r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        }
        guard r != rect else { return false }
        rect = r
        return true
    }
}

/// What a lens is doing, in the one word its accessibility value says. The order is the pill's: a notice outranks the original, the
/// original a hint, a hint what the lens is busy with.
public enum LensAccessState: Equatable, Sendable {
    case notice(String)
    case showingOriginal
    case hint(String)
    case reading
    case translated
    /// Nothing read yet: the lens is watching.
    case waiting

    public init(notice: String?, original: Bool, hint: String?, busy: Bool, translated: Bool) {
        if let notice, !notice.isEmpty { self = .notice(notice) }
        else if original { self = .showingOriginal }
        else if let hint, !hint.isEmpty { self = .hint(hint) }
        else if busy { self = .reading }
        else if translated { self = .translated }
        else { self = .waiting }
    }
}

public enum LensAccessSummary {
    /// The first `limit` characters of `lines` (a lens's translations in reading order) joined by spaces, cut at a word and ended with
    /// "…" when there is more. Empty when there is nothing to read.
    public static func excerpt(_ lines: [String], limit: Int = 200) -> String {
        let text = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
        guard text.count > limit else { return text }
        let cut = String(text.prefix(limit))
        // Back to the last space (a language without spaces cuts at the limit).
        let head = cut.lastIndex(of: " ").map { String(cut[..<$0]) }.flatMap { $0.count >= limit / 2 ? $0 : nil } ?? cut
        return head + "…"
    }
}

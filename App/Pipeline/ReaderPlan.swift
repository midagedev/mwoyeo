import Foundation
import MwoyeoCore
import os

/// Which paragraph reader one lens uses, now: the setting (the app's profile, else the global default), the app in the lens, and
/// what `ReaderSwitcher` kept from the frames so far. Shared between the pipeline (which sets it from its options) and
/// `TextRecognizer.blocks` (which asks it for a reader once the frame's lines are read).
final class ReaderPlan: Sendable {
    private struct State {
        var setting = ParagraphReader.automatic
        var context = ReaderContext()
        var switcher = ReaderSwitcher()
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func configure(setting: ParagraphReader, context: ReaderContext) {
        state.withLock {
            $0.setting = setting
            if $0.context != context { $0.switcher = ReaderSwitcher() }
            $0.context = context
        }
    }

    /// The user's choice (`automatic` unless set).
    var setting: ParagraphReader { state.withLock { $0.setting } }

    /// The reader `ReaderSwitcher` holds for this lens so far, nil before the first frame.
    var held: ParagraphReader? { state.withLock { $0.switcher.current?.reader } }

    /// The reader for a frame whose lines are `lines` in an image of `size`. `partial`: the frame is a band of a larger one
    /// (the layout of a band says little), so a choice already made stands. Returns the pick and the trace line.
    func decide(lines: [CGRect], texts: [String], size: CGSize, partial: Bool) -> (reader: ParagraphReader, trace: String) {
        state.withLock { s in
            if partial, let held = s.switcher.current { return (held.reader, "reader auto → \(held.reader.rawValue): kept (band)") }
            let layout = LineLayout(lines: lines, in: size)
            let pick = ReaderDecider.decide(layout, context: s.context)
            let (chosen, switched) = s.switcher.settle(pick, app: s.context.bundleID, text: texts.joined(separator: "\n").hashValue)
            let note = chosen.reader == pick.reader ? "" : " (decider says \(pick.reader.rawValue), held)"
            return (chosen.reader, "reader auto → \(chosen.reader.rawValue)\(switched ? " [switched]" : ""): \(chosen.reason)\(note)")
        }
    }
}

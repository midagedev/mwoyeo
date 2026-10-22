#if !MAS
import CoreGraphics
import Foundation
import MwoyeoCore

/// `MWOYEO_LENS_SWEEP=1`: how a translation fits when the lens covers only part of its block, for the one number the lens's side edges need
/// (`LensWindow.minShare`, docs/design/recognition.md §16.2). After each block is drawn, it is drawn again in a window of 100 % to 10 % of the
/// width of its source text (starting at the text's left edge), and one `sweep` line says what the fitter did: the size it returned beside the
/// size at the full width and its floor, whether the translation was cut ("…"), and how many lines it came to. `tools/lens-window/sweep.py`
/// reads the lines of a paper-bench run (`tools/paper-bench/run.sh` with the variable set) and prints, for each share, how many blocks still read.
enum LensSweep {
    static let enabled = ProcessInfo.processInfo.environment["MWOYEO_LENS_SWEEP"] != nil
    static let shares: [CGFloat] = [1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.45, 0.4, 0.35, 0.3, 0.25, 0.2, 0.15, 0.1]

    static func report(_ input: BlockRenderer.Input, source: String, core: CGRect) {
        var full: BlockRenderer.Rendered?
        for share in shares {
            var narrowed = input
            narrowed.window = core.minX...(core.minX + share * core.width)
            guard let r = BlockRenderer.render(narrowed) else { continue }
            if share == 1 { full = r }
            let line = "sweep share \(share) size \(TraceNumber.px(r.fontSize)) full \(TraceNumber.px(full?.fontSize ?? r.fontSize)) floor \(TraceNumber.px(r.floorSize)) "
                + "clipped \(r.clipped ? 1 : 0) ellipsis \(r.ellipsis ? 1 : 0) lines \(r.lines.count) wrapped \(input.originalLineCount) core \(TraceNumber.px(core.width))x\(TraceNumber.px(core.height)) "
                + "chars \(input.text.count) src '\(source.prefix(20))'"
            FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
        }
    }
}
#endif

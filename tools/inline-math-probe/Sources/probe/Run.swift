import CoreGraphics
import Foundation
import ImageIO

enum Run {
    static func wilson(_ k: Int, _ n: Int) -> (Double, Double) {
        guard n > 0 else { return (0, 0) }
        let z = 1.96, p = Double(k) / Double(n), d = 1 + z * z / Double(n)
        let c = p + z * z / (2 * Double(n)), s = z * (p * (1 - p) / Double(n) + z * z / (4 * Double(n * n))).squareRoot()
        return ((c - s) / d, (c + s) / d)
    }

    static func pct(_ k: Int, _ n: Int) -> String { n == 0 ? "n/a" : String(format: "%.0f%%", 100 * Double(k) / Double(n)) }

    static func measure(_ args: [String]) {
        func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let ocr = option("--ocr"), let pages = option("--pages") else { fail("measure needs --ocr and --pages") }
        var cfg = Config()
        if let v = option("--threshold").flatMap(Int.init) { cfg.threshold = v }
        if let v = option("--dilate").flatMap(Int.init) { cfg.dilate = v }
        if let v = option("--pad").flatMap(Int.init) { cfg.pad = v }
        if let v = option("--tol").flatMap(Int.init) { cfg.tol = v }
        if let v = option("--mutate") { cfg.mutate = v }
        let names = (option("--names") ?? "p3,p4,p5,p6").split(separator: ",").map(String.init)
        let outDir = option("--out").map { URL(fileURLWithPath: $0) }
        let verbose = args.contains("-v")
        let tag = cfg.mutate == "none" ? "base" : cfg.mutate
        var all: [String: [Row]] = [:]
        var skipped: [String: (cross: Int, noBox: Int)] = [:]
        var tsv = ["path\tpage\ttext\tlh\ttrailing\ttrim\tcrop_w\tcrop_h\ta_cut\ttouch\tb\tb_strict\tc_foreign\tclean\tgrown\tgrown_why\tgrown_dx\tgrown_dy\tgrown_a\tgrown_b\tgrown_c\tgrown_clean\tcrop\tline\tgrown_rect\ta_cut_foreign"]
        for name in names {
            let url = URL(fileURLWithPath: pages).appendingPathComponent("\(name).png")
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("cannot read \(url.path)") }
            let ink = Ink(image: image, threshold: cfg.threshold, dilate: cfg.dilate)
            for path in ["vn", "docs"] {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: ocr).appendingPathComponent("\(path)-\(name).json")),
                      let page = try? JSONDecoder().decode(JPage.self, from: data) else { print("missing \(path)-\(name).json"); continue }
                let m = Measurer(ink: ink, cfg: cfg, lines: page.paragraphs.flatMap { $0 })
                var rows: [Row] = []
                var cross = 0, noBox = 0, total = 0
                for (i, block) in blocks(of: page).enumerated() {
                    for sp in spans(of: block, index: i) {
                        total += 1
                        if sp.cross { cross += 1; continue }
                        if sp.noBox { noBox += 1; continue }
                        rows.append(m.row(path: path, page: name, span: sp))
                    }
                }
                all["\(path)", default: []] += rows
                let s = skipped[path] ?? (0, 0)
                skipped[path] = (s.cross + cross, s.noBox + noBox)
                print(summary(tag: tag, label: "\(name) \(path)", rows: rows, cfg: cfg, found: total, cross: cross, noBox: noBox))
                for r in rows {
                    tsv.append(tsvLine(r, cfg))
                    if verbose, !r.m.clean(cfg) {
                        print("  \(path) \(name) '\(r.text)' lh=\(Int(r.lh)) a=\(r.m.cut) b=\(String(format: "%.2f", r.m.b))/\(String(format: "%.2f", r.m.bStrict)) c=\(r.m.foreign) trim=\(r.trim?.kind ?? "-") grown=\(r.grown == nil ? "refused" : "ok")")
                    }
                }
            }
        }
        for path in ["vn", "docs"] {
            let rows = all[path] ?? []
            let s = skipped[path] ?? (0, 0)
            print(summary(tag: tag, label: "ALL \(path)", rows: rows, cfg: cfg, found: rows.count + s.cross + s.noBox, cross: s.cross, noBox: s.noBox))
            if args.contains("--sens") {
                for (tol, minF, bl) in [(1, 4, 0.05), (3, 4, 0.05), (6, 8, 0.05), (1, 1, 0.02), (3, 8, 0.10)] {
                    var c = cfg; c.tol = tol; c.minForeign = minF; c.bLimit = bl
                    let n = rows.filter { $0.m.clean(c) }.count
                    let g = rows.filter { $0.grown != nil && ($0.grownM?.clean(c) ?? false) }.count
                    print("  sens \(path) tol=\(tol) minForeign=\(minF) b<\(bl): clean=\(n)/\(rows.count) \(pct(n, rows.count))  grown-clean=\(g)/\(rows.count) \(pct(g, rows.count))")
                }
            }
        }
        if let outDir {
            try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            try? tsv.joined(separator: "\n").write(to: outDir.appendingPathComponent("spans-\(tag).tsv"), atomically: true, encoding: .utf8)
            var fails: [Montage.Tile] = [], cleans: [Montage.Tile] = []
            for path in ["docs", "vn"] {
                for r in all[path] ?? [] {
                    let label = tileLabel(r, cfg)
                    if r.m.clean(cfg) { cleans.append(Montage.Tile(row: r, label: label)) } else { fails.append(Montage.Tile(row: r, label: label)) }
                }
            }
            let cap = 60
            var shown = fails
            if fails.count > cap {
                let step = Double(fails.count) / Double(cap)
                shown = (0..<cap).map { fails[Int(Double($0) * step)] }
            }
            Montage.write(shown, to: outDir.appendingPathComponent("montage-fail-\(tag).png"),
                          title: "failures (\(shown.count) of \(fails.count)): orange dashed = word boxes' union, red = crop, green = ink-grown; label a=cut comps b=outside share c=neighbour ink d=trim g=grown", width: 1800)
            Montage.write(Array(cleans.prefix(24)), to: outDir.appendingPathComponent("montage-clean-\(tag).png"),
                          title: "clean controls (first \(min(24, cleans.count)) of \(cleans.count))", width: 1800)
        }
    }

    /// `probe dump`: the crop of one span as text, for checking a measure by eye: '#' ink inside the crop, 'o' ink outside it,
    /// '+' the border (red box), '~' the ink-grown box's border.
    static func dump(_ args: [String]) {
        func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let ocr = option("--ocr"), let pages = option("--pages"), let name = option("--page"), let path = option("--path"), let want = option("--text") else {
            fail("dump needs --ocr --pages --page --path --text [--nth 0]")
        }
        let cfg = Config()
        let url = URL(fileURLWithPath: pages).appendingPathComponent("\(name).png")
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let data = try? Data(contentsOf: URL(fileURLWithPath: ocr).appendingPathComponent("\(path)-\(name).json")),
              let page = try? JSONDecoder().decode(JPage.self, from: data) else { fail("cannot read inputs") }
        let m = Measurer(ink: Ink(image: image, threshold: cfg.threshold, dilate: cfg.dilate), cfg: cfg, lines: page.paragraphs.flatMap { $0 })
        var n = option("--nth").flatMap(Int.init) ?? 0
        for (i, block) in blocks(of: page).enumerated() {
            for sp in spans(of: block, index: i) where sp.text == want && !sp.cross && !sp.noBox {
                if n > 0 { n -= 1; continue }
                let r = m.row(path: path, page: name, span: sp)
                print("\(path) \(name) '\(r.text)' lh=\(Int(r.lh)) line=(\(Int(r.line.x)),\(Int(r.line.y)),\(Int(r.line.w)),\(Int(r.line.h))) base=\(r.base) crop=\(r.crop) grown=\(String(describing: r.grown)) trim=\(String(describing: r.trim))")
                print("a=\(r.m.cut) touch=\(r.m.touch) b=\(r.m.b) bStrict=\(r.m.bStrict) c=\(r.m.foreign) words=\(sp.words.map { "(\(Int($0.x)),\(Int($0.y)),\(Int($0.w)),\(Int($0.h)))" })")
                let mg = Int(0.5 * r.lh)
                let reg = (r.grown.map { r.crop.union($0) } ?? r.crop)
                let v = IntRect(x0: reg.x0 - mg, y0: reg.y0 - mg, x1: reg.x1 + mg, y1: reg.y1 + mg).clamped(m.ink.width, m.ink.height)
                let step = max(1, v.width / 170)
                for y in v.y0..<v.y1 where (y - v.y0) % step == 0 {
                    var row = ""
                    for x in stride(from: v.x0, to: v.x1, by: step) {
                        let onInk = (0..<step).contains { m.ink.has(x + $0, y) }
                        let inCrop = x >= r.crop.x0 && x < r.crop.x1 && y >= r.crop.y0 && y < r.crop.y1
                        let onEdge = inCrop && (y == r.crop.y0 || y == r.crop.y1 - 1 || (x - r.crop.x0) < step || (r.crop.x1 - 1 - x) < step)
                        if onInk { row += inCrop ? "#" : "o" } else if onEdge { row += "+" } else { row += " " }
                    }
                    print(row)
                }
                return
            }
        }
        print("no such span")
    }

    static func tsvLine(_ r: Row, _ cfg: Config) -> String {
        let g = r.grownM
        var f: [String] = [r.path, r.page, r.text, String(format: "%.0f", r.lh), String(r.trailing), r.trim?.kind ?? "-"]
        f += [String(r.crop.width), String(r.crop.height), r.m.cut.map(String.init).joined(separator: ","), String(r.m.touch)]
        f += [String(format: "%.3f", r.m.b), String(format: "%.3f", r.m.bStrict), r.m.foreign.map(String.init).joined(separator: ",")]
        f += [r.m.clean(cfg) ? "1" : "0", r.grown == nil ? "refused" : "ok", r.grownWhy]
        f += [r.grown.map { String($0.width - r.crop.width) } ?? "", r.grown.map { String($0.height - r.crop.height) } ?? ""]
        f += [g.map { String($0.a(cfg)) } ?? "", g.map { String(format: "%.3f", $0.b) } ?? "", g.map { String($0.c(cfg)) } ?? ""]
        f += [g.map { $0.clean(cfg) ? "1" : "0" } ?? ""]
        f += ["\(r.crop.x0),\(r.crop.y0),\(r.crop.x1),\(r.crop.y1)", String(format: "%.3f,%.3f,%.3f,%.3f", r.line.x, r.line.y, r.line.w, r.line.h)]
        f += [r.grown.map { "\($0.x0),\($0.y0),\($0.x1),\($0.y1)" } ?? "", r.m.cutForeign.map(String.init).joined(separator: ",")]
        return f.joined(separator: "\t")
    }

    static func tileLabel(_ r: Row, _ cfg: Config) -> String {
        let grown: String = r.grown == nil ? "refused" : ((r.grownM?.clean(cfg) ?? false) ? "clean" : "bad")
        let b = String(format: "%.2f", r.m.b)
        return "\(r.path) \(r.page) a\(r.m.a(cfg)) b\(b) c\(r.m.c(cfg)) d:\(r.trim?.kind ?? "-") g:\(grown)\n\(r.text)"
    }

    static func summary(tag: String, label: String, rows: [Row], cfg: Config, found: Int, cross: Int, noBox: Int) -> String {
        let n = rows.count
        let clean = rows.filter { $0.m.clean(cfg) }.count
        let (lo, hi) = wilson(clean, n)
        let strict = rows.filter { $0.m.cleanStrict(cfg) }.count
        let a = rows.filter { $0.m.a(cfg) > 0 }.count, b = rows.filter { $0.m.b >= cfg.bLimit }.count, c = rows.filter { $0.m.c(cfg) > 0 }.count
        let tr = rows.filter { $0.trim != nil }
        let trOK = tr.filter { $0.trim!.ok }.count
        let trKinds = Dictionary(grouping: tr.filter { !$0.trim!.ok }, by: { $0.trim!.kind }).map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: ",")
        let refused = rows.filter { $0.grown == nil }.count
        let grownClean = rows.filter { $0.grown != nil && ($0.grownM?.clean(cfg) ?? false) }.count
        let grownBad = rows.filter { $0.grown != nil && !($0.grownM?.clean(cfg) ?? false) }.count
        let (glo, ghi) = wilson(grownClean, n)
        // The ink-grown box drawn as its own components only (a mask), so that neighbour ink in the rectangle is not drawn: (c) is moot.
        let grownMasked = rows.filter { r in r.grown != nil && (r.grownM.map { $0.a(cfg) == 0 && $0.b < cfg.bLimit } ?? false) }.count
        return "[\(tag)] \(label): found=\(found) single-line=\(n) (cross-line=\(cross) no-box=\(noBox)) clean=\(clean)/\(n) \(pct(clean, n)) [95% \(Int(lo * 100))-\(Int(hi * 100))] strict-a=\(strict) fail: a=\(a) b=\(b) c=\(c) | trim ok=\(trOK)/\(tr.count)\(trKinds.isEmpty ? "" : " (" + trKinds + ")") | grown: clean=\(grownClean) \(pct(grownClean, n)) [\(Int(glo * 100))-\(Int(ghi * 100))] refused=\(refused) drawn-bad=\(grownBad) | grown-masked(a,b only)=\(grownMasked) \(pct(grownMasked, n))"
    }
}
